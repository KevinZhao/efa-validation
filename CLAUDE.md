# CLAUDE.md — efa-validation

Project-specific context for Claude Code. Loaded at session start.

## Project
JD × AWS 言犀/JoyAI 共创 EFA 验证 repo。目标：在 AWS EKS + EFA v2 上复现客户（JD）生产栈 SGLang PD 1P:1D + Mooncake KV + UCCL-EP，给 750B/1T MoE 模型出端到端性能数据。所有动作脚本化入仓，不写 `/tmp`；每步更新 `RUNBOOK.md`。

## Layout
- `RUNBOOK.md` — 逐步执行日志 + 决策 + 失败/修复，是 session 之间的权威状态
- `EFA_Validation_Plan.md` / `STAGE5_PLAN.md` — 总方案 + 下一阶段计划
- `stage{1..4}-*/` — 分阶段 manifests + README
- `scripts/` — `fsx-*.sh` / `build-*.sh` / `prefetch-*.sh` 等幂等工具
- `manifests/fsx/pv-pvc.yaml.tpl` — FSx PV/PVC 模板
- `common/Dockerfile.*` — `base-cuda-efa` / `mooncake-nixl` / `sglang-mooncake` 镜像链
- `results/stage*-*/` — 实际 benchmark 输出 + 报告（权威数据源，不要脑补）
- `logs/` — 运行日志
- `ssm-payloads/` — 发给 bastion 的 SSM 命令文件

## Clusters & bastions
| Region | Cluster | Bastion |
|---|---|---|
| us-east-2 (Ohio, 主) | `gpu-cluster-ohio` | `i-0341d214635c1ca74` |
| us-west-2 (Oregon, fallback) | `gpu-cluster-oregon` | `i-081b2b010b6af530c` |

所有 `kubectl` 都通过 bastion 经 SSM 发起（EKS 私有 API）。本机无 kubeconfig。

## FSx Lustre（模型权重唯一缓存）
- Ohio: `fs-0e7e1313a9c964d34` mount=`5w7shb4v` AZ=us-east-2b SG=`sg-062ae2f53a5e61e49`
- Oregon: `fs-079832d056597a33b` mount=`tjvijb4v` AZ=us-west-2b SG=`sg-0c2f826221429c8f3`
- PV/PVC `yanxi-model-cache` RWX 2400 Gi, StorageClass `fsx-lustre-static`
- **所有模型权重都必须走 FSx**，禁止每节点 HF 重复下载到 hostPath/NVMe
- 跨 AZ 不可 mount — 用 FSx PVC 的 pod 必须调度到 FSx 所在 AZ

## Image chain
```
base-cuda-efa:v3  (CUDA 13.0.2 + NCCL 2.27.5 + sm_90/100/103)
    └─> mooncake-nixl:v5  (Mooncake @634b7097 含 Henan #1944 + UCX 1.19)
            └─> sglang-mooncake:v5  (SGLang 0.5.10)
```
ECR: `788668107894.dkr.ecr.us-east-2.amazonaws.com/yanxi/*`，跨 region 走 ECR 拉。
升级 CUDA major 必须全链 rebuild（每层 10–15 min）。

## GPU 资源纪律
- **禁止 On-Demand / Capacity Block**，纯 Spot
- 机型优先级：p6e > p6-b300 > p6-b200 > p5en > p5（兜底）
- 每次测试前先 `aws ec2 get-spot-placement-scores` 找 score≥4 的 AZ，再建 NG
- Spot 波动剧烈（单 AZ 几小时内 4→1 都见过），拿到后立即跑完
- NG 建/改只用 `KevinZhao/eks-cluster-deployment`（已内置本地 NVMe LVM）

## Working style
- 测试优先级：**跑通 > 数据完整 > 成本**
- 用 Agent tool 并行派 subagent 做独立任务
- 不搞 DeepEP（已验证不可行），路径锁定 UCCL-EP + Mooncake + Henan sglang PR
- Blackwell 坑位：`--attention-backend=flashinfer`（不能 fa3）、`--enable-eplb` 要 ep_size>1

## Current stage
见 `RUNBOOK.md` 末尾 + `STAGE5_PLAN.md` + `results/stage5-p5en/`。

**2026-04-25 状态**（Stage 5 Day 1，p5en × 2 起跑）：
- Stage 5 正式切 **v5 基线**：`yanxi/sglang-mooncake:v5` ← `yanxi/mooncake-nixl:v5`（Mooncake @`634b7097` + Henan 5 EFA PRs #1509/#1523/#1821/#1912/**#1944**）
- R0 smoke **PASS**（2026-04-24 Oregon p5en，Qwen3-Next-80B FP8，e2e 296 ms）—— 见 `results/stage5-p5en/r0-smoke/`
- R1a（Kimi-K2 1P:1D）2026-04-25 03:35Z 起跑 Ohio us-east-2a，03:56Z 切到 v5 镜像 —— 见 `results/stage5-p5en/r1a-kimi-k2-1p1d/20260425T033552Z/BUILD_V3.md`
- 旁路：Stage 6.5（B300 CUDA 13 全栈升级 + Mooncake #1944 DRAM 283 GB/s / VRAM 97 GB/s）已完成但未落地 `results/stage6-v3-upgrade/`，数据在 session memory 中；Stage 7 Kimi K2 v5 端到端等 p6-b300 Spot 回来。
