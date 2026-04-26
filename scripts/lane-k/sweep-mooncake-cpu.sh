#!/bin/bash
# Lane K / Mooncake CPU-mode DRAM->DRAM sweep on EFA v6.
# Sizing rule: block_size * threads * batch_size <= buffer_size (1 GB default).
# We pick: block x (threads x batch) combos where the product is small enough,
# and pre-stage threads/batch to exercise different concurrency levels.
set -u
NS=yanxi-validation
T_POD=lane-k-target
I_POD=lane-k-initiator
T_IP=10.1.12.238
I_IP=10.1.12.184
META_URL=http://10.1.12.238:8080/metadata
BENCH=/opt/mooncake/build/mooncake-transfer-engine/example/transfer_engine_bench
OUT=/out/lane-k-sweep.csv
ENV_VARS='export FI_PROVIDER=efa FI_EFA_USE_DEVICE_RDMA=1 FI_EFA_FORK_SAFE=1 FI_MR_HMEM=1 MC_LEGACY_RPC_PORT_BINDING=1 MC_WORKERS_PER_CTX=2 MC_NUM_CQ_PER_CTX=2'
DURATION=15

# Seed CSV header
kubectl exec -n $NS $I_POD -- bash -c "echo run_id,block_size,threads,batch_size,require_gb,duration_s,batch_count,gbps > $OUT" 2>&1

run_point() {
    local RUN=$1 BLK=$2 THR=$3 BATCH=$4
    local REQ=$((BLK * THR * BATCH))
    local REQ_GB
    REQ_GB=$(awk -v b=$REQ 'BEGIN{printf "%.2f", b/1e9}')
    echo "=== $RUN  block=$BLK  threads=$THR  batch=$BATCH  require=${REQ_GB}GB ==="

    # Clean prior
    kubectl exec -n $NS $T_POD -- bash -c 'pkill -f transfer_engine_bench 2>/dev/null; sleep 1' 2>&1 >/dev/null
    kubectl exec -n $NS $I_POD -- bash -c 'pkill -f transfer_engine_bench 2>/dev/null; sleep 1' 2>&1 >/dev/null

    # Start target (detached)
    kubectl exec -n $NS $T_POD -- bash -c "
      bash -c '${ENV_VARS}; nohup ${BENCH} --mode=target --protocol=efa --metadata_server=${META_URL} --local_server_name=${T_IP}:13001 --duration=$((DURATION + 20)) --use_vram=false --block_size=${BLK} --threads=${THR} --batch_size=${BATCH} > /out/target.log 2>&1 &'
      sleep 5; pgrep -f transfer_engine_bench | head -1
    " 2>&1 | head -2
    sleep 4

    # Start initiator
    kubectl exec -n $NS $I_POD -- bash -c "
      bash -c '${ENV_VARS}; nohup ${BENCH} --mode=initiator --protocol=efa --metadata_server=${META_URL} --local_server_name=${I_IP}:13002 --segment_id=${T_IP}:13001 --operation=write --block_size=${BLK} --threads=${THR} --batch_size=${BATCH} --duration=${DURATION} --report_unit=GB --use_vram=false > /out/init.log 2>&1 &'
      sleep 3; pgrep -f transfer_engine_bench | head -1
    " 2>&1 | head -2

    # Wait for initiator to finish
    sleep $((DURATION + 8))

    # Parse result
    local LINE
    LINE=$(kubectl exec -n $NS $I_POD -- grep "Test completed" /out/init.log 2>&1 | tail -1)
    echo "$LINE"
    local BC GBPS
    BC=$(echo "$LINE" | sed -n 's/.*batch count \([0-9]*\).*/\1/p')
    GBPS=$(echo "$LINE" | sed -n 's/.*throughput \([0-9.]*\) GB\/s.*/\1/p')

    kubectl exec -n $NS $I_POD -- bash -c "echo $RUN,$BLK,$THR,$BATCH,$REQ_GB,$DURATION,${BC:-0},${GBPS:-0} >> $OUT" 2>&1

    # Cleanup between points
    kubectl exec -n $NS $T_POD -- pkill -f transfer_engine_bench 2>/dev/null || true
    kubectl exec -n $NS $I_POD -- pkill -f transfer_engine_bench 2>/dev/null || true
    sleep 3
}

# 12-point sweep
# Size invariant: block * threads * batch <= 1 GB = 1073741824
# msg sizes: 64 KB, 256 KB, 1 MB, 4 MB, 16 MB
# concurrencies (threads x batch product): low=32, med=128, high=512
#   - 64K: 512 conc -> require 32 MB ; 128 conc -> 8 MB; 32 conc -> 2 MB
#   - 256K: 512 conc -> 128 MB ; 128 conc -> 32 MB ; 32 conc -> 8 MB
#   - 1M: 512 -> 512 MB; 128 -> 128 MB; 32 -> 32 MB
#   - 4M: 128 -> 512 MB; 32 -> 128 MB; [512 too big]
#   - 16M: 32 -> 512 MB; [128 & 512 too big]

# We use threads=4 and vary batch_size for concurrency
# Skip combos where require > 1 GB
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
echo "=== CSV output ==="
kubectl exec -n $NS $I_POD -- cat $OUT 2>&1
