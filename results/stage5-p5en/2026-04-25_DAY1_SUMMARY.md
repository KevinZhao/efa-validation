# Stage 5 Day 1 — 2026-04-25 执行总结

> **核心收获**：Mooncake v5（含 PR #1944 SRD shared-endpoint）在 EFA 上**首次端到端跑通 PD-disaggregation**。拿到 R1a (Kimi-K2) + R3 (GLM-4.6) 两条 baseline，同时暴露 4 条新工程约束（跨 AZ KV 不行 / Spot 回收丢 NVMe / Qwen3 FP8 TP=8 upstream bug / Ohio LT 是旧版）。

## 今日战绩

| Run | 拓扑 | 模型 | 状态 | 核心数字 |
|---|---|---|---|---|
| **R1a** | 2×p5en 1P:1D (Ohio use2-az1) | Kimi-K2-Instruct-0905 (1T FP8, 959 GB) | ✅ **PASS** | 1412 tok/s total, TPOT P50 46 ms / P99 101 ms, TTFT P50 3.3 s / P99 25.6 s |
| R1b | 3×p5en 1P:2D (Ohio) | Kimi-K2 | ⚠️ **ABORT** | Spot 3 台同时回收，擦了 2.9 TB `/mnt/nvme` 权重 |
| R3 (跨 AZ) | 3×p5 1P:2D (Oregon az1/2/3) | GLM-4.6-FP8 (355B, 370 GB) | ⚠️ **ABORT** | 所有 pod Ready，首请求挂 `TransferEncodingError`；Mooncake KV 跨 AZ 不工作 |
| **R3 (same-AZ)** | 2×p5 1P:1D (Oregon usw2-az2) | GLM-4.6-FP8 | ✅ **PASS** | **2315 tok/s** total, TPOT P50 29 ms / P99 35 ms, TTFT P50 590 ms / P99 5.3 s |
| R4 | 3×p5 1P:2D (Oregon) | Qwen3-235B-A22B-FP8 | ⚠️ **ABORT** | sglang 0.5.10 block-FP8 fused MoE 启动前 ValueError（`192 % 128 ≠ 0`） |

**同 bench 配置**（rate=4 req/s, 128 prompts, ISL=1024, OSL=512）下 R1a vs R3 直接对比：

| 指标 | R1a Kimi-K2 (H200 141G) | R3 GLM-4.6 (H100 80G) | Δ |
|---|---|---|---|
| Total tok/s | 1412 | **2315** | +64% |
| Request throughput | 1.83 req/s | **3.00 req/s** | +64% |
| Mean TTFT | 7329 ms | **1226 ms** | -83% |
| Median TTFT | 3344 ms | **590 ms** | -82% |
| Mean TPOT | 47.7 ms | **27.7 ms** | -42% |
| P99 TPOT | 101 ms | **35 ms** | -65% |
| Mean ITL | 48.0 ms | **27.8 ms** | -42% |

> **不是"公平"A/B**：不同 GPU（H200 141G vs H100 80G）、模型大 2.6×、quant path 不同（block-FP8 vs compressed-tensors）。两个数据点是 Stage 5 grid 上的两个独立坐标。

## 关键突破

### 1. Mooncake v5 / PR #1944 SRD shared-endpoint 在 EFA 上**首次端到端 PASS**
- R1a/R3 两个 PD-disagg run 都有 launcher log 明确显示 `libfabric efa (shared endpoint, max_wr=256)` + `Started 16 CQ polling worker threads`
- R1a 前期的 "2h stuck" 曾被误判为 PR #1944 regression，实际是 FSx 跨 AZ OST locking；**v2 和 v5 的 worker loop 源码字节级一致**，诊断后纠正（见 `r1a-kimi-k2-1p1d/20260425T033552Z/ROOT_CAUSE_FINAL.md`）
- 为 Lane K microbench 的 Mooncake 基线提供了"系统正常工作点"锚

