# R6 B300 — RESULT

**Status**: ⚠️ **ABORT** — sglang 0.5.10 / Triton PTX codegen 不支持 B300 `sm_103a`
**Run stamp**: 20260425T144609Z
**Cluster / Region / AZ**: gpu-cluster-oregon / us-west-2 / usw2-az2（硬同 AZ）
**Node count**: 2 × p6-b300.48xlarge Spot，~1.3 node-hour 总消耗

## 一句话结论

**Mooncake EFA v5 在 B300 上首次端到端初始化 PASS（含 PR #1944 SRD shared endpoint + 16 NIC × 412 GB MR）；但 sglang 0.5.10 的 Triton JIT 在 B300 (sm_103a) 上 `ptxas exit 255` 无法 compile，阻断 e2e bench。**

## 今日在 B300 上拿到的**可用数据**

### 1. B300 硬件规格实测订正（重要！文档过时了）

| 项 | 文档旧值 | **实测新值** |
|---|---|---|
| compute capability | (10, 0) | **(10, 3)** / sm_103a |
| HBM / GPU | 180 GB | **275 GB (+53%)** |
| HBM / node (8 GPU) | 1.44 TB | **2.2 TB** |
| sglang `avail mem/GPU` | N/A | **265.27 GB** (扣 system overhead 后) |
| `/data` (instance-store LVM) | — | **28 TB xfs**（LT v6 userdata 自动条带）|

### 2. Mooncake v5 在 B300 EFA v3 上初始化 PASS（首次实测）

来自 prefill + decode 两 pod 的 libfabric 输出：

```
EFA device (libfabric): rdmapXXXs0, domain: rdmapXXXs0-rdm,
                        provider: efa (shared endpoint, max_wr=256)
EfaTransport: Initialized EFA device
EfaTransport: Clamped max_mr_size to device limit: 412316860416  (412 GB)
EfaTransport: Started 16 CQ polling worker threads
Auto-split params: page_size=4096, max_pte_entries=23068672,
                   pte_limit=94489280512, max_mr_size=412316860416
Chunk 0/1 registered on 16 NICs, length=524288, duration=4ms
```

**关键数字 B300 vs p5en**（对 Stage 6.5 计划有参考价值）：

| Mooncake init param | p5en (EFA v2) | **B300 (EFA v3)** |
|---|---|---|
| `max_mr_size` | ~195 GB | **412 GB (×2.11)** |
| `pte_limit` | ~47 GB | **94 GB (×2.0)** |
| `max_pte_entries` | ~11.5 M | **23 M (×2.0)** |
| CQ polling worker threads | 16 | 16 |
| MR register duration | 6-8 ms | 4-12 ms |

### 3. Image/software stack 实测内容（v5 preflight 输出）

```
torch       2.9.1+cu128
cuda        12.8
arch_list   sm_70/75/80/86/90/100/120  ← 没 sm_103，这是 e2e fail 的根因之一
Mooncake    0.3.10.post2 @ 634b709 (含 #1944 SRD)
sglang      0.5.10
```

### 4. 操作性学习

| 发现 | 价值 |
|---|---|
| LT v6 userdata 在 B300 上 **确认工作**（auto-LVM /data 28 TB） | 和 p5 NG 一样，不用手动 setup-nvme |
| B300 v5 镜像第一次拉取 ~4-6 min（13 GB，Oregon ECR → az2 节点） | 后续从 ECR 到同 az 节点就秒起（缓存命中）|
| HF download 一次 16-worker，GLM-4.6 337 GB **第二节点 2m53s** 完成 | HF CDN 在 Oregon 同 region 缓存命中 |
| EKS MNG 改 ASG subnet 后进 **DEGRADED**，`update-nodegroup-config` 被锁 | 要先修 ASG subnets 恢复原 config，EKS 才重新 reconcile |
| `--disable-cuda-graph` **不能** disable Triton piecewise kernel | sglang 0.5.10 的 decode 仍会 Triton JIT，在 B300 上继续 fail |

## Topology（尝试过）

