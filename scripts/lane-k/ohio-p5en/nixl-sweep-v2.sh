#!/bin/bash
set -u
export HOME=/root
NS=yanxi-validation
# In NIXL terms: our "lane-k-target" pod starts first → becomes rank 0 = INITIATOR (sends, reports data)
#                our "lane-k-initiator" pod starts second → becomes rank 1 = TARGET (receives)
# We log to per-point files so later-running points don't clobber earlier ones.
RANK0_POD=lane-k-target      # NIXL initiator (data reporter)
RANK1_POD=lane-k-initiator   # NIXL target
ETCD_EP=http://10.1.12.81:2379

kubectl exec -n $NS $RANK0_POD -- pkill -9 -f nixlbench >/dev/null 2>&1 || true
kubectl exec -n $NS $RANK1_POD -- pkill -9 -f nixlbench >/dev/null 2>&1 || true
sleep 3

OUT_CSV=/out/nixl-manual.csv
kubectl exec -n $NS $RANK0_POD -- bash -c "echo run_id,block_size,batch_size,bw_gbps,avg_lat_us,avg_prep_us,p99_prep_us,avg_post_us,p99_post_us,avg_tx_us,p99_tx_us > $OUT_CSV"

run_point() {
    local NAME=$1 BLK=$2 THR=$3 BATCH=$4 DWELL=${5:-55}
    local GROUP="nxbl-$(date +%s%N)-${NAME}"
    local LOG0=/out/nx-${NAME}.r0.log
    local LOG1=/out/nx-${NAME}.r1.log
    echo "=== $NAME  block=$BLK  threads=$THR  batch=$BATCH  dwell=$DWELL ==="

    kubectl exec -n $NS $RANK0_POD -- pkill -9 -f nixlbench >/dev/null 2>&1 || true
    kubectl exec -n $NS $RANK1_POD -- pkill -9 -f nixlbench >/dev/null 2>&1 || true
    sleep 2

    kubectl exec -n $NS $RANK0_POD -- bash -c "nohup /opt/nixl/bin/nixlbench --backend LIBFABRIC --runtime_type ETCD --etcd_endpoints $ETCD_EP --benchmark_group $GROUP --scheme pairwise --op_type WRITE --initiator_seg_type DRAM --target_seg_type DRAM --start_block_size $BLK --max_block_size $BLK --start_batch_size $BATCH --max_batch_size $BATCH --num_threads $THR --num_iter 128 > $LOG0 2>&1 &" >/dev/null 2>&1
    sleep 3
    kubectl exec -n $NS $RANK1_POD -- bash -c "nohup /opt/nixl/bin/nixlbench --backend LIBFABRIC --runtime_type ETCD --etcd_endpoints $ETCD_EP --benchmark_group $GROUP --scheme pairwise --op_type WRITE --initiator_seg_type DRAM --target_seg_type DRAM --start_block_size $BLK --max_block_size $BLK --start_batch_size $BATCH --max_batch_size $BATCH --num_threads $THR --num_iter 128 > $LOG1 2>&1 &" >/dev/null 2>&1

    sleep $DWELL

    # Data row on rank 0 pod (the one printed data)
    local ROW
    ROW=$(kubectl exec -n $NS $RANK0_POD -- awk "/^$BLK  *$BATCH  *[0-9]/{print}" $LOG0 2>&1 | tail -1)
    echo "  ROW: $ROW"

    # Parse columns
    set -- $ROW
    local BW=${3:-0} LAT=${4:-0} APP=${5:-0} PPP=${6:-0} APO=${7:-0} PPO=${8:-0} ATX=${9:-0} PTX=${10:-0}
    kubectl exec -n $NS $RANK0_POD -- bash -c "echo $NAME,$BLK,$BATCH,$BW,$LAT,$APP,$PPP,$APO,$PPO,$ATX,$PTX >> $OUT_CSV" >/dev/null 2>&1

    kubectl exec -n $NS $RANK0_POD -- pkill -f nixlbench >/dev/null 2>&1 || true
    kubectl exec -n $NS $RANK1_POD -- pkill -f nixlbench >/dev/null 2>&1 || true
    sleep 3
}

# 12 tuples matching Mooncake sweep
run_point "p01-64K-32c"   65536    4 8    45
run_point "p02-64K-128c"  65536    4 32   45
run_point "p03-64K-512c"  65536    4 128  55
run_point "p04-256K-32c"  262144   4 8    45
run_point "p05-256K-128c" 262144   4 32   55
run_point "p06-256K-512c" 262144   4 128  65
run_point "p07-1M-32c"    1048576  4 8    55
run_point "p08-1M-128c"   1048576  4 32   65
run_point "p09-1M-512c"   1048576  4 128  80
run_point "p10-4M-32c"    4194304  4 8    65
run_point "p11-4M-128c"   4194304  4 32   80
run_point "p12-16M-32c"   16777216 4 8    80

echo
echo "=== CSV ==="
kubectl exec -n $NS $RANK0_POD -- cat $OUT_CSV
