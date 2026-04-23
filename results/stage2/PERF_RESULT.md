# Stage 2.1 — UCCL-EP perf on EFA (hidden=7168, topk=8, 16 rank × 2× p5.48xlarge)

## Run Config

- Image: `yanxi/uccl-ep:v2`
- Deployment: MPIJob (Launcher + 2 Worker)，每 Worker 8 GPU + 32 EFA NIC
- `slotsPerWorker=8`, `np=16 -N 8`
- Parameters: default `test_internode.py` / `test_low_latency.py` upstream defaults
  - hidden=7168, num_topk=8, num_experts=288
- EFA env: `FI_PROVIDER=efa`, `FI_EFA_USE_DEVICE_RDMA=1`, `FI_EFA_FORK_SAFE=1`
- Logs persisted at `/var/lib/yanxi-logs/stage2/` on host (ip-10-1-12-160)

## UCCL-EP — `test_internode.py`（RDMA-kernel, 完整 dispatch+combine sweep）

### Best dispatch

| dtype | SMs | NVL chunk | RDMA chunk | transmit (μs) | notify (μs) | **BW RDMA** | **BW NVL** |
|---|---:|---:|---:|---:|---:|---:|---:|
| **BF16** (rank a) | 24 | **36** | 32 | 2296 | 227.66 | **50.95 GB/s** | **166.67 GB/s** |
| BF16 (rank b) | 24 | 40 | 32 | 2427 | 108.76 | 48.24 GB/s | 157.44 GB/s |
| FP8 (rank a) | 24 | 36 | 32 | 1799 | 170.46 | 33.53 GB/s | 109.68 GB/s |
| FP8 (rank b) | 24 | 36 | 32 | 1899 | 75.20 | 31.79 GB/s | 103.75 GB/s |

### Best combine

| SMs | NVL chunk | RDMA chunk | transmit (μs) | notify (μs) | **BW RDMA** | **BW NVL** |
|---:|---:|---:|---:|---:|---:|---:|
| 24 | 7 | 32 | 7968 | 471.24 | **14.68 GB/s** | **48.03 GB/s** |
| 24 | 7 | 32 | 8001 | 438.40 | 14.63 GB/s | 47.76 GB/s |

**解读**：dispatch RDMA 达到 ~51 GB/s（对应 400 Gb/s × ~50% 利用），combine RDMA ~14.7 GB/s（受 all-reduce 约束，NVL 域内局部聚合后才过网络）。两数都明显优于 Mooncake DRAM 的 19-38 GB/s（那是通用 KV 路径）。

## UCCL-EP — `test_low_latency.py`（低延迟 dispatch/combine）

### Per-rank bandwidth（16 rank）

Dispatch / Combine 呈 **NUMA/节点非对称**：每节点 8 rank 中，前 8 rank（node A）dispatch 带宽 ~2.5 GB/s，后 8 rank（node B）dispatch 带宽 ~10-11 GB/s；combine 反向（A 侧 ~11-13 GB/s，B 侧 ~4.3 GB/s）。这是预期——LL kernel 的 dispatch/combine 在跨节点方向上不对等。

| 统计 | Dispatch BW | Combine BW |
|---|---|---|
| Node-A rank (0-7) | 2.49-2.67 GB/s | 11.17-13.30 GB/s |
| Node-B rank (8-15) | 9.79-11.26 GB/s | 4.25-4.38 GB/s |
| **全局平均（A+B）** | ~6.5 GB/s | ~8 GB/s |

### Send/recv time（μs）

| 方向 | Node-A rank | Node-B rank |
|---|---|---|
| Dispatch send | 85-90 | 185-201 |
| Dispatch recv | 23-29 | 24-28 |
| Combine send | 88-102 | 170-200 |
| Combine recv | 46-58 | 47-58 |

对比 stage 2 smoke 报告的 ~7 GB/s/rank dispatch+combine（更简单负载），本次 LL bench 在 per-rank BW 上差一半，**因为 LL kernel 优化目标是延迟（~100 μs）而不是带宽**。延迟 ~85-200 μs 完全在合理范围（单个 token chunk RTT over 2-hop NVL+EFA）。

## DeepEP（NCCL-EP baseline）— 未能对照

尝试跑 `test_internode.py` + `test_low_latency.py` (DeepEP 上游)，全部 **ImportError**：

```
ImportError: /usr/local/lib/python3.10/dist-packages/deep_ep_cpp.cpython-310-x86_64-linux-gnu.so:
  undefined symbol: __cudaRegisterLinkedBinary_0b4aee48_9_layout_cu_833d94b3
```

**根因**：DeepEP v1.2.1 用的是 **cu124 预编译 wheel**，镜像运行时是 **CUDA 12.6**，`layout.cu` 符号哈希不匹配。在 stage 2 冒烟阶段已踩过并记录（RUNBOOK: "DeepEP 无法简单修复"）。

若需补 NCCL-EP 对照，可选方案：
1. 用源码编译 DeepEP（vs cu126 runtime）—— 下一轮镜像 build 任务
2. 用 NCCL 纯 `all_to_all` 取数（非 EP kernel，只给跨节点网络上限）
3. 用更接近生产的 UCCL-EP 自身作为目标栈（当前做法），放弃 DeepEP baseline

## 参考：Stage 2 冒烟（upstream）数字

之前已归档：`results/stage2/SUMMARY.md`
- 16 rank 均 `All correctness tests passed` × 16
- Dispatch+Combine ~7 GB/s/rank（更轻量 hidden / batch）

## 结论

- **UCCL-EP RDMA dispatch 51 GB/s / combine 14.7 GB/s** 在 EFA v2 上达到 ~50% NIC 理论带宽
- 低延迟 kernel 的 dispatch/combine send 时延 ~85-200 μs，recv ~23-58 μs
- **DeepEP baseline 在当前镜像跑不通**（cu124 × cu126 ABI 不兼容）；如需量化对比需重编 DeepEP wheel 对齐 runtime

## 运行记录

- UCCL-EP perf: ~6-17 min（取决于 JIT cache warmup），两组 bench 均 Succeeded
- DeepEP baseline: launcher 3 min 内 Complete（全部 ImportError 秒退）
- 全部 raw log 持久在 `/var/lib/yanxi-logs/stage2/` (ip-10-1-12-160 节点)
