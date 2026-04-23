# Stage 1 (p5en) — EFA v3 NCCL 基础链路

**时间**: 2026-04-22 ~15:30 UTC
**配置**: 2× p5en.48xlarge (us-east-2a), 16× H200, EFA v3 (16 NIC × 200 Gb/s), GPU Operator v25.10.1, driver 580.126.09, CUDA 13.0
**镜像**: `788668107894.dkr.ecr.us-east-2.amazonaws.com/yanxi/nccl-tests:v2` (复用 p5 镜像)
**完整日志**: `s3://yanxi-validation-788668107894/logs/stage1-p5en/`

## all_reduce_perf 8KB–8GB (busBW, out-of-place)

| Size | p5 (旧) | **p5en (新)** | delta |
|---:|---:|---:|---:|
| 128 MB | 311.55 GB/s | **315.60 GB/s** | +1% |
| 512 MB | 402.93 GB/s | **409.58 GB/s** | +2% |
| 1 GB | 442.20 GB/s | **444.75 GB/s** | +0.6% |
| 4 GB | 467.43 GB/s | **467.35 GB/s** | 持平 |
| **8 GB** | **476.91 GB/s** | **479.97 GB/s** | +0.6% |

- **Avg bus bandwidth (几何平均)**: 172.31 → **178.94 GB/s** (+4%)
- **all_to_all avg**: 36.07 → **37.10 GB/s** (+3%)

## 判据

| 判据 | 目标 | p5en 实测 | 结论 |
|---|---|---|---|
| 跨节点 all-reduce 大消息 ≥ 320 GB/s | 320 GB/s | **479.97 GB/s @ 8GB** | ✅ **+50% 超过判据** |
| FI_PROVIDER=efa 生效 | EFA | 日志确认 | ✅ |
| all-to-all 曲线平滑 | 无尖峰 | 平滑 | ✅ |

## 关键观察

1. **p5en 和 p5 持平**（略好 1-4%）: EFA v3 没显著提升跨机带宽。这符合预期——p5en/p5 的 EFA aggregate bandwidth 都是 3.2 Tbps，架构差异主要在 HBM（141GB vs 80GB）和 NIC 数量（16×200G vs 32×100G）。
2. **H200 NVLink 加速对跨机 all-reduce 无帮助**: 瓶颈在 EFA，不在 GPU。
3. **无崩溃、无 NaN、无 wrong=N/A**: Stage 1 完全健康。

## 下一步

Stage 2/3/4 继续在 p5en 上跑，对比 p5 的旧结果。
