#!/bin/bash
# Lane K preflight — run from BASTION via SSM. Dumps exact CLI from both
# benchmark tools in the live image so the orchestrator can build correct
# command lines. Produces /tmp/lane-k-preflight.txt on the bastion after a
# kubectl-cp roundtrip from the initiator pod.
set -euo pipefail

NS=yanxi-validation
OUT=/tmp/lane-k-preflight.txt

run_in_pod() {
  local pod=$1; shift
  kubectl exec -n "$NS" "$pod" -- bash -c "$*" 2>&1
}

{
  echo "=== nixlbench --help ==="
  run_in_pod lane-k-initiator 'nixlbench --help || true'
  echo
  echo "=== nixlbench version ==="
  run_in_pod lane-k-initiator 'nixlbench --version 2>&1 || nixlbench -V 2>&1 || true'
  echo
  echo "=== transfer_engine_bench --help ==="
  run_in_pod lane-k-initiator 'transfer_engine_bench --help 2>&1 || transfer_engine_bench --helpshort 2>&1 || true'
  echo
  echo "=== EFA on initiator ==="
  run_in_pod lane-k-initiator '/opt/amazon/efa/bin/fi_info -p efa 2>&1 | head -40 || true'
  echo
  echo "=== EFA device list (rdmap*) ==="
  run_in_pod lane-k-initiator 'ls /sys/class/infiniband/ 2>&1'
  echo
  echo "=== etcd reachability ==="
  run_in_pod lane-k-initiator 'ETCDCTL_API=3 etcdctl --endpoints=$ETCD_ENDPOINTS endpoint health 2>&1 || echo "etcdctl unavailable"'
  echo
  echo "=== Mooncake python binding OK? ==="
  run_in_pod lane-k-initiator 'python3 -c "import mooncake; print(mooncake.__file__)" 2>&1'
  echo
  echo "=== NIXL python binding OK? ==="
  run_in_pod lane-k-initiator 'python3 -c "import nixl_cu12; print(nixl_cu12.__file__)" 2>&1 || true'
  echo
  echo "=== Target pod IP (for --target_ip / --segment_id) ==="
  kubectl get pod -n "$NS" lane-k-target -o jsonpath='{.status.hostIP}' 2>&1; echo
  echo "=== Initiator pod IP ==="
  kubectl get pod -n "$NS" lane-k-initiator -o jsonpath='{.status.hostIP}' 2>&1; echo
} | tee "$OUT"

echo
echo "Preflight saved to $OUT"
