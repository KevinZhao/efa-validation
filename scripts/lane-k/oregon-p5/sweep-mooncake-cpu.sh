#!/bin/bash
# Oregon p5 variant of sweep-mooncake-cpu.sh.
# Same algorithm + params as Ohio p5en prior run; only host IPs change.
# Target node 10.0.13.65, initiator node 10.0.13.103, both us-west-2c.
# Image: mooncake-nixl:v6.1 (libcuda stub baked; v6 patch inherited).
set -u
NS=yanxi-validation
T_POD=lane-k-target
I_POD=lane-k-initiator
T_IP=10.0.13.65
I_IP=10.0.13.103
META_URL=http://10.0.13.65:8080/metadata
BENCH=/opt/mooncake/build/mooncake-transfer-engine/example/transfer_engine_bench
OUT=/out/mc-sweep.csv
ENV_VARS='export FI_PROVIDER=efa FI_EFA_USE_DEVICE_RDMA=1 FI_EFA_FORK_SAFE=1 FI_MR_HMEM=1 MC_LEGACY_RPC_PORT_BINDING=1 MC_WORKERS_PER_CTX=2 MC_NUM_CQ_PER_CTX=2'
DURATION=15

kubectl exec -n $NS $I_POD -- bash -c "echo run_id,block_size,threads,batch_size,require_gb,duration_s,batch_count,gbps > $OUT"

run_point() {
    local RUN=$1 BLK=$2 THR=$3 BATCH=$4
    local REQ=$((BLK * THR * BATCH))
    local REQ_GB
    REQ_GB=$(awk -v b=$REQ 'BEGIN{printf "%.2f", b/1e9}')
    echo "=== $RUN  block=$BLK  threads=$THR  batch=$BATCH  require=${REQ_GB}GB ==="

    kubectl exec -n $NS $T_POD -- bash -c 'pkill -f transfer_engine_bench 2>/dev/null; sleep 1' >/dev/null 2>&1
    kubectl exec -n $NS $I_POD -- bash -c 'pkill -f transfer_engine_bench 2>/dev/null; sleep 1' >/dev/null 2>&1

    kubectl exec -n $NS $T_POD -- bash -c "
      bash -c '${ENV_VARS}; nohup ${BENCH} --mode=target --protocol=efa --metadata_server=${META_URL} --local_server_name=${T_IP}:13001 --duration=$((DURATION + 20)) --use_vram=false --block_size=${BLK} --threads=${THR} --batch_size=${BATCH} > /out/target.log 2>&1 &'
      sleep 5; pgrep -f transfer_engine_bench | head -1
    " 2>&1 | head -2
    sleep 4

    kubectl exec -n $NS $I_POD -- bash -c "
      bash -c '${ENV_VARS}; nohup ${BENCH} --mode=initiator --protocol=efa --metadata_server=${META_URL} --local_server_name=${I_IP}:13002 --segment_id=${T_IP}:13001 --operation=write --block_size=${BLK} --threads=${THR} --batch_size=${BATCH} --duration=${DURATION} --report_unit=GB --use_vram=false > /out/init.log 2>&1 &'
      sleep 3; pgrep -f transfer_engine_bench | head -1
    " 2>&1 | head -2

    sleep $((DURATION + 8))

    local LINE
    LINE=$(kubectl exec -n $NS $I_POD -- grep "Test completed" /out/init.log 2>&1 | tail -1)
    echo "$LINE"
    local BC GBPS
    BC=$(echo "$LINE" | sed -n 's/.*batch count \([0-9]*\).*/\1/p')
    GBPS=$(echo "$LINE" | sed -n 's/.*throughput \([0-9.]*\) GB\/s.*/\1/p')

    kubectl exec -n $NS $I_POD -- bash -c "echo $RUN,$BLK,$THR,$BATCH,$REQ_GB,$DURATION,${BC:-0},${GBPS:-0} >> $OUT"

    kubectl exec -n $NS $T_POD -- pkill -f transfer_engine_bench 2>/dev/null || true
    kubectl exec -n $NS $I_POD -- pkill -f transfer_engine_bench 2>/dev/null || true
    sleep 3
}

run_point "p01-64K-32c"   65536   4 8
run_point "p02-64K-128c"  65536   4 32
run_point "p03-64K-512c"  65536   4 128
run_point "p04-256K-32c"  262144  4 8
run_point "p05-256K-128c" 262144  4 32
run_point "p06-256K-512c" 262144  4 128
run_point "p07-1M-32c"    1048576 4 8
run_point "p08-1M-128c"   1048576 4 32
run_point "p09-1M-512c"   1048576 4 128
run_point "p10-4M-32c"    4194304 4 8
run_point "p11-4M-128c"   4194304 4 32
run_point "p12-16M-32c"   16777216 4 8

echo
echo "=== CSV ==="
kubectl exec -n $NS $I_POD -- cat $OUT 2>&1
