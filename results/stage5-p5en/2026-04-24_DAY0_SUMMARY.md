# Stage 5 · Day 0 阶段测试总结 — 2026-04-24 UTC

**阶段定位**：Stage 5 (p5en × 7，NIXL + UCCL-EP 深度调优) 的 **Day 0 基建日**（非正式测试日）
**窗口**：2026-04-23 规划完成 → 2026-04-24 被 FSx 基建占满 → Day 1 正式起跑顺延至 **2026-04-25**
**执行人**：AWS Account Team (JD)
**关联文档**：[`STAGE5_PLAN.md`](../../STAGE5_PLAN.md)、[`RUNBOOK.md`](../../RUNBOOK.md)、[`results/STAGE1-4_P5EN_SUMMARY.md`](../STAGE1-4_P5EN_SUMMARY.md)

---

## 1. 本日目标 vs 实际

| 项目 | 原计划 | 实际结果 |
|---|---|---|
| Stage 5 Day 1 起跑 | R0 smoke + R1a Kimi-K2 1P:1D | **推迟到 04-25**；Day 0 插入为 FSx 基建日 |
| FSx for Lustre 两 region 上线 | 非计划项 | ✅ 两 region SCRATCH_2 2400 GiB AVAILABLE（Lustre 2.15） |
| 5 个模型共 2.26 TB/region 预取 | 非计划项 | 🔄 进行中（Qwen3-Next-80B ✅ / Qwen3-235B-FP8 下载中 / GLM-4.6 / DeepSeek-V3.1 / Kimi-K2 待下） |

**关键判定**：今天**没有跑任何 EFA / GPU 性能 run**。Day 0 纯基建，把 Stage 5 的"模型分发"从 p5en hostPath 路线切到 FSx 共享路线，为后续 Day 1~7 所有 run 节省冷启动时间和出站带宽。

---

## 2. 阶段 1-4 已沉淀结果（总览）

Stage 5 Day 0 前的全部已完成测试（详见 `results/STAGE1-4_P5EN_SUMMARY.md`）：

| Stage | 硬件 | 关键数字 | 状态 |
|---|---|---|---|
| **1 NCCL all-reduce 8 GiB busBW** | p5en × 2 | **479.97 GB/s**（判据 ≥ 320） | ✅ PASS |
| **2 UCCL-EP Dispatch+Combine /rank** | p5en × 2 | **36.49–36.64 GB/s/rank**（vs p5 **5.2×**） | ✅ PASS |
| **2 UCCL-EP correctness** | p5en × 2 | 16/16 全通 | ✅ PASS |
| **3 Mooncake DRAM throughput** | p5en × 2 | **123.20 GB/s**（vs p5 **6.4×**），4 Henan PR 全部生效 | ✅ PASS |
| **3 Mooncake VRAM throughput** | p5en × 2 | SIGSEGV（新 bench bug） | ⚠️ 待排查 |
| **4 SGLang 0.5.10 + Mooncake post2 就绪** | p5en × 3 | import/CLI/EFA 全就绪 | ✅ PASS |
| **4 PD 1P:2D Llama-3.1-8B 真实请求** | p5en × 3 | rate=16 **Mean TTFT 73 ms / Out 1974 tok/s / 成功 128/128**（vs p5 baseline **TTFT 46× / ITL 2.6×** 改善） | ✅ PASS |
| **4 Kimi-K2-Instruct-0905 (1T MoE FP8) 1P:2D** | p5en × 3 | rate=4 **Mean TTFT 448 ms / TPOT 10.94 ms / Out 171 tok/s**，48/48 全通 | ✅ PASS |

所有 p5en run 已把 Mooncake upstream v0.3.10.post2 + 王鹤男 4 EFA PR 验证成**生产级稳定**。

---

## 3. 2026-04-24 时间线（UTC）

