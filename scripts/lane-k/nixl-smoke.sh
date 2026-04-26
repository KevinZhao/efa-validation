#!/bin/bash
# NIXL smoke: LIBFABRIC backend, 1M block, 4 threads, DRAM->DRAM write, etcd coord.
set -u
NS=yanxi-validation
T_POD=lane-k-target
I_POD=lane-k-initiator
ETCD_EP=http://10.1.12.121:2379   # etcd is ClusterIP svc; use its node IP via hostNetwork
T_IP=10.1.12.140
I_IP=10.1.12.121

# Actually: etcd is ClusterIP service. Let's get the service ClusterIP.
# But hostNetwork pods can't hit ClusterIPs directly on some configs.
# Check first.

# Alternative: use etcd pod's nodeIP:2379 ... but etcd pod is NOT hostNetwork.
# Best: expose etcd on any pod's NIC via hostNetwork (requires manifest change)
# OR use etcd's own pod IP (works from anywhere in pod network).

echo "=== etcd service info ==="
kubectl get svc -n yanxi-validation etcd -o wide 2>&1 | head
ETCD_POD_IP=$(kubectl get pods -n yanxi-validation -l app=etcd -o jsonpath='{.items[0].status.podIP}')
echo "etcd pod IP: $ETCD_POD_IP"
ETCD_SVC_IP=$(kubectl get svc -n yanxi-validation etcd -o jsonpath='{.spec.clusterIP}')
echo "etcd ClusterIP: $ETCD_SVC_IP"

# Test reachability from bench pods (hostNetwork → pod network):
echo "=== ClusterIP reachability test ==="
kubectl exec -n $NS $I_POD -- curl -s -m 3 -o /dev/null -w "init->etcd_svc:%{http_code}\n" http://$ETCD_SVC_IP:2379/ 2>&1
kubectl exec -n $NS $I_POD -- curl -s -m 3 -o /dev/null -w "init->etcd_pod:%{http_code}\n" http://$ETCD_POD_IP:2379/ 2>&1
