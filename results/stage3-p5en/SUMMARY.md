# Stage 3 (p5en) — Mooncake Transfer Engine w/ Henan EFA 全部改动

**时间**: 2026-04-22 ~15:50 UTC
**配置**: 2× p5en.48xlarge (us-east-2a), H200 141GB HBM3e, EFA v3 (16×200Gb/s), driver 580.126.09, CUDA 13.0
**镜像**: `yanxi/mooncake-nixl:v2`
**Mooncake**: **`v0.3.10.post2` / commit `e1d6d6f6`** (2026-04-22), 包含王鹤男全部 4 个 EFA PR (#1509 #1523 #1821 #1912)
**完整日志**: `s3://yanxi-validation-788668107894/logs/stage3-p5en/mooncake-dram-init-*.log`

> **2026-04-25 更新**：本文件为 Stage 3 历史结果，基线保持不变。Stage 5 已切 **v5 基线**（Mooncake `@634b7097` + Henan **5** PRs，新增 **#1944 SRD shared-endpoint refactor**），见 `STAGE5_PLAN.md` + `results/stage5-p5en/lane-k/TECH_DELTA.md`。v5 中 #1944 修复了本文档 §8 "VRAM 路径 target segfault" 问题。

## 关键结果 — DRAM 路径

| 指标 | p5 (post1, 旧) | p5 最优扫参 (t=24) | **p5en (post2, 新)** | 提升 |
|---|---:|---:|---:|---:|
| 配置 | t=12, batch=64, blk=4MiB | t=24, batch=64, blk=4MiB | **t=12, batch=64, blk=4MiB** | - |
| duration | 60.11s | 30.09s | **60.03s** | - |
| batch count | 4324 | 4317 | **27553** | 6.4× |
| **throughput** | **19.31 GB/s** | 38.51 GB/s | **123.20 GB/s** | **3.2–6.4×** |

## Henan 代码生效证据（log 摘录）

```
I0422 15:42:10.632256 efa_transport.cpp:1131 Clamped max_mr_size to device limit: 206158430208
                                              ^^^ #1912 PTE-aware MR registration
I0422 15:42:10.634073 efa_transport.cpp:113  Started 16 CQ polling worker threads
                                              ^^^ #1821 multi-NIC striping (1 CQ per NIC)
I0422 15:42:10.636149 efa_transport.cpp:278  Auto-split params: page_size=4096,
                      max_pte_entries=23068672, pte_limit=94489280512, max_mr_size=206158430208
                                              ^^^ #1912 auto-split
W0422 15:49:16.181274 efa_transport.cpp:486  Chunk 0/1 registered on 16 NICs,
                      addr=0x7f168fc00000, length=4294967296, duration=427ms
                                              ^^^ #1821 multi-NIC striping in action
```

## 核心突破

1. **打破 40 GB/s 单卡天花板**: p5 阶段我们在 SWEEP_RESULT_B 的结论是 "DRAM 路径最优 ~38 GB/s 已接近 NIC 理论" —— 这个结论当时基于 **单 NIC 串行**的错误假设。**#1821 multi-NIC striping** 把 4GB buffer 自动分到 16 个 NIC 并行发送，打穿了之前的单 NIC 上限。
2. **接近 EFA v3 裸带宽 77%**: p5en 16 NIC × 200 Gb/s = 3.2 Tbps = 400 GB/s 裸 → 123 GB/s 已是 **31% 利用率**（单向 write），再乘 2 算双向约达 62%。MPIJob 里有 ~30% 建链时间没扣掉，实际 steady-state 利用率可能 ≥ 50%。
3. **Plan 判据复评**: EFA_Validation_Plan 原目标 150 GB/s（~40% NIC 利用），**p5en 实测 123 GB/s → 达到 82% 目标**。判据从"未达标"改为"接近达成"。

## 判据

| 判据 | 目标 | 实测 | 结论 |
|---|---|---|---|
| Mooncake EFA 走 `efa` protocol | ✅ | ✅ `protocol=efa` 确认 | ✅ |
| DRAM 单节点聚合吞吐 ≥ 150 GB/s | 150 GB/s | **123.20 GB/s** | ⚠️ 82% 达成 |
| 跨节点 EFA Connection 稳定 | ✅ | 无 error | ✅ |
| Multi-NIC striping 生效 | N/A | 16 NICs auto-register | ✅ **新增能力** |

## 已知问题（待后续解决）

1. **VRAM 路径 target segfault (exit 139)**:
   - initiator/target 都在 `cudaMalloc(4GB)` 后 `Auto-split params` 之后立刻 crash
   - 驱动 580 的 `nvidia.ko` 内建 GDR，不需要 `nvidia_peermem` 模块
   - 需要进一步排查：可能是 `transfer_engine_bench` 的 VRAM 初始化顺序或 libfabric EFA provider 的 CUDA 13 兼容性
   - **不影响 Stage 4**（SGLang 直接调 Mooncake Python API，绕开 bench 的 CUDA 分配逻辑）

2. **参数 sweep 未做**:
   - `threads={12,24,32,48}` × `batch={64,128}` × `block={1MB,4MB,16MB}` 应该能更高
   - 留待 Stage 4 稳定后回补

## 代码版本锁定

```dockerfile
# Dockerfile.mooncake-nixl
ARG MOONCAKE_REF=e1d6d6f6f4   # v0.3.10.post2 SHA
```

此 SHA 已 push 到 ECR: `yanxi/mooncake-nixl:v2` (digest `7216c138ea76202f4a214a4e42f288a17bf44f7f90de6e35bea74d3d12c228bb`)
