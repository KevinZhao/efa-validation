# Lane K p5en Δ% + NCCL baseline — STEPS

**Run ID**: `lane-k/20260426T134313Z-p5en-nixl-vs-mooncake-nccl`

## Timeline (UTC)

| Time | Action | Result |
|---|---|---|
| 13:40 | SPS check: Ohio use2-az2 p5en tc=2 = **9** | GO |
| 13:42 | `aws eks update-nodegroup-config gpu-p5en-spot-useast2b desired=2` | 2 p5en launched in us-east-2b |
| 13:43 | Upload manifests + sweep scripts to `s3://yanxi-validation-788668107894-ohio/lane-k-ohio-p5en/20260426T134313Z/` | |
| 13:44 | SSM→bastion `i-097c86b226a32a128`: apply etcd.yaml + meta.yaml; cleanup old `mooncake-metadata-v3` + stale sglang-r1c Services | etcd + meta Running on 10.1.12.18 |
| 13:50 | Image pull for meta: 1st attempt `EOF`, 2nd attempt OK; bench `target` Running (cache hit), `initiator` pulls | |
| 13:54 | apply bench.yaml; etcd pod IP = `10.1.12.81`; sed-fill nixl-sweep-v2.sh ETCD_EP | |
| 13:56 | Preflight on target: fi_info = 48 (= 16 × 3 = **16 NIC EFA v3** ✓), nixlbench --help loads, v6 patch sentinel ✓, /dev/nvidia* OK | |
| 13:58 | Launch Mooncake 12-point sweep | |
| 14:07 | Mooncake DONE — peak **205 GB/s** @ 4M × 4 × 8 | |
| 14:08 | Launch NIXL v2 sweep | |
| 14:25 | NIXL DONE — peak **134 GB/s** @ 1M × 4 × 8 | |
| 14:27 | Build nccl-tests inside both bench pods (`make MPI=1 CUDA_HOME=/usr/local/cuda NCCL_HOME=/usr`) — ~2 min | |
| 14:30 | 1st NCCL attempt: `Test CUDA failure: driver is a stub library` | v6.1 libcuda stub blocks real CUDA |
| 14:32 | Workaround: `LD_LIBRARY_PATH=/usr/lib64:...` — real host-bound libcuda at `/usr/lib64/libcuda.so.1` takes precedence | |
| 14:34 | NCCL single-node 8-GPU `all_reduce_perf -b 1M -e 256M -f 2 -g 8` — peak **347 GB/s busbw** @ 256 MB | NVLink baseline captured |
| 14:40 | Decided to defer 2-node NCCL (needs sshd + mpirun, not in v6.1) | |
| 14:40 | `kubectl delete` all workload; `aws eks update-nodegroup-config desired=0` | Scale-in started |
| 14:43 | Both p5en in `shutting-down`; NG `desired=0`, `status=ACTIVE` | |

## Key IPs + names

- Target pod: `lane-k-target`, node `ip-10-1-12-18`, node IP `10.1.12.18` (NIXL rank 0 = initiator)
- Initiator pod: `lane-k-initiator`, node `ip-10-1-12-228`, node IP `10.1.12.228` (NIXL rank 1 = target)
- etcd pod IP: `10.1.12.81` (for NIXL coordination)
- mooncake-meta: `http://10.1.12.18:8080/metadata` (hostNetwork service on target node)

## Why Ohio p5en NG was a single-AZ pin by default

`gpu-p5en-spot-useast2b` has `subnets=[subnet-0c86f1c69e4067890]` (us-east-2b only) — already single-AZ by design. We reused it, avoiding the cross-AZ trap hit in Oregon p5 run.

## Artefacts saved

- `mc-sweep.csv`, `nixl-sweep.csv` — raw 12-point sweeps
- `nccl-single-node.txt` — NCCL NVLink reference
- `RESULT.md` — analysis + Δ% tables + cross-hardware compare
