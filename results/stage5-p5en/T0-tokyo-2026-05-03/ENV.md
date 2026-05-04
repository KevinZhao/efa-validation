# T0 Baseline — Environment Snapshot

**Date**: 2026-05-03 06:30-06:56 UTC
**Task ID**: T0 (DEVELOPMENT_AND_VALIDATION_PLAN §2)
**Purpose**: Reproduce PR #745 post-baseline dispatch 174.9 µs / combine 326.7 µs on our stack; validate N1 `PER_EXPERT_BATCHING=1` lever

## Region / Cluster
- AWS Region: `ap-northeast-1` (Tokyo)
- EKS Cluster: `yanxi-eks-tokyo` (Kubernetes 1.35)
- Availability Zone: `ap-northeast-1a` (= apne1-az4)
- SPS at launch: **score 7** for p5en.48xlarge in apne1-az4

## Nodes
- **rank0**: `i-076b0a149e56cc12e` → node `ip-10-99-10-213.ap-northeast-1.compute.internal` (10.99.10.213)
- **rank1**: `i-0951b129c3a66a07c` → node `ip-10-99-10-95.ap-northeast-1.compute.internal` (10.99.10.95)
- Both: `p5en.48xlarge`, SPOT, AL2023 x86_64, kernel `6.12.79-101.147.amzn2023.x86_64`
- GPU: 8× NVIDIA H200 SXM5, driver `580.126.09`, compute_cap 9.0
- EFA: 16 NICs per node (1 primary + 15 EFA-only)

## Software
- Image: `788668107894.dkr.ecr.us-east-2.amazonaws.com/yanxi/uccl-ep:latest` (sha `a1be0d5b785e`, pushed 2026-04-21)
- CUDA: 12.6.r12.6 (compiler.34841621_0)
- PyTorch: 2.5.1+cu124, GLIBCXX_USE_CXX11_ABI=0
- Python: 3.10.12
- nanobind: installed inside container
- EFA userspace: libfabric `/opt/amazon/efa/bin/fi_info` (from image)

## UCCL
- Repository: `uccl-project/uccl` (GitHub)
- SHA: **`dd9573ddb980141c432a875bbafed1376b8bb408`** = `[UK] oob refactor (#902)`, head of `main` branch as of 2026-04-25
- build method: `make -j192 PER_EXPERT_BATCHING={0,1}` inside container (NOT `build.sh` which is a docker-in-docker wrapper that doesn't work from inside a pod)
- Install: `python3 setup.py install` → `/usr/local/lib/python3.10/dist-packages/uccl/ep.cpython-310-x86_64-linux-gnu.so`

## Runtime config
- containerd: `enable_cdi = true`, `default_runtime_name = "nvidia"`, `SystemdCgroup = true`
- CDI spec: `nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml` (42 KB)
- nvidia-device-plugin: v0.15.0, `DEVICE_LIST_STRATEGY=envvar`, `PASS_DEVICE_SPECS=true`
- Pod metadata annotation: `cdi.k8s.io/gpu: "nvidia.com/gpu=all"` — this is the load-bearing bit that injects libcuda.so + device nodes

## Bench command
```
cd /opt/uccl/ep
LD_LIBRARY_PATH=/usr/local/lib/python3.10/dist-packages/torch/lib:$LD_LIBRARY_PATH \
  FI_PROVIDER=efa FI_EFA_USE_DEVICE_RDMA=1 \
  torchrun --nnodes=2 --nproc_per_node=8 --node_rank=$RANK \
    --master_addr=uccl-bench-rank0.uccl-bench-rdzv.uccl-bench.svc.cluster.local \
    --master_port=12355 \
  bench/test_low_latency.py --num-tokens=128 --hidden=7168 --num-topk=8 --num-experts=288
```

## Resource request per pod
- `nvidia.com/gpu: 8`
- `vpc.amazonaws.com/efa: 16`
- `hugepages-2Mi: 5120Mi`
- `memory: 256Gi`
- HostPath `/data` mount (LVM striped scratch)

## Bench runs
6 runs total: PEB={0,1} × run{1,2,3}, all in `raw/`. Each run is torchrun 2-node 16-rank, `test_low_latency.py` default 10 iterations.

## Known gotchas
1. `build.sh` doesn't work inside pod (it tries to `docker run` a builder container). Direct `make -j$(nproc)` is the right path when already inside the bench container.
2. `PASS_DEVICE_SPECS=true` alone doesn't mount host `libcuda.so` — the `cdi.k8s.io/gpu` pod annotation is what makes the whole CUDA library tree visible.
3. Pod annotation `cdi.k8s.io/gpu: "nvidia.com/gpu=all"` requires `/etc/cdi/nvidia.yaml` to exist on the node (`nvidia-ctk cdi generate` once per node).
4. Bench expects `LD_LIBRARY_PATH` to include torch/lib; UCCL uccl.ep .so links against it but rpath isn't set.
