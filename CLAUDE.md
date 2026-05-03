# CLAUDE.md — efa-validation

Project-specific context for Claude Code. Loaded at session start.

## Project
JD × AWS 言犀/JoyAI 共创 EFA 验证 repo。目标：在 AWS EKS + EFA v2 上复现客户（JD）生产栈 SGLang PD 1P:1D + Mooncake KV + UCCL-EP，给 750B/1T MoE 模型出端到端性能数据。所有动作脚本化入仓，不写 `/tmp`；每步更新 `RUNBOOK.md`。

## Layout（2026-05-03 cleanup 后）
- `RUNBOOK.md` — Stage 1-4 执行流水 + 决策日志（历史记录，不改）
- `EFA_Validation_Plan.md` / `STAGE5_PLAN.md` — 总方案 + 当前阶段计划
- `archive/stage1-4/` — Stage 1-4 历史 manifest + Dockerfile 冻结归档（附 README 索引）
- `stage2-uccl-ep/` — Stage 2 UCCL-EP validation MPIJob（活跃）
- `manifests/stage5-p5en/` — Stage 5 主线 manifest + customer-*（GLM / Kimi / Qwen / DSV31）
- `common/` — 当前活镜像 Dockerfile（客户 customer-h200 双 variant + Stage 5 v5-uccl / mooncake-nixl-v6 / uccl-ep）+ BUILD_MATRIX 权威 pin 表 + sglang-launcher.sh
- `scripts/` — `build-*.sh` / `fsx-*.sh` / `*-prefetch*.sh` / `sps-*.sh` / `stage5-*.sh` 等幂等工具
- `results/stage*-*/` + `STAGE1-4_P5EN_SUMMARY.md` + `NG_INVENTORY.md` — 权威测量数据，不脑补
- `ssm-payloads/` — 发给 bastion 的 SSM 命令文件（Stage 5 活，Stage 1-4 已归档）
- `customer_K2.5/` / `customer_K2.5_0429/` / `customer_glm_5.1/` / `repro/k2-5-segfault/` — 客户现场环境 compose / entrypoint
- `docs/` — 定位/背景（MOONCAKE/NIXL/UCCL_VS_NCCL）+ KNOWLEDGE_BASE + HENAN PR 评审 + P5EN 模型矩阵

## Sibling repos（相关但独立）
- `../uccl-ep-optimization/` — UCCL-EP on EFA 推理优化研究（2026-05-03 从本 repo 分离：34 设计文档 + 3 上游 PR 工作区 + Hopper mem-ordering microbench）
- `../uccl-ep-optimization/uccl/` — `KevinZhao/uccl` fork（upstream `uccl-project/uccl`），2026-05-03 挪进 sibling repo 作 nested repo（自带 `.git`，父 repo `.gitignore` 排除）

## Clusters & bastions
| Region | Cluster | Bastion |
|---|---|---|
| us-east-2 (Ohio, 主) | `gpu-cluster-ohio` | `i-0341d214635c1ca74` |
| us-west-2 (Oregon, fallback) | `gpu-cluster-oregon` | `i-081b2b010b6af530c` |

所有 `kubectl` 都通过 bastion 经 SSM 发起（EKS 私有 API）。本机无 kubeconfig。

## 模型权重加载规则（硬性）
- **一律从 regional S3 拉到节点本地 NVMe**；sglang `--model-path` 只指本地路径
- **禁** FSx（跨 AZ + 并发 mmap 慢 8×）、**禁** HF 直拉（匿名限流）、**禁** 跨 AZ 共享
- FSx 只保留 `manifests/fsx/` 模板作历史参考，已标 deprecated

## Image chain（BUILD_MATRIX.md 为权威）
客户交付（public ECR `public.ecr.aws/n3l4x8f3/sglang-mooncake-{uccl,nccl}`）:
- 2026.04.28-h200.5（默认 release）
- **2026.05.02-h200.dp16**（Mooncake PR #2023 tip `4a306de8`，DP>1 根因修复，大 DP 用户必须）

内部 Hopper 调优（private ECR `788668107894.dkr.ecr.us-east-2.amazonaws.com/yanxi/*`）:
```
base-cuda-efa:v1/v2    (archived, ECR tag 还在)
    └─> mooncake-nixl:v5/v6.1    (Mooncake @634b7097 + Henan 5 PRs)
            └─> sglang-mooncake:v5       (SGLang 0.5.10)
                    └─> sglang-mooncake:v5-uccl (+ UCCL-EP + deep_ep wrapper)
uccl-ep:v2             (Stage 2 microbench，冻结)
```
跨 region 走 ECR 拉。升级 CUDA major 必须全链 rebuild（每层 10–15 min）。

## GPU 资源纪律
- **禁止 On-Demand / Capacity Block**，纯 Spot
- 机型优先级：p6e > p6-b300 > p6-b200 > p5en > p5（兜底）
- 每次测试前先 `aws ec2 get-spot-placement-scores` 找 score≥6 的 AZ，再建 NG
- Spot 波动剧烈（单 AZ 几小时内 4→1 都见过），拿到后立即跑完
- NG 建/改只用 `KevinZhao/eks-cluster-deployment`（已内置本地 NVMe LVM）
- 跳过机型：p4d/p4de/p5e（deprecated SPS 不扫）
- **所有测试必须 single-AZ**（多节点 run 全部同 AZ；PD-disagg 跨 AZ 会挂）

## Working style
- 测试优先级：**跑通 > 数据完整 > 成本**
- 用 Agent tool 并行派 subagent 做独立任务
- 不搞 DeepEP（已验证不可行），路径锁定 UCCL-EP + Mooncake + Henan sglang PR
- Blackwell 坑位：`--attention-backend=flashinfer`（不能 fa3）、`--enable-eplb` 要 ep_size>1
- UCCL-EP on EFA 必须 `SGLANG_DISAGGREGATION_NIXL_BACKEND=LIBFABRIC`（UCX 默认会 fallback TCP 挂死）

## Current stage
见 `RUNBOOK.md` 末尾 + `STAGE5_PLAN.md` + `results/stage5-p5en/`。

**2026-05-03 状态**：
- 客户镜像 `2026.05.02-h200.dp16`（Mooncake PR #2023 `4a306de8`）已上 public ECR，解决大 DP 连接风暴
- Stage 5 PD 1P1D A/B（Mooncake vs NIXL LIBFABRIC）完成 S1–S6（含 60K/120K 长 context），README.md index 已补；见 `results/stage5-p5en/pd-1p1d-mc-vs-nixl-k25-int4/`
- Stage 1-4 / UCCL-EP 优化研究已分别归档到 `archive/stage1-4/` 和 sibling repo `../uccl-ep-optimization/`