### 2. 跨 AZ FSx 大模型必须 hostPath（FSx PVC 不可用）
- R1a 首次尝试用 FSx PVC 挂 Kimi-K2（959 GB、62 shards），8×TP 并发 mmap 触发 OST locking + 跨 AZ RTT 放大 → 18 min 累计 1.1 TB、聚合 1 GB/s（Stage 4 本地 NVMe 是 8 GB/s，8× 慢）
- hf_transfer 16-worker 并行直下 HF CDN：**两节点 15 min 完成 959 GB**（~1 GB/s / 节点，2 GB/s 聚合）
- Stage 5 R1b/R1c/R2/R5 这类单模型 > 500 GB 都要走 hostPath，不再用 FSx PVC 做大权重加载

### 3. EKS Launch Template **自动挂本地 LVM** 已经在 Oregon 生效
- Oregon p5 NG `gpu-p5-48xlarge-spot` 的 LT v4 使用了 `KevinZhao/eks-cluster-deployment` 仓库的 `GPU_ENABLE_LOCAL_LVM=true` userdata
- 节点起来自动：7 × 3.5 TB instance-store → `vg_local/lv_scratch` 条带 xfs → `/data` (27.6 TB)
- **不需要**再跑 `setup-nvme.sh`，R3 Oregon run 直接用 `hostPath: /data/models`
- Ohio `gpu-p5en-spot-useast2a` 的 LT `lt-0200be32f4401a715 v1` 是老版 userdata，只把 1 个 NVMe 给 containerd，剩下 7 个闲置——需要手动 mdadm 或 LT 升级
- 下次起 GPU NG 优先用该仓库

### 4. PD-disaggregation Mooncake KV **必须同 AZ**
- R3 三个 pod 分布在 usw2-az1/az2/az3 时：所有 pod 1/1 Ready，EFA enum 正常，**但第一个 warmup 请求就挂** `TransferEncodingError: Not enough data to satisfy transfer length header`
- 收窄到 2 × p5 同 usw2-az2 后：128/128 PASS，43 秒跑完
- 推测是 Mooncake EfaTransport 的 bootstrap (port 8998) endpoint + RKey 交换在跨 AZ EFA fabric 下握不上手；生产流量的 ClusterIP 健康检查不敏感
- **以后所有 PD run 默认同 AZ**（NG 覆盖多 subnet 时用 pod `nodeSelector: topology.kubernetes.io/zone=<az>`）

### 5. Qwen3-235B-A22B-FP8 在 sglang 0.5.10 **TP=8 不工作**
- `moe_intermediate_size=1536`，TP=8 下 per-rank 192，与 `weight_block_size[1]=128` 不整除
- sglang 的 block-FP8 fused MoE kernel 启动前 ValueError `192 % 128 ≠ 0`
- 可行 TP：1/2/3/4/6；TP=4 在 p5 上只用 4 GPU 浪费显存
- 对比 GLM-4.6-FP8 同 `moe_intermediate_size=1536` 但用 compressed-tensors quant → 无此约束
- R4 暂时 park 等 sglang upstream 修

## 关键踩坑 + 解决（今日新增）

