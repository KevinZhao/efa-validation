# Sprint A Gate A — Environment

**Date**: 2026-05-03 14:04-14:27 UTC
**Purpose**: Verify that `feat/sbo-comp-signal-sprint-a` compiles on a real
H200 container with nvcc SM=90 before any bench/perf work.

## Hardware

- 1× p5en.48xlarge spot instance (ap-northeast-1a, apne1-az4, SPS=9 at acquisition)
- Node: ip-10-99-10-223.ap-northeast-1.compute.internal
- H200 SXM5 x 8 per node (1 visible in pod via CDI annotation, build only)

## Software stack

- EKS cluster: `yanxi-eks-tokyo` (K8s 1.35)
- Nodegroup: `gpu-p5en-48xlarge-spot` (Amazon Linux 2023.11.20260413, kernel 6.12.79)
- Container image: `788668107894.dkr.ecr.us-east-2.amazonaws.com/yanxi/uccl-ep:latest`
  - CUDA 12.6, nvcc 12.6 r12.6
  - Python 3.10, PyTorch 2.5.1+cu124, nanobind bundled
  - g++ 11.4.0, EFA SDK
- Branch: `feat/sbo-comp-signal-sprint-a` @ `1304e828`
  - Parent: `91a3bdfa` (stub PR #919, OPEN) + this PR's ~215-line kernel diff

## Build config

- `PER_EXPERT_BATCHING=0` (PEB lever off)
- `SM=90` explicit override (`nvidia-smi --query-gpu=compute_cap` unavailable in build pod)
- `make -j$(nproc)` (direct make; `build.sh` needs docker-in-docker)
- All 8 `combine<>` template instantiations compiled:
  `{use_logfmt=false,true} × {aggressive_atomic=false,true} × {kOverlap=false,true}`

## Pod setup

- CDI annotation `cdi.k8s.io/gpu: "nvidia.com/gpu=all"` to inject NVIDIA driver
- `host-lib64` hostPath mount → symlink `libcuda.so.580.126.09`, `libnvidia-ml.so.*` into `/usr/lib/x86_64-linux-gnu/`
- Pod ran `sleep infinity`; build triggered via `kubectl exec` → `nohup /workspace/build.sh`
- Build script delivered via S3: `s3://uccl-ep-ops-788668107894-ap-northeast-1/sprint-a/`
- Orchestrated from local machine → SSM → Tokyo bastion (`i-09e6350406e2eb33a`) → `kubectl` in EKS

## Timeline

| Event | Timestamp |
|---|---|
| p5en nodegroup scale to 1 | 14:04 UTC |
| Node Ready | 14:09 UTC |
| Pod created (v1, had aws CLI dep) | 14:10 UTC |
| Pod re-created (v2, sleep infinity) | 14:14 UTC |
| First build attempt — FAILED at internode_ll.cu:778 (goto-bypass initialization) | 14:22 UTC |
| Fix amended (moved `slot_start` etc. above goto) | 14:24 UTC |
| Build relaunched | 14:24 UTC |
| Build PASSED (EC=0), `ep.cpython-310-x86_64-linux-gnu.so` linked | 14:25 UTC |
| GPU nodegroup scale to 0 | 14:27 UTC |

## Key artifacts

- `build.log` — full build output, ends with `Gate A: PASS`
- Commit: `1304e828 [EP] Sprint A: low_latency_combine overlap kernel path (SM-stripe)`

## Gotchas logged

1. **nvcc rejects `goto` bypassing initialization of local `const int`** — the first build failed because my new `slot_start` / `slot_stride` / `max_blocks_per_expert` variables were declared between the SEND-phase `goto LOW_LATENCY_COMBINE_RECV` and their first use. Fix: declare them before the goto.
2. **`uccl-ep:latest` image has no `aws` CLI** — any S3 traffic from inside the pod has to go via kubectl cp through the bastion.
3. **Image does not include tmux** — use `nohup` + background `&` instead of `tmux new-session`.
