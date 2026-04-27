#!/bin/bash
# Oregon p5 variant of nixl-sweep.sh — same 12 param tuples as Mooncake sweep.
# ETCD is a ClusterIP Service → reached via svc DNS from hostNetwork pods on
# same node (works because etcd pod has hostNetwork=false + CNI route OK in-cluster;
# we bypass with the actual etcd pod IP to be safe).
set -u
NS=yanxi-validation
T_POD=lane-k-target
I_POD=lane-k-initiator
ETCD_EP="http://10.0.13.225:2379"
OUT=/out/nixl-sweep.csv

kubectl exec -n $NS $T_POD -- pkill -9 -f nixlbench 2>/dev/null || true
kubectl exec -n $NS $I_POD -- pkill -9 -f nixlbench 2>/dev/null || true
sleep 3

kubectl exec -n $NS $I_POD -- bash -c "echo run_id,block_size,threads,batch_size,bw_gbps,avg_lat_us,avg_prep_us,p99_prep_us,avg_post_us,p99_post_us,avg_tx_us,p99_tx_us > $OUT"

run_point() {
    local RUN=$1 BLK=$2 THR=$3 BATCH=$4
    local GROUP="nxbl-$(date +%s)-${RUN}"
    echo "=== $RUN  block=$BLK  threads=$THR  batch=$BATCH  group=$GROUP ==="

    kubectl exec -n $NS $T_POD -- bash -c "
      bash -c 'nohup /opt/nixl/bin/nixlbench --backend LIBFABRIC --runtime_type ETCD --etcd_endpoints ${ETCD_EP} --benchmark_group ${GROUP} --scheme pairwise --op_type WRITE --initiator_seg_type DRAM --target_seg_type DRAM --start_block_size ${BLK} --max_block_size ${BLK} --start_batch_size ${BATCH} --max_batch_size ${BATCH} --num_threads ${THR} --num_iter $((THR * 32)) > /out/nxt.log 2>&1 &'
      sleep 2
    " >/dev/null 2>&1

    sleep 2

    kubectl exec -n $NS $I_POD -- bash -c "
      bash -c 'nohup /opt/nixl/bin/nixlbench --backend LIBFABRIC --runtime_type ETCD --etcd_endpoints ${ETCD_EP} --benchmark_group ${GROUP} --scheme pairwise --op_type WRITE --initiator_seg_type DRAM --target_seg_type DRAM --start_block_size ${BLK} --max_block_size ${BLK} --start_batch_size ${BATCH} --max_batch_size ${BATCH} --num_threads ${THR} --num_iter $((THR * 32)) > /out/nxi.log 2>&1 &'
      sleep 2
    " >/dev/null 2>&1

    sleep 28

    local ROW
    ROW=$(kubectl exec -n $NS $I_POD -- awk "/^$BLK  *$BATCH  *[0-9]/{print}" /out/nxi.log 2>&1 | tail -1)
    if [ -z "$ROW" ]; then
      ROW=$(kubectl exec -n $NS $T_POD -- awk "/^$BLK  *$BATCH  *[0-9]/{print}" /out/nxt.log 2>&1 | tail -1)
    fi
    echo "  ROW: $ROW"

    set -- $ROW
    local BW_GBPS=${3:-0} AVG_LAT=${4:-0} AVG_PREP=${5:-0} P99_PREP=${6:-0}
    local AVG_POST=${7:-0} P99_POST=${8:-0} AVG_TX=${9:-0} P99_TX=${10:-0}

    kubectl exec -n $NS $I_POD -- bash -c "echo $RUN,$BLK,$THR,$BATCH,$BW_GBPS,$AVG_LAT,$AVG_PREP,$P99_PREP,$AVG_POST,$P99_POST,$AVG_TX,$P99_TX >> $OUT" >/dev/null 2>&1

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
