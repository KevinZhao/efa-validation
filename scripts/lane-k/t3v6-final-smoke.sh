#!/bin/bash
# T3 smoke v6: split into two SSM invocations to avoid kubectl-exec-in-ssm lock.
# Strategy: use `nohup &` and immediately exit, then poll from outside.
set -u
NS=yanxi-validation
T_POD=lane-k-target
I_POD=lane-k-initiator
T_IP=10.1.12.238
I_IP=10.1.12.184
META_URL=http://10.1.12.238:8080/metadata
BENCH=/opt/mooncake/build/mooncake-transfer-engine/example/transfer_engine_bench

# 1. Kill any previous
kubectl exec -n $NS $T_POD -- bash -c 'pkill -f transfer_engine_bench 2>/dev/null || true; sleep 1' 2>&1 | head -2
kubectl exec -n $NS $I_POD -- bash -c 'pkill -f transfer_engine_bench 2>/dev/null || true; sleep 1' 2>&1 | head -2

# 2. Start target in background using nohup -- the key: exit kubectl exec immediately.
kubectl exec -n $NS $T_POD -- bash -c "
  ENV='export FI_PROVIDER=efa FI_EFA_USE_DEVICE_RDMA=1 FI_EFA_FORK_SAFE=1 FI_MR_HMEM=1 MC_WORKERS_PER_CTX=2 MC_NUM_CQ_PER_CTX=2 MC_LEGACY_RPC_PORT_BINDING=1'
  bash -c \"\${ENV}; nohup ${BENCH} --mode=target --protocol=efa --metadata_server=${META_URL} --local_server_name=${T_IP}:13001 --duration=90 --use_vram=false > /out/target.log 2>&1 &\"
  sleep 3
  pgrep -f transfer_engine_bench | head -1
" 2>&1
echo "---target started---"
sleep 4

# 3. Start initiator similarly
kubectl exec -n $NS $I_POD -- bash -c "
  ENV='export FI_PROVIDER=efa FI_EFA_USE_DEVICE_RDMA=1 FI_EFA_FORK_SAFE=1 FI_MR_HMEM=1 MC_WORKERS_PER_CTX=2 MC_NUM_CQ_PER_CTX=2 MC_LEGACY_RPC_PORT_BINDING=1'
  bash -c \"\${ENV}; nohup ${BENCH} --mode=initiator --protocol=efa --metadata_server=${META_URL} --local_server_name=${I_IP}:13002 --segment_id=${T_IP}:13001 --operation=write --block_size=4194304 --threads=16 --batch_size=128 --duration=15 --report_unit=GB --use_vram=false > /out/init.log 2>&1 &\"
  sleep 3
  pgrep -f transfer_engine_bench | head -1
" 2>&1
echo "---initiator started---"

# 4. Wait for initiator to finish (runs ~15 + startup)
sleep 40

# 5. Collect logs
echo
echo "=== INITIATOR LOG ==="
kubectl exec -n $NS $I_POD -- tail -60 /out/init.log 2>&1

echo
echo "=== TARGET LOG ==="
kubectl exec -n $NS $T_POD -- tail -30 /out/target.log 2>&1

# 6. Cleanup
kubectl exec -n $NS $T_POD -- pkill -f transfer_engine_bench 2>/dev/null || true
kubectl exec -n $NS $I_POD -- pkill -f transfer_engine_bench 2>/dev/null || true
echo DONE