| Role | Pod | Node | GPU | EFA |
|---|---|---|---|---|
| prefill | 1 | p6-b300 (usw2-az2) | 8 | 16 |
| decode  | 1 | p6-b300 (usw2-az2) | 8 | 16 |
| lb      | 1 | 同 decode 节点      | 0 | 0 |

## Bench 数据

**❌ 未采集**（prefill SIGQUIT 阻断）。用于下次（Stage 6.5 后）R6 重做的基准对照锚仍是：

| 指标 | R3 GLM-4.6 1P:1D Oregon p5 same-AZ |
|---|---|
| Total tok/s | 2315 |
| Mean TTFT | 1226 ms |
| Median TTFT | 590 ms |
| Mean TPOT | 27.7 ms |
| P99 TPOT | 35 ms |
| Request throughput | 3.00 req/s |

**Bench 配置（下次复用）**: rate=4 req/s, 128 prompts, random dataset, ISL=1024, OSL=512。

## Root Cause

### 第一次 fail：CUDA graph capture

```
ptxas --gpu-name=sm_103a /tmp/*.ptx → exit 255
PTXASError: Internal Triton PTX codegen error
NoTritonConfigsError → Capture cuda graph failed
```

### 第二次 fail（加 --disable-cuda-graph 后）：Triton piecewise kernel

Prefill pod 进入 running phase 后，lb `/health` probe 触发 sglang `health_generate` → 实际走 decode 路径 → Triton-JIT 的 fused MoE kernel → 又 compile `sm_103a` → `ptxas exit 255` → sglang `running_phase_sigquit_handler` 把 process tree kill。

**根本原因**：v5 镜像里 torch 2.9.1 + Triton 版本不支持 sm_103a target arch。要修必须升级到 CUDA 13 + 对应的 Triton wheel（= Stage 6.5）。

## 节点/成本收工状态

- ✅ 两 B300 已 shutting-down（15:59 / 16:00 UTC 开始）
- ✅ ASG desired=0
- ✅ ASG subnet 恢复 4 AZ（让 EKS NG 自愈 DEGRADED）
- ✅ K8s resources 全清理（deployments / services / configmaps / job / pod）

## 下次重做 R6 的条件

在 Stage 6.5 CUDA 13 全栈升级完成前不要再起 B300：

1. Rebuild `base-cuda-efa` → v3 (CUDA 13.0.2 + driver 580 + cuDNN)
2. Rebuild `mooncake-nixl:v5` 基于新 base
3. Rebuild `sglang-mooncake:v5` 基于新 mooncake，用 torch 2.10 或 2.9 B300 patch
4. **Preflight 必须验证**：
   - `torch.cuda.get_arch_list()` 含 `sm_103`
   - Triton 空 kernel `ptxas --gpu-name=sm_103a` 测试通过（exit 0）
5. 然后才 apply R6a 到 2 × B300 same-AZ usw2-az2

## 产出文件

```
results/stage5-p5en/r6-b300/20260425T144609Z/
├── STEPS.md    # 完整时间线（preflight → prefetch → 2× 起机器 → 2× 尝试 apply → abort → 收工）
├── RESULT.md   # 本文
└── ABORT.md    # 详细 root cause + 数据 + 运维总结

manifests/stage5-p5en/
├── r6-b300-preflight.yaml              # 单 pod preflight（通过）
├── _prefetch-hf-glm46-b300.yaml        # 2 node prefetch（通过）
└── r6a-glm46-1p1d-v5-b300-az2.yaml     # R6a 主 manifest（带 --disable-cuda-graph，最终 ABORT）
```

## 对 Stage 5 Day 1 summary 的 delta

Day 1 结论之一是 "p5en Spot 今天不可用"。今天 late 追加观察：
- **Oregon p6-b300 Spot SPS=9 已回来**（usw2-az2 only，single-AZ reality）
- **Oregon p5en Spot SPS=9 回来**（usw2-az3 和 use2-az2）
- 这些窗口仍可用于 **不依赖 Triton JIT 的 Mooncake microbench**（Lane K），无需 Stage 6.5