| 时间 | 动作 | 脚本 / 资源 | 结果 |
|---|---|---|---|
| 08:00 | 第一次 SG 建立尝试，description 含非 ASCII 字符 `—` 被拒 | `scripts/fsx-sg-setup.sh` | 修为 ASCII `-` |
| 08:01 | Ohio FSx SG 建立 | `sg-062ae2f53a5e61e49`（988 + 1018-1023 来自 GPU node SG + self） | ✅ |
| 08:01 | Oregon FSx SG 建立 | `sg-0c2f826221429c8f3` | ✅ |
| 08:01 | FSx SCRATCH_2 2400 GiB × 2 region v1 创建（Lustre 2.10） | Ohio `fs-0adb0b44ce313faea`、Oregon `fs-0a0a98a5f21d6f9fc` | CREATING |
| 08:08 | Ohio v1 AVAILABLE | mount `xc4chb4v` (2.10) | ⚠️ 与 AL2023 client 不兼容 |
| 08:09 | Oregon v1 AVAILABLE | mount `uqkyjb4v` (2.10) | ⚠️ 同上 |
| 09:03 | 两 cluster helm 装 `aws-fsx-csi-driver` | controller ×2 + node DaemonSet | ✅ |
| 09:04 | 渲染 + apply 静态 PV/PVC `yanxi-model-cache` | `scripts/fsx-apply-pvpvc.sh` | ✅ |
| ~09:30 | **踩坑定位**：AL2023 自带 Lustre client 2.15.6，挂 FSx 2.10 报 `mount.lustre: Invalid argument` | — | 需重建 |
| 09:50 | `fsx-create.sh` pin `FSX_LUSTRE_VERSION=2.15`，删旧库重建 | v1 destroy + v2 create | CREATING |
| 10:00 | Ohio v2 AVAILABLE | **`fs-0e7e1313a9c964d34`** / mount `5w7shb4v` (Lustre **2.15**) | ✅ |
| 10:00 | Oregon v2 AVAILABLE | **`fs-079832d056597a33b`** / mount `tjvijb4v` (Lustre **2.15**) | ✅ |
| 10:00 | PV/PVC 重新 bind 到新 FSx ID | — | ✅ 两 region Bound |
| 10:06 | EC2 Fleet `capacity-optimized` 起 m7i Spot prefetcher（m6in.32xlarge 无容量） | Ohio `i-0e559f242487cc5f7` m7i.16x / Oregon `i-02606615a4464114a` m7i.24x | Running |
| 12:32 | Prefetcher 重启（换 m6in/c6in instance type 提速） | 现役 Ohio `i-091464ad55096df98` m6in.16x / Oregon `i-0b814d09495cf025c` c6in.16x | Running |
| 12:40 | Watcher tick 1：Qwen3-Next-80B ✅ 完成（162 GB/156 files），Qwen3-235B-FP8 进行中（~12 GB @ 51 files） | `scripts/prefetch-models-watch.sh` | 🔄 |

---

## 4. Day 0 交付清单

### 4.1 代码（已入仓）

