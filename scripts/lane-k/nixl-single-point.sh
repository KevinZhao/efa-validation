#!/bin/bash
set -u
NS=yanxi-validation
T_POD=lane-k-target
I_POD=lane-k-initiator
ETCD_EP=http://10.1.12.248:2379
GROUP="nixl-sanity-$(date +%s)"

# Full kill
kubectl exec -n $NS $T_POD -- pkill -9 -f nixlbench 2>/dev/null || true
kubectl exec -n $NS $I_POD -- pkill -9 -f nixlbench 2>/dev/null || true
sleep 3

echo "=== Start target (rank assignment: whichever connects first=initiator) ==="
# NIXLBench convention: first process to register = initiator (rank 0), second = target (rank 1)
# We label them by pod name; actual role is determined by connection order.
kubectl exec -n $NS $T_POD -- bash -c "
  bash -c 'nohup /opt/nixl/bin/nixlbench --backend LIBFABRIC --runtime_type ETCD --etcd_endpoints ${ETCD_EP} --benchmark_group ${GROUP} --scheme pairwise --op_type WRITE --initiator_seg_type DRAM --target_seg_type DRAM --start_block_size 1048576 --max_block_size 1048576 --num_threads 4 --num_iter 100 > /out/nxt.log 2>&1 &'
  sleep 3
  pgrep -f nixlbench | head
" 2>&1 | head
sleep 3

echo "=== Start initiator ==="
kubectl exec -n $NS $I_POD -- bash -c "
  bash -c 'nohup /opt/nixl/bin/nixlbench --backend LIBFABRIC --runtime_type ETCD --etcd_endpoints ${ETCD_EP} --benchmark_group ${GROUP} --scheme pairwise --op_type WRITE --initiator_seg_type DRAM --target_seg_type DRAM --start_block_size 1048576 --max_block_size 1048576 --num_threads 4 --num_iter 100 > /out/nxi.log 2>&1 &'
  sleep 3
  pgrep -f nixlbench | head
" 2>&1 | head

sleep 45
echo
echo "=== INIT LOG ==="
kubectl exec -n $NS $I_POD -- tail -50 /out/nxi.log 2>&1 | tail -40

echo
echo "=== TARGET LOG ==="
kubectl exec -n $NS $T_POD -- tail -30 /out/nxt.log 2>&1 | tail -25

kubectl exec -n $NS $T_POD -- pkill -f nixlbench 2>/dev/null || true
kubectl exec -n $NS $I_POD -- pkill -f nixlbench 2>/dev/null || true
