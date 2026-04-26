#!/bin/bash
# NIXL 12-point sweep matching Mooncake params (block × threads × batch).
# Same 12 (block, threads, batch) tuples as scripts/lane-k/sweep-mooncake-cpu.sh
# to enable apples-to-apples Δ% comparison in K_VS_MOONCAKE.md.
set -u
NS=yanxi-validation
T_POD=lane-k-target
I_POD=lane-k-initiator
ETCD_EP=http://10.1.12.248:2379
OUT=/out/nixl-sweep.csv

# Clean
kubectl exec -n $NS $T_POD -- pkill -9 -f nixlbench 2>/dev/null || true
kubectl exec -n $NS $I_POD -- pkill -9 -f nixlbench 2>/dev/null || true
sleep 3

# Seed CSV header
kubectl exec -n $NS $I_POD -- bash -c "echo run_id,block_size,threads,batch_size,bw_gbps,avg_lat_us,avg_prep_us,p99_prep_us,avg_post_us,p99_post_us,avg_tx_us,p99_tx_us > $OUT" 2>&1

run_point() {
    local RUN=$1 BLK=$2 THR=$3 BATCH=$4
    local GROUP="nxbl-$(date +%s)-${RUN}"
    echo "=== $RUN  block=$BLK  threads=$THR  batch=$BATCH ==="

    # Start target
    kubectl exec -n $NS $T_POD -- bash -c "
      bash -c 'nohup /opt/nixl/bin/nixlbench --backend LIBFABRIC --runtime_type ETCD --etcd_endpoints ${ETCD_EP} --benchmark_group ${GROUP} --scheme pairwise --op_type WRITE --initiator_seg_type DRAM --target_seg_type DRAM --start_block_size ${BLK} --max_block_size ${BLK} --start_batch_size ${BATCH} --max_batch_size ${BATCH} --num_threads ${THR} --num_iter $((THR * 32)) > /out/nxt.log 2>&1 &'
      sleep 2
    " 2>&1 > /dev/null

    sleep 2

    # Start initiator
    kubectl exec -n $NS $I_POD -- bash -c "
      bash -c 'nohup /opt/nixl/bin/nixlbench --backend LIBFABRIC --runtime_type ETCD --etcd_endpoints ${ETCD_EP} --benchmark_group ${GROUP} --scheme pairwise --op_type WRITE --initiator_seg_type DRAM --target_seg_type DRAM --start_block_size ${BLK} --max_block_size ${BLK} --start_batch_size ${BATCH} --max_batch_size ${BATCH} --num_threads ${THR} --num_iter $((THR * 32)) > /out/nxi.log 2>&1 &'
      sleep 2
    " 2>&1 > /dev/null

    # Wait for bench to finish (warmup+real+destruct)
    sleep 25

    # Parse data row (exactly: "BLK BATCH BW ... 8 fields")
    local ROW
    ROW=$(kubectl exec -n $NS $I_POD -- awk "/^$BLK  *$BATCH  *[0-9]/{print}" /out/nxi.log 2>&1 | tail -1)
    if [ -z "$ROW" ]; then
      # Try target side
      ROW=$(kubectl exec -n $NS $T_POD -- awk "/^$BLK  *$BATCH  *[0-9]/{print}" /out/nxt.log 2>&1 | tail -1)
    fi
    echo "  ROW: $ROW"

    # Extract columns
    set -- $ROW
    local BW_GBPS=${3:-0}
    local AVG_LAT=${4:-0}
    local AVG_PREP=${5:-0}
    local P99_PREP=${6:-0}
    local AVG_POST=${7:-0}
    local P99_POST=${8:-0}
    local AVG_TX=${9:-0}
    local P99_TX=${10:-0}

    kubectl exec -n $NS $I_POD -- bash -c "echo $RUN,$BLK,$THR,$BATCH,$BW_GBPS,$AVG_LAT,$AVG_PREP,$P99_PREP,$AVG_POST,$P99_POST,$AVG_TX,$P99_TX >> $OUT" 2>&1 > /dev/null

    # Cleanup
    kubectl exec -n $NS $T_POD -- pkill -f nixlbench 2>/dev/null || true
    kubectl exec -n $NS $I_POD -- pkill -f nixlbench 2>/dev/null || true
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