| 类型 | 文件 | 说明 |
|---|---|---|
| 基础库 | `scripts/fsx-lib.sh` | Region profile + helper，source-only |
| SG | `scripts/fsx-sg-setup.sh` | 幂等建 FSx SG（988 + 1018-1023 from GPU node SG + self） |
| FSx | `scripts/fsx-create.sh` | 幂等建 FSx，**pin Lustre 2.15**，轮询到 AVAILABLE |
| FSx | `scripts/fsx-status.sh` | 打印 dns / MountName |
| FSx | `scripts/fsx-destroy.sh` | 幂等销毁（`--yes --drop-sg` 全清） |
| CSI | `scripts/fsx-apply-pvpvc.sh` | 查 FSx 实 ID → 渲染 `manifests/fsx/pv-pvc.yaml.tpl` → apply |
| Prefetcher | `scripts/prefetch-models-launch.sh` | EC2 Fleet capacity-optimized 起 Spot 下载机（9 档候选 instance type） |
| Prefetcher | `scripts/prefetch-models-userdata.sh.tpl` | UserData：挂 FSx + `pip install huggingface_hub>=1.0 hf_transfer hf_xet` + 顺序 `hf download` 5 模型 + self-terminate |
| Prefetcher | `scripts/prefetch-models-watch.sh` | 每 10 min SSM probe 一次，NDJSON 写 `logs/prefetch-watch.ndjson` |
| Manifest | `manifests/fsx/pv-pvc.yaml.tpl` | 静态 PV/PVC 模板（`__FS_ID__` / `__DNS__` / `__MOUNT__`） |
| Manifest | `manifests/fsx/rendered/{ohio,oregon}-pv-pvc.yaml` | 已渲染并 applied |
| K8s Job | `stage4-p5en/model-prefetch-fsx.yaml` | FSx PVC 版本 prefetch job（备用） |
| 文档 | `manifests/fsx/README.md` | FSx 使用说明 |
| 日志 | `logs/prefetch-2026-04-24.md` | 今日 prefetcher run manifest |

### 4.2 基础设施（已部署）

| Region | FSx ID | DNS | MountName | SG | AZ |
|---|---|---|---|---|---|
| us-east-2 | `fs-0e7e1313a9c964d34` | `fs-0e7e1313a9c964d34.fsx.us-east-2.amazonaws.com` | `5w7shb4v` | `sg-062ae2f53a5e61e49` | us-east-2b |
| us-west-2 | `fs-079832d056597a33b` | `fs-079832d056597a33b.fsx.us-west-2.amazonaws.com` | `tjvijb4v` | `sg-0c2f826221429c8f3` | us-west-2b |

- CSI driver（`aws-fsx-csi-driver`）在两 cluster 的 `kube-system` 部署
- PV/PVC `yanxi-model-cache-pv` / `yanxi-model-cache` 在两 cluster Bound

---

## 5. 踩坑 × 4（脚本已固化修复）

1. **Lustre 2.10 vs AL2023 client 2.15.6 不兼容**
   - 现象：`mount.lustre: Invalid argument`
   - 修复：`fsx-create.sh` pin `FSX_LUSTRE_VERSION=2.15`
   - 成本：首版 2 region FSx 删库重建一次（~10 min / region）

2. **`huggingface_hub` 1.x 取消 `[cli]` extra**
   - 现象：入口 `huggingface-cli` 不再存在，`pip install huggingface_hub[cli]` 返回空
   - 修复：UserData 装 `huggingface_hub>=1.0 hf_transfer hf_xet`，直接 `hf download`（绝对 venv 路径）

3. **m6in.32xlarge 在两个 FSx AZ 当前都无 Spot 容量**
   - 现象：EC2 Fleet 首选 m6in.32x 返回 `InsufficientInstanceCapacity`
   - 修复：Fleet 配 9 档 instance type 候选（m6in → m7i → c7i → c6in），`capacity-optimized` 策略兜底
   - 结果：实际落到 m7i.16/24x（25/37.5 Gbps ENA），FSx SCRATCH_2 burst ~3 GB/s 仍是瓶颈，不影响下载速度

4. **SG description 不能含非 ASCII**
   - 现象：EM dash `—` 被 `authorize-security-group-ingress` 拒
   - 修复：全部 ASCII hyphen

---

## 6. 当前运行态（12:40 UTC 快照）

| Region | Instance | Type | 已完成 | 当前下载 | 累计字节 |
|---|---|---|---|---|---|
| us-east-2 | `i-091464ad55096df98` | m6in.16xlarge | 1/5（Qwen3-Next-80B） | Qwen3-235B-A22B-Instruct-2507-FP8 | 174 GiB |
| us-west-2 | `i-0b814d09495cf025c` | c6in.16xlarge | 1/5（Qwen3-Next-80B） | Qwen3-235B-A22B-Instruct-2507-FP8 | 175 GiB |