| 问题 | 原因 | 修复 |
|---|---|---|
| FSx rsync 跨 AZ 30 MB/s，959 GB 要 8h | Lustre OST locking + 跨 AZ RTT | 换 `hf download --max-workers 16 --HF_HUB_ENABLE_HF_TRANSFER=1`，双节点并行 15 min |
| `dnf install coreutils` in AL2023 image 冲突 `coreutils-single` | 不同包名 | `dnf install -y --allowerasing rsync` |
| DS daemonset 两个 rsync 并行把 FSx 带宽打爆 27 MB/s | FSx OST contention | 序列化跑（结果还是慢，最终换 HF hub） |
| `setup-nvme.sh` 在 p5 上 `nvme1n1 busy` | 其中 1 个 NVMe 被 LT 自动借给 vg_data/lv_containerd | p5 版脚本：先 `pvs` 过滤掉 LVM 盘，7 盘条带（但 Oregon 已有 LT v4 auto-LVM，不用跑） |
| R3 跨 AZ warmup 挂 TransferEncodingError | Mooncake KV handshake 跨 AZ | pod pin 到 az2 单 AZ |
| R4 Qwen3-235B 启动 ValueError 192%128 | sglang block-FP8 fused MoE | 换 GLM-4.6-FP8（同 ctx dim, compressed-tensors quant 无此约束） |
| R3 decode pod 第一次被 evicted | node ephemeral-storage 压力（80 Ki 剩余） | 删掉 25h 前的 Stage 4 残留 Deployment 释放空间 |
| ASG VPCZone narrow 被 EKS 回退 + NG DEGRADED | EKS MNG 不让改 subnet | 直接 terminate 非目标 AZ 实例 → ASG 在允许 subnet 里重建 |
| R1b Ohio 3 台 Spot 同时回收 | Spot 市场波动 + NG 追 desired | instance-store 上的 2.9 TB 权重全丢；下次靠 HF 重取，不指望 NVMe 持久 |

## 版本 / ECR 锁定

```
788668107894.dkr.ecr.{us-east-2,us-west-2}.amazonaws.com/yanxi/:
├── sglang-mooncake:v2    (Stage 4 baseline，v2 基线 = 4 Henan PRs)
└── sglang-mooncake:v5    (Stage 5 baseline，v5 = 4 + PR #1944 SRD)
                          digest sha256:aeabf6819cabf5be5a50cc1edffcd4609c6917c0bfd1ded8ab9ea8a81ba47a70
                          Mooncake commit 634b7097
                          Ohio 构建、Oregon 镜像（scripts/stage5-mirror-ecr.sh）
```

## 当前节点状态（今日收尾）

| Cluster | NG | desired | 实例数 | 备注 |
|---|---|---|---|---|
| gpu-cluster-ohio | gpu-p5en-spot-useast2a | 0 | 0 | ACTIVE |
| gpu-cluster-ohio | 其他预建 NG | 0 | 0 | 未用 |
| gpu-cluster-oregon | gpu-p5-48xlarge-spot | ASG 0 | 3 shutting-down | EKS NG health DEGRADED（ASG 已恢复 4 subnet，缓存自愈中） |
| gpu-cluster-oregon | gpu-p5en-48xlarge-spot / gpu-p6-b300 | 0 | 0 | 未用 |

今日用量（Spot 计费窗口）：
- Ohio p5en: 2 台 × ~5h = 10 node-hour
- Oregon p5: 3 台 × ~2h = 6 node-hour（扩容过程 + R4/R3 双阶段）

## Spot 容量观察（今日 SPS 快照）

| 机型 | Ohio | Oregon |
|---|---|---|
| p5en.48xlarge | 1 全线 | 1 全线 |
| p5.48xlarge | 1 (use2-az3 早期 9) | **9 (az1/az2/az3), 1 (az4)** |
| p5e.48xlarge | 1 | 1 |
| p6-b200.48xlarge | 1 | 1 |
| p6-b300.48xlarge | — | 1 (az2 only) |
| g7e.48xlarge | 3 (az2) | 3 (az1) |
| p4d.24xlarge | 3 | 9 (az3) |

**结论**：能跑 Kimi-K2 / GLM / DSv3.1 的 Spot 窗口今天只剩 **Oregon p5 (H100 80G)**。p5en / p6 全线 SPS=1，要等 AWS 容量池释放。

## 新沉淀的 5 条永久记忆 + 1 条更新

（位于 `~/.claude/projects/-home-ec2-user-workspace-efa-validation/memory/`，不进 git，跨 session 可召回）

