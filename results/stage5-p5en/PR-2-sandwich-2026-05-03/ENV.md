# PR-2 Stub Non-regression Sandwich — Environment Snapshot

**Date**: 2026-05-03 12:07-12:16 UTC
**Purpose**: Gate B non-regression evidence for the DeepEP-compatible overlap kwargs stub PR.

## Hardware

- 2× p5en.48xlarge spot instances in `ap-northeast-1a` (`apne1-az4`)
  - `i-06b54f475da1b5b6b` (10.99.10.63) — rank0 pod
  - `i-0d57a015aa90c3c3a` (10.99.10.212) — rank1 pod
- H200 × 8 per node, driver 580.126.09
- SPS score at acquisition time: **8** (Tokyo apne1-az4)

## Software stack

- EKS cluster: `yanxi-eks-tokyo` (K8s 1.35)
- AMI: Amazon Linux 2023.11.20260413
- Kernel: 6.12.79-101.147.amzn2023.x86_64
- Container image: `788668107894.dkr.ecr.us-east-2.amazonaws.com/yanxi/uccl-ep:latest`
  - CUDA 12.6.2, Python 3.10.12, PyTorch 2.5.1+cu124, NCCL 2.21.5
  - NVCC 12.6 r12.6, G++ 11.4.0
- UCCL upstream main SHA: `fb4147a2` [P2P] Added congestion control support (#837)
- Stub patch: `patches/combine-signal-api/0001-ep-combine-overlap-kwargs-stub.patch` (8350 bytes, 64 insertions)

## Build config (all 3 sandwich phases)

- `PER_EXPERT_BATCHING=0` (default, PR #745 lever off — to exclude N1 lever noise from sandwich)
- `SM=90` (explicit override; `nvidia-smi --query-gpu=compute_cap` unavailable inside container)
- `make -j$(nproc)` (not `build.sh`, which requires docker-in-docker)
- Full clean between phases: `find . -name "*.o" -delete; rm -rf build`

## Bench config

- `torchrun --nnodes=2 --nproc_per_node=8 --node_rank={0,1}` (EP=16)
- `--master_addr=uccl-bench-rank0.uccl-bench-rdzv.uccl-bench.svc.cluster.local --master_port=12355`
- `test_low_latency.py --num-tokens=128 --hidden=7168 --num-topk=8 --num-experts=288`
- `--pressure-test-mode=0` (default, single perf bench per torchrun)
- FP8 dispatch, bf16 combine, return_recv_hook=False (from test_low_latency.py default)

## Pod infra

- CDI spec `/etc/cdi/nvidia.yaml` regenerated per node (`nvidia-ctk cdi generate`)
- Pod annotation `cdi.k8s.io/gpu: "nvidia.com/gpu=all"` to trigger NVIDIA runtime injection
- `host-lib64` hostPath mount → `/host-lib64` inside pod
- Pod-init symlinks host `libcuda.so.580.126.09` and `libnvidia-ml.so.*` into `/usr/lib/x86_64-linux-gnu/` so torch and NCCL can find them
- `LD_LIBRARY_PATH=/usr/local/lib/python3.10/dist-packages/torch/lib` for bench runs

## Sandwich timeline

| Phase | Build finish | Runs | Binary |
|---|---|---|---|
| baseline-pre | 12:06:36 UTC | 12:07:32 / 12:07:58 / 12:08:26 | `fb4147a2` (upstream main) |
| patched | 12:10:10 UTC | 12:11:30 / 12:11:56 / 12:12:26 | `fb4147a2` + stub patch |
| baseline-post | 12:14:09 UTC | 12:15:05 / 12:15:31 / 12:15:59 | `fb4147a2` (re-clean-built) |

## Non-obvious gotchas encountered (logged for memory)

1. **`build.sh` fails inside pod** — expects docker-in-docker. Must use `make -j SM=90 PER_EXPERT_BATCHING=$PEB` directly.
2. **`nvidia-smi` not in container PATH** — Makefile's `DETECTED_SM := $(shell nvidia-smi ...)` evaluates to empty; must explicitly `SM=90`.
3. **Pod-init script needs both libcuda AND libnvidia-ml symlinks** — torch needs libcuda, NCCL needs libnvidia-ml.
4. **`build.sh`'s verify step doesn't set LD_LIBRARY_PATH**, so `import uccl.ep` fails even after successful build. Not a real failure.