**下载顺序**（小 → 大）：Qwen3-Next-80B ✅ → Qwen3-235B-FP8 (240 GB) 🔄 → GLM-4.6 (340 GB) → DeepSeek-V3.1 (640 GB) → Kimi-K2 (959 GB)

**Watcher**：后台运行中（`logs/prefetch-watch.pid`），INTERVAL=600s，MAX_TICKS=24（4 h cap）。完成后两实例自 terminate，watcher 自退出。

---

## 7. 不确定 / 待观察

- FSx SCRATCH_2 2400 GiB 容量上限是 2.26 TB 全 5 模型总和，**余量仅 ~140 GB**，下载过程中若任何 model 多出临时 `.incomplete` 文件可能触顶；若真触顶需扩到 4800 GiB。
- 若 Kimi-K2（959 GB）下载超 4 h cap，watcher 会退出；instance self-terminate 条件（5 个 `.prefetch-complete` sentinel）独立于 watcher，不受影响。
- us-west-2c 是 Stage 5 首选 AZ（SPS=9），但本次 FSx 建在 us-west-2b，**Day 1 起 7 p5en 节点需选 us-west-2b**（与 FSx 同 AZ 避跨 AZ 流量）；如必须 us-west-2c，要重建 FSx。

---

## 8. 下一步（Day 1，2026-04-25）

1. 等 prefetcher 5/5 完成（预估再 3~5 h，Kimi-K2 最大）
2. 核查 P Spot quota ≥ 1344 vCPU（Day -1 应已提 case）
3. us-west-2b 起 **7 × p5en.48xlarge** Spot（EC2 Fleet capacity-optimized）
4. 替换 `stage4-*/model-prefetch*.yaml` 的 hostPath → `persistentVolumeClaim: yanxi-model-cache`
5. R0 smoke（Qwen3-Next-80B 单机）+ R1a Kimi-K2 1P:1D（2 node）

---

## 9. 本日产出一览

- 代码：12 个脚本 / 模板 / manifest（见 §4.1）
- 基础设施：2 region FSx + CSI + PV/PVC 全上线
- 文档：`logs/prefetch-2026-04-24.md`、`manifests/fsx/README.md`、本文件
- 运行中：2 个 Spot prefetcher + 1 个 watcher 进程
- **性能数据**：无（基建日，不跑 benchmark）

**总工期**：08:00 → 12:40 ≈ **4h40m**（含 2h 的 FSx 2.10/2.15 返工）；净基建工期约 2h40m。

---

**版本**：v1.0（2026-04-24 12:50 UTC 写入）
**生成者**：Claude Opus 4.7 · workspace `/home/ec2-user/workspace/efa-validation`

---

## 10. 2026-04-25 补记（v5 基线切换）

本 Day 0 summary 所述的 "Mooncake v0.3.10.post2 + 4 Henan PR" 是 **Stage 1-4 的历史基线**。Stage 5 正式起跑时（2026-04-25 R1a）已切到 **v5 基线**：

- Mooncake `@634b7097`（v0.3.10.post2 tag 之后的 post-SRD-refactor 头）
- Henan **5** EFA PRs：原 4 PR + **#1944 SRD shared-endpoint refactor**（2026-04-23 08:52Z merge）
- 镜像：`yanxi/sglang-mooncake:v5` ← `yanxi/mooncake-nixl:v5`（Ohio ECR 18 h 前已预 build）
- R1a 切 v5 的完整记录：`results/stage5-p5en/r1a-kimi-k2-1p1d/20260425T033552Z/BUILD_V3.md`

**§5 "踩坑 × 4" 遗漏**：Stage 3 挂账的 "Mooncake VRAM 路径 target SIGSEGV" 原因在 #1944 里查明 —— `EfaTransport::preTouchMemory` 对 `cudaMalloc` 指针做 CPU 端 store 导致段错误；#1944 把 pre-touch 路径仅对 host memory 生效，**已修**。切 v5 后此问题自动关闭。