1. `feedback_fsx_crossaz_hostpath.md` — 跨 AZ FSx 大模型必须先 hostPath 到本地 NVMe
2. `feedback_spot_reclaim_wipes_nvme.md` — Spot p5en 回收会擦除 `/mnt/nvme` 已预取权重
3. `feedback_no_ondemand_spot_only.md` — 不用 On-Demand，永远走 Spot + 重扫 SPS
4. `feedback_same_az_for_pd_disagg.md` — PD-disagg Mooncake KV 必须同 AZ
5. `feedback_qwen3_235b_fp8_tp8_unsupported.md` — sglang 0.5.10 + Qwen3-235B-A22B-FP8 TP=8 不兼容
6. `reference_eks_gpu_node_deploy_repo.md` (更新) — 确认 Oregon p5 LT v4 已是新版

## 文件索引

```
results/stage5-p5en/
├── r1a-kimi-k2-1p1d/20260425T033552Z/
│   ├── STEPS.md                   # 完整时间线（5h 含 FSx→NVMe 诊断弯路）
│   ├── RESULT.md                  # PASS 数据 + 结论
│   ├── ROOT_CAUSE_V5.md           # 最初错误诊断（归咎 PR #1944）
│   ├── ROOT_CAUSE_FINAL.md        # 纠正：FSx 跨 AZ 是真因
│   └── BUILD_V3.md                # v3 vs v5 镜像对比
├── r1b-kimi-k2-1p2d/20260425T091545Z/
│   └── ABORT.md                   # Spot 回收
├── r3-glm46-1p2d/20260425T110000Z/
│   └── ABORT.md                   # 跨 AZ KV handshake 挂
└── r3-glm46-1p1d/20260425T115000Z/
    └── RESULT.md                  # PASS（same-AZ fix）

manifests/stage5-p5en/
├── _prefetch-hf-to-nvme.yaml           # R1a Kimi-K2 HF prefetch → /mnt/nvme (Ohio)
├── _prefetch-hf-qwen3-235b-oregon.yaml # R4 (aborted) prefetch
├── _prefetch-hf-glm46-oregon.yaml      # R3 GLM-4.6 HF prefetch → /data (Oregon)
├── r1a-kimi-k2-1p1d-v5-hostpath.yaml   # R1a PASS manifest
├── r1b-kimi-k2-1p2d-v5-hostpath.yaml   # R1b ABORT manifest
├── r3-glm46-1p2d-v5-hostpath-oregon.yaml      # R3 ABORT（跨 AZ）
├── r3-glm46-1p1d-v5-hostpath-oregon-az2.yaml  # R3 PASS（same-AZ）
└── r4-qwen3-235b-1p2d-v5-hostpath-oregon.yaml # R4 ABORT manifest
```

## Day 2+ 优先级（重排后）

原计划 Day 2 做 R1b Kimi-K2 + Lane K microbench。新顺序：

**Day 2（2026-04-26）**：
- **[等 p5en Spot] R1b Kimi-K2 1P:2D 3 节点**（Ohio 同 AZ）— 拿 PD 曲线第二个点
- **R3 长 ctx sweep**（ISL=128k / 200k）— 2 × p5 Oregon same-AZ，已验证 same-AZ OK
- **Lane K microbench 起始**：`transfer_engine_bench` 两节点点对点（同 AZ + 跨 AZ）验证 Mooncake KV 跨 AZ 是否 microbench 层就挂；如果是，交给 Lane K bisect

**Day 3**：
- R1c Kimi-K2 1P:3D 4 节点（PD 曲线右端）
- R2 DSv3.1 TP=16 跨节点探索（或等上游 TP=8 FP8 支持 cross-node）

**Day 4**：
- R4 Qwen3-235B **park**（等 sglang upstream 修 block-FP8 TP alignment）
- R5 GLM-5.1 FP16 准备

**Day 5**：
- Lane E UCCL-EP microbench + 上游 PR 推进

## 一句话总结

**Mooncake v5 PR #1944 确实能打，但需要同 AZ；Qwen3-235B-A22B-FP8 TP=8 需要 sglang 上游修；Ohio p5en Spot 今天不可用要等。**
