# Stage 5 验证方案 —— 7 台 p5en × 1 周，NIXL + UCCL-EP 深度调优

**时间**：2026-04-23 规划，执行窗口 2026-04-24 ~ 2026-04-30（**7 天**）
**进度**：04-24 实际被 FSx 基建吃掉（Lustre 2.10/2.15 版本返工 + HF 1.x API 断裂 + m6in Spot 无容量）；Day-by-Day 顺延一天，Day 1 起跑对齐 **2026-04-25**。
**作者**：AWS Account Team (JD)
**关联**：`EFA_Validation_Plan.md`（Stage 1-4）、`RUNBOOK.md`（2026-04-21 起）、`results/stage4-p5en/*`
**客户主栈**：SGLang PD 分离 + Mooncake + EFA（客户 fork 不可得，本轮走 **upstream @`634b7097` + Henan 5 EFA PRs** 作为稳定参照；详见 §4.2 的 v5 基线说明）

---

## Changelog

### 2026-04-27 — Lane E §5.8 单节点 UCCL-EP vs NCCL 对比新增

**触发**：客户问到"单节点 MoE 不跨机，UCCL-EP 相比 NCCL 能快多少"。当前 Lane E 主线（§5.3 / §5.5）全部瞄准 2-4 node 跨机场景，**单节点数据完全缺失**，无法直接答。补 §5.8 作为 Lane E 的第 5 个小项，填上这段曲线。

**核心问题**：单节点 TP=EP=8 时，alltoall 走 NVLink / NVSwitch（900 GB/s），**带宽差距被稀释**——但稀疏 permute/unpermute 融合、SM 占用低（DeepEP 20-24 SM vs NCCL ~132 SM）、chunked overlap 三个 lever 仍在。先写出预估，再用实测数字覆盖。

**预估（待 §5.8 实测验证）**：
- alltoall 微观延迟：**1.5–2×**（DeepEP paper H800 NVLink 基础推算）
- MoE decode ITL，不开 overlap：**-10 ~ -15%**
- MoE decode ITL，叠 SBO overlap：**-20 ~ -30%**
- MoE prefill throughput：**-5 ~ -10%**
- 预估来源：DeepEP paper + MoE 58 层 × 220-320 µs alltoall 累计，**没有本项目 p5en 单节点实测数据**

**时机**：Day 4 08:00-12:00（原 buffer 时段），~4 h，不挤 R4 / 故障恢复 / Day 5 Lane E 主线。
**依赖**：§9 Day 2 晚的"UCCL-EP SGLang 接入 pre-task"必须先闭合（同 §5.3）。

### 2026-04-26 — Day 2 R6a B300 ABORT + 镜像栈整理立项

**触发**：2026-04-26 下午 R6a（GLM-4.6-FP8 1P:1D @ 2×p6-b300 usw2-az2）ABORT。Mooncake EFA v5 在 B300 上**初始化 PASS**（shared endpoint max_wr=256、16 CQ、`max_mr_size=412 GB`），但 sglang decode path 走 Triton JIT → `ptxas --gpu-name=sm_103a exit 255` → `Capture cuda graph failed` → `--disable-cuda-graph` 也救不回（Triton piecewise kernel 仍走 JIT）。详见 `results/stage5-p5en/r6-b300/20260425T144609Z/`。

**根因**：当前 `yanxi/sglang-mooncake:v5` 栈是 Hopper-only pipeline：
- `base-cuda-efa:v1` = CUDA 12.6 / NCCL 2.23.4 编译时 `NVCC_GENCODE=compute_90,code=sm_90`，单架构
- `mooncake-nixl:v5` 层 pin `torch==2.4.*`（cu124 wheel，sm_90 only）
- `sglang-mooncake:v5` 层 `pip install sglang[all]==0.5.10` 隐式拉 `flashinfer-python` / `triton==3.1.x` / `vllm-flash-attn`，全是 sm_90 预编译 wheel
- ECR 上存在的 `base-cuda-efa:v3` tag 内容和 v1 一致（4729 MB → 4743 MB），CLAUDE.md 文档里 "v3 = CUDA 13.0.2 + sm_90/100/103" 是**虚构描述**，从未实际 build

**行动**：新增 **§13 镜像栈整理 + Blackwell 分叉**（本次 changelog 条目后的主章节），定义 Hopper / Blackwell 双栈 build matrix、ECR tag 迁移计划、受影响 run 的依赖关系。**该章节在 Stage 5 剩余窗口内不吃 GPU 节点时间，由 builder EC2 异步执行**，不挤占 Lane K / Lane E。

**受阻 run 清单**（需等 Blackwell 栈 ready）：
- R6a / R6b / R6c（B300 上 GLM-4.6 / Kimi-K2 e2e）
- 未来任何 p6-b200 / p6-b300 上的 sglang / uccl-ep / flashinfer attention run
- **不影响** p5 / p5en 上的 Mooncake / NIXL / UCCL-EP / sglang 全部 Hopper 栈 run（Lane K / Lane E / R1-R5 继续走 v5 hopper 栈）

### 2026-04-25 晚 — Day 1 执行结果回填 + Day 2+ 重排

**Day 1 产出**：R1a（Kimi-K2 1P:1D @ 2×p5en Ohio）PASS；R3（GLM-4.6-FP8 1P:1D @ 2×p5 Oregon same-AZ）PASS；R1b/R3 1P:2D/R4 三个 abort 带 ABORT.md。详见 `results/stage5-p5en/2026-04-25_DAY1_SUMMARY.md`。

**5 条新约束纳入**：
- 跨 AZ FSx PVC 不能用于大模型（OST locking + RTT 放大）→ 全部走 HF hostPath
- Spot 回收擦 /mnt/nvme → 每 run 从 HF 重取，不依赖 NVMe 持久化
- **PD-disagg Mooncake KV 必须同 AZ**（跨 AZ 首请求 TransferEncodingError）→ 所有 1P:ND manifest 加 `nodeSelector: topology.kubernetes.io/zone=<az>` 约束；Day 2 Lane K microbench 验证 Mooncake 层是否也挂
- sglang 0.5.10 + Qwen3-235B-A22B-FP8 TP=8 block-FP8 alignment bug（192 % 128 ≠ 0）→ R4 从 Day 1 移到 Day 4，等上游修或换替代模型
- Oregon p5 LT v4 已是新版 auto-mount `/data` 27.6 TB（`KevinZhao/eks-cluster-deployment` 仓库的 `GPU_ENABLE_LOCAL_LVM=true`）；Ohio p5en LT v1 是旧版需手动 mdadm

**Day 2+ 重排要点**：R1b/R1c 前移到 Day 2（条件：Ohio p5en SPS 恢复，当晚已观察到 use2-az2=9）；R3 长 ctx sweep 和 Lane K microbench 同日并行；R4 挪到 Day 4 等 upstream；Day 5/6/7 保持不变。

### 2026-04-25 — 方案 review 后加入的修订（Stage 5 Day 1 当日）

本次修订基于方案 review 指出的结论置信度缺口，全部在当前窗口内用文档 / 脚本调度调整闭合，不新增 GPU 节点，不砍 R3/R4：

**P0（阻塞结论置信度，必做）**
1. §4.4 新增 Lane K 正确性闸门（§4.4 `SWITCH_OBSERVABLES` 旁边加"字节级 + token 级一致性"子项）—— 固定 seed 1000 请求，NIXL vs Mooncake 输出 token match rate；Day 3 末半天完成
2. §4.3 Mooncake baseline 改**背靠背采样**：同一个 2 node pod 内 Mooncake bench → NIXL bench 交替，或同小时各跑一次；不再"借用 R1b 数据"
3. §10 风险矩阵 + Day 6 时间表加 **R5 Go/No-Go pre-flight**（Day 6 尾部 15 min 试加载 GLM-5.1 FP16 看 HBM，决定 Day 7 走哪条 fallback）

**P1（强建议，纳入本轮）**
4. §4.3.2 加 **K-E1' 次优点 E2E 验证**（microbench 次优参数在 SGLang E2E 下复测一次，验证"transport 层最优 ⇒ 推理层最优"假设是否成立）；~2 h，Day 3 内吸收
5. §4.4 故障恢复专项从 30 min 扩到 **4 h**（kill prefill / 断 EFA / OOM 每场景 ≥ 3 次复测）；Day 4 腾窗口（不砍 R3/R4，从 buffer/补跑时段切）
6. §5.2 / §5.6 把 IB 参考线从主性能差值表（`E_VS_NCCL.md`）**移出到独立文件** `IB_REFERENCE.md`，主表只含 EFA 数据；避免读者隐式对齐
7. §5.4 UCCL-EP 正确性闸门在"logits max-abs-diff ≤ 1e-3"之外**加 token match rate ≥ 99%**（greedy, temperature=0, ≥ 64 条短请求）

P2（格式类，本轮**不做**）：Spot 价采样脚注 / P99.9 CI 标注 —— 留到下一轮

### 2026-04-25 晚 — Lane E 附加项（UCCL 上游 PR 自测纳入）

向 UCCL 上游提交了第一个 PR **#904** (`UCCL_EP_CPU_TIMEOUT_SECS` runtime override，解 issue #893/#878)，为让 "AWS benchmark 作为 UCCL 团队的权威验证数据"（见 memory `feedback_uccl_pr_aws_bench.md`）真正闭环，在 §5 Lane E 新增 **§5.7 PR #904 自测项**：

- **Day 5 晚 +1 h**（不挤占其他项）：沿用当日 2 node 镜像，build `sglang-mooncake:v5-uccl-pr904` 跑 3 段 microbench（A baseline f1ecbaf7 / B no-regression a7eb743e / C env=600 生效）+ 非法值 stderr 测试
- **交付**：`results/stage5-p5en/lane-e/pr904-verify/<stamp>/` → 直接贴 PR #904 comment；若 Day 5 SPS 不够延 Day 6 晚；若 Day 5/6 都不起，PR 只附 CPU build log，AWS 数据做 follow-up
- **风险**：~1 h 小项，Fallback 明确（见 §5.7.4），不阻塞 Lane E 主线 E-E1/E2/E3 / §10.1 R5 pre-flight / Day 7 R5

产出归属：若 Stage 5 窗口内 PR merge → `SUMMARY.md` 列为 "上游修复已 upstream"；否则进 `RECOMMENDATIONS.md` Open items。

---

### 2026-04-25 晚 — Lane E 深度收紧（客户定位明确后）

客户定位明确：**Mooncake 已在用，改动小**；NIXL 不强推；**重心在 EP 层** —— 希望本轮能直接呈现 "UCCL-EP 适配 AWS EFA 后的生产可用性" 判断。EP 层在 EFA 上实际只有 NCCL-EP（兜底）和 UCCL-EP（OSDI'26 首发路径）两个选项，DeepEP / pplx-kernels / Mooncake-EP 因硬件或编译原因排除。为让 Lane E 数据直接服务客户决策：

**P0（扎实 UCCL-EP 的生产可用性判据）**
8. §5.4 正确性闸门升级：1000 请求 × 3 模型（Qwen3-235B / Kimi-K2 / DeepSeek-V3.1）× 2 场景（短请求 ISL 128 / 长 ctx ISL 8192）= **6 组闸门**；token match rate 阈值 64→1000 样本，判据 99%→**99.9%**
9. §5.3 扫描分两层剪枝：层 1 "核心 MoE 拓扑" 必扫（~20 组，EP world × hidden × tokens/batch），层 2 "EFA 硬件参数" 在层 1 最优点周围 ±1 档扫；`FI_EFA_FORK_SAFE` / `FI_EFA_USE_HUGE_PAGE` / `FI_MR_CACHE_MONITOR` 固定生产默认值不扫（Stage 2 已验证）
10. §9 Day 1-2 加 pre-task：**UCCL-EP 在 SGLang 0.5.10 的接入路径** 必须 Day 1-2 内查清；上游 main 分支 `--moe-a2a-backend` 不含 `uccl`，需拉 PR patch build `sglang-mooncake:v5-uccl` 或环境变量注入
11. §12 客户对齐清单第 2 条升级为 blocking 前置：Day 1 内回答

**P1（结果可直接服务客户决策）**
12. §5.6 新增交付物 `E_DECISION_TREE.md`：从客户模型 + EP 规模 → 推荐配置的决策树（而非纯参数清单）
13. `E_VS_NCCL.md` 模板必须含免责声明："EP world size 上限 32，客户生产 EP=64+ 的行为需另做规模实验；从 2→4 node 曲线只能给趋势，不外推"

---

## 0. 调整（相对 v1）

v1 方案有三栈对照（SGLang+Mooncake / vLLM+NIXL / Dynamo+NIXL）。按客户最新反馈收敛：

- **vLLM / Dynamo 全砍**：不拉新引擎栈，避免把时间耗在引擎兼容性上。
- **Mooncake 客户 fork 拿不到**：Lane A 用 upstream 跑基线，不再等 fork。
- **重心转到两条**：
  - **Lane K — NIXL**：KV 传输层的深度调优，作为 Mooncake 的**可替代路径**（产出"何时、哪些参数下 NIXL 能追平/超过 Mooncake"）。
  - **Lane E — UCCL-EP**：MoE 通信层的深度调优，给客户一条**EFA 下 all-to-all 的可行路径**（对齐客户国内 DeepEP on IB 的生产行为）。
- **SGLang 作为两条 lane 的共同 host**（不作为被比较对象）。所有对照都在 SGLang 0.5.10 之上做"可插拔组件"替换。
- 目标仍是：**给出可操作的调优参数清单**，不是"栈选秀"。

---

## 1. 约束梳理

### 1.1 客户现状

| 维度 | 现状 |
|---|---|
| 推理引擎 | **SGLang 0.5.10**（Stage 4 已跑通 Kimi-K2 1T FP8） |
| KV 传输 | Mooncake（客户 fork 不可得，本轮 **upstream @`634b7097` + Henan 5 PRs** 做基线，含 #1944 SRD shared-endpoint refactor） |
| 通信 | 国内 IB / 欧洲 EFA 分栈；EFA 分栈整体首发 |
| PD 拓扑 | `1P : ND` 分离（国内生产 1P:1D，Stage 4 做到 1P:2D） |
| 主精度 | **FP8（block fp8, W8A8）** |
| 次要精度 | **FP16/BF16**（仅对照，不作 SLA） |

### 1.2 硬件（本次）

| 项 | 值 |
|---|---|
| 规模 | **4 × p5en.48xlarge**（32 × H200 141GB / 4.5 TB HBM）——2026-04-24 下调（原 7，quota / 容量现实约束） |
| 单机互联 | NVLink 900 GB/s |
| 跨机互联 | EFA v3 16 × 200 Gb/s = 3.2 Tbps/node |
| 选址 | us-east-2a（SPS=8/10，cap=7 扫描，2026-04-24 13:01 UTC）；备选 us-west-2c（SPS=6） |
| Quota（US 商业） | All P Spot 1152 vCPU，**4 节点 = 768 vCPU → 现有 quota 够用**（1344 vCPU 申请已撤回） |
| 时间 | **7 天**（含 buffer） |
| 成本上限 | ~$6,000 Spot |

### 1.3 风险项

1. **EFA-EP 整体是首发**：DeepEP 原生为 IB，UCCL-EP on EFA 是 OSDI'26 论文路径，端到端从未在生产压力下跑过。风险集中在 all-to-all 的有效带宽、长尾、正确性。
2. **NIXL on EFA 深度未知**：Stage 3 已通 smoke，但没做过真实 KV 工作点的参数扫描。`UCX_TLS` / NIXL plugin / 内存注册方式 / 多 NIC striping 的组合对性能影响巨大。
3. **FP16 仅收尾一跑**：旗舰 MoE FP16 @ 7 node 不划算；但客户指定最后追加 **GLM-5.1 FP16 单 run** 作为收尾画像（R5），使用已调优参数，不做 sweep。
4. **Spot 回收**：launcher idempotent、断点可续。

---

## 2. 设计原则

1. **两条调优课题并行，输出"技术差异 + 数字化差值"而非"是否/必须"类结论**（客户信息不足，不做业务定论；把差异具象到数字，让客户自行判定）：
   - **Lane E**：在同一 EFA 硬件下做 **UCCL-EP vs NCCL-EP** 的分层对照（microbench → 端到端），把 dispatch/combine 延迟、有效带宽、TTFT/TPOT、EP 扩展性全部数字化，并**技术差异表**（架构/协议/内存路径/kernel 差异） + **测试差值表**（每个维度的 Δ%）。
   - **Lane K**：在同一 EFA 硬件下做 **NIXL vs Mooncake-EfaTransport(upstream @`634b7097`，含 Henan 5 PR)** 的分层对照。性能数字化的同时，把**栈切换引起的可观测改动点**逐项列出（launcher flag、依赖、日志关键字、镜像大小、冷启动、metadata / agent 需求、故障恢复行为），**只描述"哪里不一样、差多少"**，不直接给"引 / 不引"的结论。
2. **先分层后集成**：
   - 先在 **microbench**（`transfer_engine_bench`、`nixlbench`、`uccl-ep bench`、DeepEP bench）上扫参数，拿到"KV 层最优点"与"EP 层最优点"。
   - 再把最优点灌到**端到端推理**（SGLang + Kimi-K2 / DeepSeek-V3.1），看 TTFT/TPOT/OTPS 是否真的落在预期。
3. **EP 跨机是核心课题而不是可选**：本轮用 2~4 节点专门跑 UCCL-EP，把"EFA-EP 是否可用 + 要开哪些 env + 和 NCCL-EP 的相对位置"彻底摸清。
4. **FP8 MoE 为主，最后一个 run 追加 GLM-5.1 FP16**（R5）收尾画像；不做稠密对照。
5. **所有动作脚本化入仓**：`manifests/stage5-*.yaml`、`scripts/stage5-*.sh`、`results/stage5-*/`。

---

## 3. 测试模型（2026-04 前沿 FP8）

| 模型 | 参数 / Active | 架构 | FP8 | 显存 | ctx | 用途 |
|---|---|---|---|---|---|---|
| **Kimi-K2-Instruct-0905** | 1T / 32B (384 E top-8) | DeepseekV3 MLA | ✅ block-fp8 | **959 GB** | 262k | 主力基线 + PD 扫 + EP 压测 |
| **DeepSeek-V3.1-Instruct** | 671B / 37B (256 E top-8) | DeepseekV3 MLA | ✅ block-fp8 | **640 GB** | 128k | 生产必上；reasoning on/off |
| ~~DeepSeek-V4-Pro~~ | ~~61 L / 384 E top-6 / MLA / 865 GB FP8~~ | ~~DeepseekV4~~ | ~~✅~~ | ~~865 GB~~ | ~~1M~~ | **R6 取消**（2026-04-24）：SGLang main 未 merge V4 支持（PR #23600 open，需 `deepseek_v4` 分支 + tilelang + FlashMLA + 未稳定 Mooncake 兼容），等软件生态成熟再做 |
| **GLM-4.6** | 355B / 32B (160 E top-8) | GLM-MoE | ✅ block-fp8 | **340 GB** | 200k | 长 ctx 场景 |
| **GLM-5.1** | 待公开确认（预计 ≥ 355B MoE） | GLM-MoE | BF16 / FP16 | **≥ 710 GB**（按 355B FP16 估） | 128k+ | **最后一个 run**：FP16 压力测试，客户指定 |
| **Qwen3-235B-A22B-FP8** | 235B / 22B (128 E top-8) | Qwen3-MoE | ✅ block-fp8 | **240 GB** | 128k | 中等 MoE，2 节点 |
| **Qwen3-Next-80B-A3B** | 80B / 3B (128 E top-8) | Qwen3-Next hybrid | ✅ block-fp8 | **~85 GB** | 262k | 单机基线（排查 EFA 是否瓶颈） |

---

## 4. Lane K — NIXL vs Mooncake-EfaTransport 技术差异量化

### 4.1 课题

**不做"引 / 不引"的业务判断**（客户信息不足）；而是给客户一份**可带走的事实表**：

1. **技术差异表**：NIXL 和 Mooncake-EfaTransport 在协议层、内存注册、元信息传递、多 NIC 并发、依赖组件上有哪些**架构性不同**，每条标"相同 / 类似 / 显著不同"。
2. **性能差值表**：同硬件同 payload 下，两栈每个工作点的 Gbps、RTT、TTFT/TPOT 的**绝对值 + Δ%**。
3. **切换可观测项**：如果客户真要切栈，会看到哪些外部变化（launcher flag、依赖镜像、日志关键字、冷启动、metadata 组件）——**只罗列、不评价**，由客户自己结合其生产栈判断是否重要。

### 4.2 技术差异表（先写，Day 2 启动前）

一页架构对比，**不依赖测试数据**，来自 upstream 代码与文档的静态差异。模板：

| 维度 | Mooncake-EfaTransport (upstream @`634b7097` + Henan 5 PRs) | NIXL (v1.0.1) | 差异性 |
|---|---|---|---|
| Transport 层 | libfabric efa provider 直调（SRD `FI_EP_RDM`） | UCX（后端 TL=rc/ud/cuda_copy）或 UCX_MO | **显著不同** |
| Endpoint 模型 | **#1944 起共享 `fid_ep`**：每本地 NIC 1 个 EP，peer 以 `fi_addr_t` AV 索引寻址；消除 per-peer QP 墙 | UCX `ucp_ep` per peer；`UCX_NUM_EPS` 控制并发 | **显著不同** |
| 多 NIC striping | **#1944 已移除** per-request `MC_EFA_STRIPING_THRESHOLD`（p5en 实测 >2 MB 时 20× 负优化）；保留 #1912 PTE-aware register-time 多 NIC 覆盖 | UCX `UCX_MAX_RNDV_RAILS={1,4,8,16}` 控制 rendezvous rail 数 | **相似（register-time），运行时路径不同** |
| 内存注册 | 显式 pinned + Mooncake 内部 MR cache；#1912 按页大小 PTE-aware auto-split | UCX managed + memhooks / userfaultfd | 相似但配置面不同 |
| 元信息 / 协调 | Mooncake master service | NIXL metadata server / peer handshake | **显著不同** |
| 依赖 | libfabric + Mooncake store + `efa_nv_peermem`（GPU Direct） | UCX + NIXL plugin | **显著不同** |
| SGLang 接入 | `--disaggregation-transfer-backend mooncake` | `--disaggregation-transfer-backend nixl` | 相同 |
| 日志关键字（可观测） | `EfaTransport:` / `SRD shared endpoint` / `Auto-split params` / `Topology discovery` / `warmupSegment` | UCX `UCX_LOG_LEVEL=info` | 不同 |
| 镜像大小（预估） | Stage 4 v2 镜像基线 | +UCX +NIXL plugin 预估增量 | — |
| 失败恢复语义 | Mooncake retry + RPC reconnect | NIXL / UCX endpoint 级重建 | 不同 |

**产出**：`results/stage5-p5en/lane-k/TECH_DELTA.md`。

### 4.3 Microbench（2 节点，Day 2 上午）

工具：`nixlbench`（NIXL 官方 bench）+ `transfer_engine_bench`（Mooncake 官方 bench，做对照）。

**扫描维度**：

| 维度 | 取值 | 备注 |
|---|---|---|
| Transfer backend | UCX / UCX_MO | NIXL 支持多 backend，UCX 是主流 |
| `UCX_TLS` | `rc,cuda_copy` / `ib,cuda_copy` / `rc,rdma,cuda_copy` | 决定走 libfabric EFA 或 IB verbs 兼容路径 |
| `UCX_IB_GPU_DIRECT_RDMA` | yes / no | GPUDirect 开关 |
| `UCX_NET_DEVICES` | `rdmap*s0` 全 16 / 8 / 4 | NIC 数 |
| `UCX_MAX_RNDV_RAILS` | 1 / 4 / 8 / 16 | 多 NIC 并发 rails |
| Message size | 64 KB / 256 KB / 1 MB / 4 MB / 16 MB | KV chunk 典型大小 |
| Concurrency | 1 / 4 / 16 / 64 | 同时 in-flight transfers |
| Memory reg | pinned / UCX managed / cuda-aware | NIXL 内存注册方式 |
| CUDA stream | single / per-transfer | 并发度 |

**产出**：`results/stage5-p5en/lane-k/nixl-sweep.csv`，含每组参数的 Gbps、round-trip μs、CPU 占用。

**基线对照**：同一组 message size × concurrency 在 Mooncake EfaTransport 上跑一遍，产出 `mooncake-baseline.csv`。

**2026-04-25 修订 — 背靠背采样**（原方案允许"借用 R1b 数据"，已撤销）：
- Mooncake baseline 与 NIXL sweep **必须在同一 2 node pod 内交替执行**，不得跨时段借用。理由：Spot 价波动、节点 Spot 回收重调度、EFA 拓扑抖动都会引入不可忽略的噪声。
- 具体执行：每组参数的 NIXL run 紧接着跑一轮 Mooncake `transfer_engine_bench` 对照，两次采样间隔 ≤ 5 min；同一小时内所有 message size 各至少采一对 (NIXL, Mooncake)。
- Mooncake baseline **不借用 R1b / Stage 4 历史数据**（Stage 4 是 v2 镜像，此轮是 v5 + #1944，参数基线不同）。
- 产出：两个 CSV 文件共用同一 `run_id` 列，`K_VS_MOONCAKE.md` 只对同 `run_id` 做 Δ%。

#### 4.3.2 端到端（3 节点，Day 2 下午 ~ Day 3）

将 microbench 最优点灌入 **SGLang `--disaggregation-transfer-backend nixl`**，跑 1P:2D 分离：

| Run | Model | NIXL 配置 | 产出 |
|---|---|---|---|
| K-E1 | Kimi-K2 | microbench 最优 | TTFT/TPOT/OTPS |
| K-E1' | Kimi-K2 | microbench **次优**（Top-2 或 Top-3）| **验证 "transport 层最优 ⇒ 推理层最优" 假设是否成立**（2026-04-25 新增） |
| K-E2 | Kimi-K2 | 最差组参数 | 证明调优差值 |
| K-E3 | DeepSeek-V3.1 | 最优 | 换模型验证通用性 |

**K-E1' 判据**（2026-04-25 新增）：
- 如果 K-E1' 的 TTFT/TPOT 显著好于 K-E1 或差距 ≥ 10% → 说明 microbench 最优点**不等于** E2E 最优点（rendezvous + metadata handshake + batch submit 节奏与裸 transfer 不同），`NIXL_TUNING.md` 必须标注"推荐按 E2E 复测选参数"。
- 如果 K-E1' 与 K-E1 差距 < 3% → 假设成立，microbench 作为选参工具可信。
- 不做重排，就算 K-E1' 更优也不改 K-E1 的"最优点"定义（避免统计偏差），只把 K-E1' 数据进 `K_VS_MOONCAKE.md` 作为敏感性对照列。

**对照**：Lane K 背靠背基线（§4.3 已改），**不借用 R1b / Stage 4 历史数据**。

### 4.4 切换可观测项（**只罗列、不评价**）

客户若在 `SGLang + Mooncake` 与 `SGLang + NIXL` 之间切换，会在以下位置看到差异。我们把每一项**如实记录**，不做高/中/低打分，给客户自行评估：

| 观测项 | 记录内容 |
|---|---|
| SGLang launcher flag/env diff | 两栈启动脚本的纯文本 diff |
| 依赖链（deb/pip 包 + 镜像大小） | `docker image inspect` + `ldd` 输出 |
| 冷启动时间（到 Ready） | launcher 打时间戳 |
| 日志关键字 | Mooncake：`EfaTransport` / `Chunk registered` / `topology` 等；NIXL：`UCX_LOG` / endpoint 事件；两套 key 列表 |
| metrics / counters 出口 | 两栈各自暴露的 metric 名 |
| 独立组件 | Mooncake master service、NIXL metadata peers 等外挂进程/pod 列表 |
| 故障行为（kill prefill pod / 断 EFA / OOM） | **Day 4 尾部 4 h 专项**（2026-04-25 扩容；原 30 min 不够统计意义）。每个故障场景 **≥ 3 次复测**，记录两栈恢复时间 p50/p99、hung connection 残留、memory reg 泄漏（`/proc/<pid>/status` VmRSS 连续采样）、FI_MR cache 是否耗尽。场景：(a) kill prefill pod → 等 decode 侧 K-E1 E2E 恢复至 90% TTFT；(b) `iptables -I INPUT -i rdmap*s0 -j DROP` 断 EFA 60 s 再放开；(c) mem-fraction-static 调高触发 OOM |
| TTFT/TPOT 抖动（同 payload 多次） | P99 / P99.9 分布 |

**产出**：`results/stage5-p5en/lane-k/SWITCH_OBSERVABLES.md`，纯数据 + 纯事实，不下结论。

### 4.4.1 正确性闸门（**2026-04-25 新增**）

Lane K 原方案只测性能差值，未测正确性 —— 但 KV 传输在 rendezvous + PTE-aware chunk split + 乱序 completion 等边界条件下可能出现 **位腐败**（尤其是 peer reconnect 后 partial transfer 或非 64B 对齐的 KV block）。补一项硬判据：

**判据**（两栈必须都通过，否则性能差值数字不具备可比性）：
- 固定 seed + 固定 prompt 集（**1000 条**，来自 SGLang 官方 `bench_serving` 的 sharegpt 样本）
- 单模型（Kimi-K2），同 1P:2D 拓扑，分别在 Mooncake 和 NIXL 下跑一轮 greedy decoding（temperature=0）
- **token match rate ≥ 99.9%**（< 1/1000 分歧；预期 100%，留 1 条抖动余量）
- 每次分歧样本记录 prefix hash + divergence position，写进 `LANE_K_CORRECTNESS.md`

**执行时机**：Day 3 末 30 min（两个 E2E 各跑 ~15 min）；Day 3 的时间表 §9 会更新。

**如果不过**：标为 Lane K 性能部分 ⚠️ "可能存在边界条件正确性问题"，Mooncake 基线仍可信（Stage 4 生产级稳定），但 NIXL 数据不给推荐。

**产出**：`results/stage5-p5en/lane-k/LANE_K_CORRECTNESS.md`。

### 4.5 交付物（Lane K）

- `results/stage5-p5en/lane-k/TECH_DELTA.md` —— 架构差异（静态）
- `results/stage5-p5en/lane-k/NIXL_TUNING.md` —— 参数调优清单（每个参数的影响方向 + 推荐值）
- `results/stage5-p5en/lane-k/K_VS_MOONCAKE.md` —— **性能差值表**（同硬件同模型同 payload，Δ% 全列）
- `results/stage5-p5en/lane-k/SWITCH_OBSERVABLES.md` —— 切换外部观测项（事实表，无评价）
- `results/stage5-p5en/lane-k/LANE_K_CORRECTNESS.md` —— **2026-04-25 新增**：1000 请求 token match rate；NIXL 和 Mooncake 各一个数字
- `results/stage5-p5en/lane-k/LANE_K_FAILURE.md` —— **2026-04-25 新增**：三场景 × 两栈 × ≥3 次复测的恢复时间 p50/p99 + 泄漏指标
- `scripts/stage5-lane-k-microbench.sh`、`scripts/stage5-lane-k-e2e.sh`、`scripts/stage5-lane-k-correctness.sh`（新增）、`scripts/stage5-lane-k-failure.sh`（新增）

---

## 5. Lane E — UCCL-EP vs NCCL-EP 技术差异量化

### 5.1 课题

**不做"是否必须"的业务判断**；给客户一份**可带走的事实表**：

1. **技术差异表**：UCCL-EP 与 NCCL-EP 在协议 / kernel / 调度路径 / 内存路径上的架构差异。
2. **性能差值表**：同硬件同 routing / hidden / token-per-batch 下，两者 dispatch+combine 延迟、有效带宽、端到端 TTFT/TPOT 的绝对值 + Δ%。
3. **扩展性曲线**：2 → 4 节点两个点，记录趋势但不外推。
4. **IB 参考线**：DeepEP on IB 的公开/客户数字作为趋势参照，**仅标注、不直接与 EFA 数据对齐比较**（硬件不同）。**2026-04-25 修订**：IB 数字**不进主性能差值表 `E_VS_NCCL.md`**，单独放 `IB_REFERENCE.md`，避免读者隐式对齐 —— 即便写"不对齐"的注释，读者心理仍会并列比较，这是人类阅读的默认行为。

### 5.2 技术差异表（先写，Day 3 启动前）

| 维度 | NCCL-EP on EFA | UCCL-EP on EFA | 差异性 |
|---|---|---|---|
| 通信 kernel | NCCL all-to-all（环/树/xhier） | UCCL 自定义 dispatch+combine kernel | **显著不同** |
| 下层传输 | libfabric efa | libfabric efa（自带 proxy kernel + RDMA write） | 相似（同 libfabric） |
| token 调度 | 全量 a2a，每 rank 发/收固定 tensor | 按 top-k routing 稀疏 dispatch | **显著不同** |
| 内存路径 | NCCL buffer | UCCL pinned + GPU-direct | 类似 |
| CPU 侧开销 | NCCL host proxy | UCCL host proxy + kernel launch overhead | 类似 |
| SGLang 接入 | `--moe-a2a-backend none/nccl`（默认等价） | `--moe-a2a-backend uccl`（若 SGLang 已支持）/ 环境变量 | 不同 |
| 调优旋钮 | NCCL env（NCCL_ALGO / NCCL_PROTO 等） | UCCL queue depth + FI_EFA_* | 不同面 |

**产出**：`results/stage5-p5en/lane-e/TECH_DELTA.md`。

### 5.3 Microbench（2 节点 → 4 节点，Day 3 下午 ~ Day 5 上午）

工具：
- `uccl-ep bench`（OSDI'26 官方 bench）
- `deepep-tests/test_internode.py`（DeepEP 自带 bench，用作 IB 路径的对标脚本；改造为 EFA 兼容版）
- NCCL-tests alltoall 作为 NCCL-EP 路径参照

**扫描策略（2026-04-25 晚 修订 — 分两层剪枝，避免全组合爆炸）**：

#### 层 1 — 核心 MoE 拓扑（必扫，预计 ~20 组）

| 维度 | 取值 | 说明 |
|---|---|---|
| EP world size | 2 / 4 / 8 / 16 / 32 | 跨 1-4 node |
| Hidden dim | 4096（Qwen3-MoE）/ 7168（Kimi-K2 / DeepSeek）| 12288 不扫（客户无此 hidden） |
| Tokens per batch | 2048 / 8192 | 512 太小无代表性，删 |
| Top-k | **固定 8** | 客户主力模型全部 top-k=8，不扫 |

组合：5 × 2 × 2 = **20 组**，每组 UCCL-EP + NCCL-EP 各跑一次 = 40 run，每 run ~2 min → ~80 min。

#### 层 2 — EFA 硬件参数（在层 1 最优点周围 ±1 档扫，预计 ~15 组）

在层 1 选出 "推荐工作点"（Kimi-K2 hidden=7168 / tokens=8192 / EP=16 推定最具代表性），围绕这个点扫：

| 维度 | 取值 | 说明 |
|---|---|---|
| NIC 绑定 | 每 GPU 单 NIC / 每 GPU 2 NIC / 多 NIC striping | 3 档 |
| `FI_EFA_TX_SIZE` / `RX_SIZE` | 默认 / 2× / 4× | 3 档 |
| `UCCL_RDMA_QUEUE_DEPTH` | 64 / 128 / 256 / 512 | 4 档 |
| `UCCL_MAX_INFLIGHT` | 默认 / 2× | 2 档 |

层 2 不做笛卡尔乘积，按 OFAT（one-factor-at-a-time）扫：3+3+4+2 = **12 组**，UCCL-EP only，~30 min。

#### 固定不扫（Stage 2 / 官方文档已验证，扫了也是浪费）

| 维度 | 固定值 | 理由 |
|---|---|---|
| `FI_EFA_USE_DEVICE_RDMA` | **1** | H200 v3 默认；Stage 2 验证 0 会退化为 TCP |
| `FI_EFA_FORK_SAFE` | **1** | 生产强制 |
| `FI_EFA_USE_HUGE_PAGE` | **0** | Stage 4 验证 1 遇到问题 |
| `FI_MR_CACHE_MONITOR` | **memhooks** | libfabric 默认；userfaultfd 在 AL2023 kernel 未验证 |
| Top-k | **8** | 客户模型锁定 |
| UCCL kernel launch 参数 | **官方 default** | 不在本轮能力范围内调 kernel |

#### 总扫描量

20 + 12 = **~32 组**（层 1 + 层 2 OFAT），每组 2 min，总 ~1.5 h 纯跑时间，加上切 EP world size 的重建 overhead ≈ **3 h 跑完**，留 2 h buffer 给 E2E 准备。Day 3 下午 ~ Day 5 上午够用。

**产出**：
- `results/stage5-p5en/lane-e/uccl-ep-sweep.csv` —— dispatch + combine 延迟 / 有效带宽
- `results/stage5-p5en/lane-e/nccl-ep-baseline.csv` —— NCCL 路径兜底
- `results/stage5-p5en/lane-e/deepep-ib-reference.md` —— 引用客户国内 or DeepEP 官方公开数字作趋势线

### 5.4 正确性闸门（必须过）

**双层判据**（2026-04-25 晚 修订 — 对标 Lane K 的 1000 请求 / 99.9% 标准，覆盖客户主力模型 + 长 ctx 路径）：

**判据 1：数值层**
- 固定 seed、固定 routing、固定 token 分布，UCCL-EP vs NCCL-EP 跑 `dispatch + combine`
- **logits / activation max-abs-diff ≤ 1e-3**（fp16 量级）
- 每模型 × 每 hidden 维度采一个 max-abs-diff 数字

**判据 2：Token 层**（6 组闸门，全部通过）

| 组 | 模型 | 场景 | 样本 | 判据 |
|---|---|---|---|---|
| G1 | Qwen3-235B-A22B-FP8 | 短请求 ISL 128 / OSL 128 | 1000 条 sharegpt | token match rate ≥ 99.9% |
| G2 | Qwen3-235B-A22B-FP8 | 长 ctx ISL 8192 / OSL 128 | 1000 条 longbench-v2 | 同 |
| G3 | Kimi-K2-Instruct-0905 | 短请求 ISL 128 / OSL 128 | 1000 条 sharegpt | 同 |
| G4 | Kimi-K2-Instruct-0905 | 长 ctx ISL 8192 / OSL 128 | 1000 条 longbench-v2 | 同 |
| G5 | DeepSeek-V3.1-Instruct | 短请求 ISL 128 / OSL 128 | 1000 条 sharegpt | 同 |
| G6 | DeepSeek-V3.1-Instruct | 长 ctx ISL 8192 / OSL 128 | 1000 条 longbench-v2 | 同 |

- 全部 greedy decoding（temperature=0）
- UCCL-EP vs NCCL-EP 输出 token-by-token 比对
- 任一组 < 99.9% → 记录分歧样本（prefix hash + divergence position）到 `CORRECTNESS.md`，上 issue 到 UCCL 团队

**执行**：Day 5 04:00-06:00 UTC（原 30 min → 2 h），短请求 6 × 1000 × ~1 s ≈ 100 min，长 ctx 另一半时间。

**两层判据都过**才跑性能 sweep；任一条不过 → Lane E 性能部分**回退到只出 NCCL-EP 数据 + UCCL 定性结论**，不出 UCCL-EP vs NCCL-EP 差值表。

**对 Mixtral-8x7B 等老模型的备选**：原方案用 Mixtral 做小规模验证（§5.4 第二条），撤销；直接用客户主力模型（Qwen3-235B / Kimi-K2 / DeepSeek-V3.1）闸门 —— Mixtral 数据对客户参考价值低。

### 5.5 端到端（3~4 节点，Day 5 下午 ~ Day 6）

把 microbench 最优 UCCL-EP 参数灌到 SGLang 的 `--moe-a2a-backend uccl`（若支持）或通过环境变量注入：

| Run | Model | EP 配置 | 对照 |
|---|---|---|---|
| E-E1 | Kimi-K2 | EP=16 跨 2 node | `--moe-a2a-backend nccl`（即 NCCL-EP） |
| E-E2 | DeepSeek-V3.1 | EP=16 跨 2 node | 同 |
| E-E3 | Kimi-K2 | EP=32 跨 4 node | 看扩展性 |

**观察点**：
- dispatch 延迟 p50/p99
- combine 延迟 p50/p99
- 端到端 TTFT/TPOT 相对 EP-off（EP=TP=8 单机）的增量
- EFA counters（tx_pkts、rx_pkts、rdma_cm_events）

### 5.6 交付物（Lane E）

- `results/stage5-p5en/lane-e/TECH_DELTA.md` —— 架构差异（静态）
- `results/stage5-p5en/lane-e/UCCL_EP_TUNING.md` —— 参数调优清单 + env 白名单
- `results/stage5-p5en/lane-e/E_VS_NCCL.md` —— **性能差值表**（dispatch/combine 延迟、有效带宽、扩展性；每维度 Δ%）；**2026-04-25 修订**：只含 EFA 数据，**不含 IB 列**；**2026-04-25 晚 修订**：文档必含免责声明 "EP world size 上限 32；客户生产 EP=64+ 的行为需另做规模实验；2→4 node 曲线只给趋势，不外推"
- `results/stage5-p5en/lane-e/CORRECTNESS.md` —— 正确性闸门报告（6 组 G1-G6 × 1000 请求 × 99.9% 判据）
- `results/stage5-p5en/lane-e/IB_REFERENCE.md` —— DeepEP on IB 公开数字 **独立文件**（与主表 `E_VS_NCCL.md` 物理分开），不做对齐比较
- `results/stage5-p5en/lane-e/E_DECISION_TREE.md` —— **2026-04-25 晚 新增**：从客户模型（Qwen3-MoE / Kimi-K2 / DeepSeek-V3.1）+ EP 规模 → 推荐 backend（UCCL-EP / NCCL-EP）+ 关键 env + 预期延迟区间；这是给客户决策的直接输入，不是参数清单
- `scripts/stage5-lane-e-microbench.sh`、`scripts/stage5-lane-e-e2e.sh`、`scripts/stage5-lane-e-correctness.sh`（新增）

### 5.7 Lane E 附加项 —— UCCL 上游贡献验证（**2026-04-25 新增**）

本 Stage 5 窗口期内，团队向 `uccl-project/uccl` 提交了第一个上游 PR（**#904** — `UCCL_EP_CPU_TIMEOUT_SECS` runtime 覆盖）。为把客户决策从"旁观 UCCL-EP 生产可用性"升级为"主动补强并可验证"，把 PR 自测作为 **Lane E 的第 4 个交付维度**，与 §5.3 microbench / §5.4 正确性闸门 / §5.5 E2E 并列。

**动机**（与客户价值对齐）：
- UCCL-EP 在 EFA 上存在已知的 CPU-side false timeout 问题（issue #893 / #878），客户若上生产会踩同样的坑
- 我们已经实现了 `UCCL_EP_CPU_TIMEOUT_SECS` 环境变量 runtime 覆盖，需要在 AWS p5en 上**实测验证**才能说服 UCCL 团队 merge
- 验证成功后，同一手段将继续用于 P0 combine-signal / P1 dispatch early-release 等后续 PR —— 本轮建立的 benchmark 基建是**跨 PR 可复用**的工具链

**PR #904 实际改动**（基于 HEAD `f1ecbaf7` + 四个 commit；2026-04-27 更新，镜像实际锁 `ef7460cc`）：
| Commit | 内容 | 风险 |
|---|---|---|
| `0ce1a22f` | 加 `UCCL_EP_CPU_TIMEOUT_SECS` env var，override `NUM_CPU_TIMEOUT_SECS` | 低（纯 env 扩展，默认行为不变） |
| `a7eb743e` | Helper 移 `common.hpp`，`atoi` → `strtol` + 验证 | 低（refactor，无语义变化） |
| `17fdb8d3` | Merge upstream main（含 #902 oob refactor 等） | 低（上游非 EP-core 改动） |
| `ef7460cc` | Trim CPU timeout env helper comment | 零（仅注释）|

**镜像 SHA 锚点**：`sglang-mooncake:v5-uccl` (Ohio ECR, 2026-04-27 build) 内嵌 `/opt/uccl/.build-sha = ef7460ccd09a511c3c9681df04112a6e6feb2baa`，用于 §5.7 PR comment 证据链。

#### 5.7.1 测试目标

**必验证项（3 条，blocking merge）**：
1. **零回归**：`UCCL_EP_CPU_TIMEOUT_SECS` 未设置时，`test_low_latency.py` 的 dispatch/combine 微基准数字和 HEAD `f1ecbaf7` 一致（误差 < 1%，低于 run-to-run 噪声）
2. **Env 生效**：设置 `UCCL_EP_CPU_TIMEOUT_SECS=3` 触发短超时路径、设置 `=600` 允许长步骤不触发超时
3. **Build 通过**：在 p5en.48xlarge 上 `bash build.sh cu12 ep --install` 无编译错误，`python3 -c "import uccl.ep"` 无 import 错误

**可选强化项（PR review 被要求时再做）**：
4. 非法值 fallback：`UCCL_EP_CPU_TIMEOUT_SECS=abc` / `=-5` / `=0` 均 fallback 到 100，并观察到一次性 stderr warning
5. Stress：Megatron / SGLang 实际工作负载下 `=600` 稳定运行 2 h 无 false timeout

#### 5.7.2 测试设计

**测试窗口**：Day 5 晚（Lane E microbench 结束后），共 ~1 h，不影响主流程。

**硬件**：沿用当日 Lane E microbench 拉起的 2×p5en.48xlarge（SPS 按 §1.2 当日可用 AZ 选），不另外起集群。

**镜像**：基于 Stage 5 现有 `sglang-mooncake:v5-uccl` 镜像，新 build 一个标签 `sglang-mooncake:v5-uccl-pr904`，内含：
- UCCL `KevinZhao/uccl:ep-warmup-cpu-timeout-env`（HEAD `a7eb743e`）
- 其他依赖（Mooncake / Henan PR / rdma→efa 补丁）完全保持和 v5-uccl 一致
- 构建脚本复用 `scripts/stage5-mirror-ecr.sh`，加 `UCCL_BRANCH=ep-warmup-cpu-timeout-env` 变量

**测试脚本**：`scripts/stage5-lane-e-pr904-verify.sh`（新增，~80 行）：
1. 启动 2 node pod（image 切到 `v5-uccl-pr904`）
2. 三段 microbench：
   - **A 段**（baseline）：`HEAD=f1ecbaf7`，env 不设，`test_low_latency.py --num-tokens=128 --hidden=7168 --num-topk=8 --num-experts=288`，3 次取平均
   - **B 段**（verify 无回归）：`HEAD=a7eb743e`，env 不设，同参数，3 次取平均；对比 A 段 dispatch/combine 延迟差应 < 1%
   - **C 段**（verify env 生效）：`HEAD=a7eb743e`，`UCCL_EP_CPU_TIMEOUT_SECS=3` 起 pod，验证 dispatch 30 s 后启动不会被 kill（因为只是 runtime knob，不触发 timeout）；再用 `=600` 启，观察 import 阶段 env 生效（`strace -e getenv` 或直接日志）
3. 非法值测试：`UCCL_EP_CPU_TIMEOUT_SECS=abc python3 -c "import uccl.ep"` 抓 stderr，grep `[UCCL] Warning: invalid`

**数据采集**：和 §8 统一口径一致，额外加：
- UCCL commit SHA（每 run 写 `env.txt`）
- env 变量值 + stderr warning 片段（`env.txt` + `stderr.log`）
- 三段对比表格进 `results/stage5-p5en/lane-e/pr904-verify/RESULT.md`

#### 5.7.3 交付物（PR comment 可直接贴）

- `results/stage5-p5en/lane-e/pr904-verify/<stamp>/STEPS.md` —— 流水（pod 起、每段启动时间、3 次采样 raw）
- `results/stage5-p5en/lane-e/pr904-verify/<stamp>/RESULT.md` —— 结构化对比表：
  | Segment | UCCL SHA | Env | Dispatch µs | Combine µs | Δ vs A |
  |---|---|---|---|---|---|
  | A baseline | `f1ecbaf7` | unset | (N) | (N) | — |
  | B no-regression | `a7eb743e` | unset | (N) | (N) | < 1% |
  | C env-works | `a7eb743e` | `=600` | (N) | (N) | < 1% |
- `results/stage5-p5en/lane-e/pr904-verify/<stamp>/env.txt` —— full env snapshot（实例 id / AZ / 所有 UCCL_* env）
- `results/stage5-p5en/lane-e/pr904-verify/<stamp>/stderr_abc.log` —— 非法值测试的 warning 原文
- 以上所有内容汇总成 PR #904 的 comment（代码块 + 表格），符合 `feedback_uccl_pr_aws_bench.md` 要求

#### 5.7.4 风险与 Fallback

| 风险 | 概率 | 影响 | Fallback |
|---|---|---|---|
| Day 5 晚 Ohio SPS 不足，没法起 2 node | 中 | 本项延到 Day 6 晚 | 如 Day 6 也不起，PR 先提交 "build log only"（CPU 侧确认过 format/build pass），AWS 数据做 follow-up comment |
| `v5-uccl-pr904` 镜像 build 失败 | 低 | 本项阻塞 | 镜像 build 是 Day 4 尾完成，Day 5 早发现可回退到 `v5-uccl` 打 patch 直接 pod 内 `pip install -e /opt/uccl/ep` |
| B 段和 A 段差值 > 1%（即我们的 refactor 意外引入回归）| 低 | PR 要撤或修 | 立刻 `git bisect` 定位是 `0ce1a22f` 还是 `a7eb743e` 引入，若是 helper 移 `common.hpp` 引入，回退到文件作用域方案（PR 重提） |
| C 段 env 不生效（证明我们的实现有 bug）| 极低 | PR 阻塞 | 同上，回本机 debug；这是 pre-merge 必须 clear 的 |
| UCCL 团队在 Day 5-7 窗口期 review comment 要求改 API | 中 | 要追加 commit | 不阻塞 Stage 5 收尾；新 commit push fork 后 PR 自动更新，benchmark 数据不变（语义等价的话） |

#### 5.7.5 与主线关系

**不占 Day 6 R5 pre-flight / Day 7 R5 / 报告窗口**。如果 Day 5 晚跑不完，宁可把 5.7 项**整个砍掉**（PR #904 提供 CPU-side build log 即可），也不挤压 §5.5 Lane E E2E 和 §10.1 R5 pre-flight。

**产出归属**：PR #904 如果在 Stage 5 窗口内 merge，把"AWS benchmark 已上游验证"作为 `SUMMARY.md` 的附加亮点；如果窗口内没 merge，单独列在 `RECOMMENDATIONS.md` 的 "Open items" 小节里给客户看，体现 "UCCL 上游修复路径已打通"。

### 5.8 Lane E 附加项 —— 单节点 UCCL-EP vs NCCL 对比（**2026-04-27 新增**）

#### 5.8.1 课题

Lane E 主线（§5.3 / §5.5）全部瞄准 2-4 node 跨机 EFA 场景；**单节点 TP=EP=8 走 NVLink 内的 MoE alltoall 数据缺失**。客户若只部署单节点（Qwen3-235B-A22B-FP8 / Qwen3-Next-80B-A3B 单机即可），我们目前无法回答"UCCL-EP 相比 NCCL alltoall 能快多少"。本项补该曲线。

**关键点**：单节点 NVLink 900 GB/s 足够宽，**带宽差距被稀释**；UCCL-EP / DeepEP 的优势不来自"数据量少"，来自：
1. permute / unpermute 融合进 dispatch / combine kernel（NCCL 必须单独 kernel）
2. SM 占用低（DeepEP 20-24 SM vs NCCL ~132 SM）→ 让出 SM 给 expert GEMM
3. Chunked dispatch 可与 GroupedGEMM overlap（NCCL alltoall 整块同步）

因此单节点实测需同时测 "不开 overlap" 和 "开 SBO overlap" 两档。

#### 5.8.2 预估（待实测覆盖）

| 指标 | 不开 overlap | 开 SBO overlap | 来源 |
|---|---|---|---|
| alltoall 纯延迟（dispatch+combine）| UCCL-EP **-40 ~ -50%**（即 1.5-2× 提速）| 同左 | DeepEP paper H800 NVLink + p5en H200 形状外推 |
| MoE decode ITL | **-10 ~ -15%** | **-20 ~ -30%** | 58 层 × 110-170 µs 节省 / (30-40 ms ITL) |
| MoE prefill throughput | **-5 ~ -10%** | 同左（prefill 不叠 overlap）| prefill FLOPs-bound，alltoall 占比 10-15% |

**预估来源**：DeepEP paper (Feb 2025) 数据 + MoE 分层结构推算；**没有本项目 p5en H200 单节点实测**。判据：实测 ITL 改善落在预估区间内 → 结论"单节点 UCCL-EP 收益在预期"；落在区间外 → 文档注明"NVLink 900 vs 400 GB/s 带宽差异 / 单节点 SM 争用行为与 DeepEP 原始假设不一致"。

#### 5.8.3 测试设计

**硬件**：1 × p5en.48xlarge Ohio（use2-az2，SPS 当日最高），沿用现有 `yanxi-validation` ns + Lane E 镜像（`sglang-mooncake:v5-uccl`），**不另起集群**，不需要 hostNetwork（单节点无跨机）。

**时机**：Day 4 08:00-12:00（原 buffer 时段，R4 重试在 00:00-04:00，故障恢复 16:00-20:00，中间窗口空闲）。

**测试矩阵**（分两层，沿用 Lane E §5.3 / §5.4 方法论）：

##### L1 — Microbench（2 h）

单节点 TP=EP=8，`test_intranode.py`（DeepEP 自带，UCCL-EP 已兼容）+ NCCL-tests alltoall 对照：

| 维度 | 取值 | 说明 |
|---|---|---|
| Hidden dim | 4096 / 7168 | 覆盖 Qwen3-MoE 和 Kimi-K2 / DeepSeek 两档 |
| Tokens per batch | 512 / 2048 / 8192 | 单节点有必要加 512（decode 小 batch 代表性）|
| Top-k | 固定 8 | 同 Lane E 主线 |
| Experts total | 128（Qwen3）/ 256（DeepSeek）/ 384（Kimi-K2）| 3 档 |
| Backend | UCCL-EP / NCCL alltoall | 对照 |

组合：2 × 3 × 3 × 2 = **36 run**，每 run 90 s → **~1 h 纯跑时间 + 30 min 切 backend 重建**。

产出：每组参数的 dispatch µs / combine µs / 有效 NVLink 带宽 GB/s / SM 占用。

##### L2 — E2E SGLang（1.5 h）

单节点 Qwen3-235B-A22B-FP8 TP=8 + EP=8（FP8 显存 240 GB 能单机放下，但注意 Day 1 发现的 `moe_intermediate_size=1536` TP=8 不兼容——见 memory `feedback_qwen3_235b_fp8_tp8_unsupported.md`；**本项改用 Qwen3-Next-80B-A3B** 作为实验模型，避免阻塞；Qwen3-Next top-k=8 / 128 E / hidden=4096，结构代表性一致）：

| Run | Backend | Overlap | 产出 |
|---|---|---|---|
| S1-NCCL-noovlp | NCCL alltoall | off | baseline TTFT/TPOT/OTPS |
| S1-UCCL-noovlp | UCCL-EP | off | **验证 "-10 ~ -15% ITL"** |
| S1-UCCL-ovlp | UCCL-EP | on (SBO chunked overlap) | **验证 "-20 ~ -30% ITL"** |
| S1-NCCL-prefill | NCCL alltoall | off（仅 prefill） | prefill throughput baseline |
| S1-UCCL-prefill | UCCL-EP | off（仅 prefill）| **验证 "-5 ~ -10% prefill"** |

每 run：sharegpt 256 请求，ISL 2048 / OSL 1024，concurrency 16。每 run ~8 min，共 5 × ~10 min = 50 min + 10 min 切 backend。

##### L3 — 敏感性（30 min，时间够再做）

把 L2 主工作点扫两个 knob，看 UCCL-EP 收益是否稳定：
- concurrency：16 / 64 / 128（小 batch 时 kernel launch overhead 占比大，DeepEP 融合优势应更明显）
- hidden：4096 → 7168（只在 Qwen3-Next 系没法切，此项用 Kimi-K2 active 32B 做——但 Kimi-K2 单机放不下 FP8 959 GB）；**L3 降级为只扫 concurrency**

#### 5.8.4 正确性闸门（**轻量版**）

单节点 alltoall 环境单一（不涉跨机 RDMA），错的概率低于 Lane E 主线；但"UCCL-EP 是否有 SM=8 开关下的 kernel 边界 bug" 值得一查：
- 单模型 Qwen3-Next-80B-A3B，greedy decoding（temperature=0）
- 200 条 sharegpt 样本（单节点轻量，不用 1000 条）
- UCCL-EP vs NCCL alltoall token match rate ≥ 99.5%（单节点单一路径，阈值可略松于 Lane E 主线 99.9%）
- 不过 → L2 的 UCCL-EP 数字标 ⚠️，只出 NCCL baseline

#### 5.8.5 交付物

- `results/stage5-p5en/lane-e/intranode/<stamp>/STEPS.md` —— 流水
- `results/stage5-p5en/lane-e/intranode/<stamp>/RESULT.md` —— 两层结果表：
  - L1 微观：`(hidden, tokens, experts, backend) → (dispatch µs, combine µs, NVLink GB/s, SM 占用)` × 36 行
  - L2 E2E：S1-NCCL-noovlp / S1-UCCL-noovlp / S1-UCCL-ovlp / S1-NCCL-prefill / S1-UCCL-prefill × (TTFT p50/p99, TPOT p50/p99, OTPS)
- `results/stage5-p5en/lane-e/intranode/<stamp>/PREDICTION_VS_ACTUAL.md` —— 3 条预估 vs 实测对照，落区间内 / 外各自写明归因
- `results/stage5-p5en/lane-e/intranode/<stamp>/correctness.log` —— 200 条 token match rate
- `scripts/stage5-lane-e-intranode.sh`（新增）—— 一键跑 L1 + L2 + 正确性
- **汇入** `E_VS_NCCL.md`：新增 "单节点" 小节，与跨机数据并列；明确标注"单节点数据 Day 4 补测，样本 1 node，扩展趋势不外推"
- **汇入** `E_DECISION_TREE.md`：决策树加"单节点部署 → 推荐 UCCL-EP" 或 "单节点部署 → NCCL 足够"的分支（由实测数据决定）

#### 5.8.6 风险 + Fallback

| 风险 | 概率 | 影响 | Fallback |
|---|---|---|---|
| Day 4 Ohio p5en SPS 不足（Day 4 故障恢复也要节点）| 中 | 本项延到 Day 6 白天 buffer | Day 6 R5 preflight 前的 8h 空窗可吸收 |
| Qwen3-Next-80B-A3B SGLang 0.5.10 `--moe-a2a-backend uccl` 不支持（同 §12 客户对齐第 2 条的接入路径问题）| 低-中 | 只出 L1 microbench 数字 | `E_VS_NCCL.md` 单节点小节标"E2E pending integration"，只给 microbench Δ% |
| L1 实测 UCCL-EP vs NCCL 延迟差 < 10%（即预估 1.5-2× 不成立）| 中 | 需重新推预估 | 在 `PREDICTION_VS_ACTUAL.md` 归因（NVLink 带宽太宽 / SM 争用模式不同），不撤结论 |
| SBO overlap 在 SGLang 0.5.10 上未默认启用，需要 patch | 中 | L2 S1-UCCL-ovlp 这一 run 缺 | 标注 "overlap 需自定 patch，客户需 sgl-project/sglang PR #XXXX"，只给 noovlp 数字 |
| UCCL-EP token match rate < 99.5% | 低 | 正确性闸门挂 | 同 §5.4 处理：上 issue；L2 不出 UCCL-EP 数字 |

#### 5.8.7 与 Lane E 主线关系

- 单节点数据 **独立于** 跨机数据（§5.3 / §5.5），不合并分析；`E_VS_NCCL.md` 分"单节点 (5.8)"和"跨机 (5.3/5.5)"两节
- 若 Day 4 buffer 被 R4 / 故障恢复吃掉，**§5.8 可整体砍掉**（不进 SUMMARY.md 主报告，只留一句"单节点对比未做，留 follow-up"）
- 预算：4 h GPU 时间（1 × p5en.48xlarge Spot，约 $6）+ 0 新镜像（沿用 v5-uccl）

---

## 6. 主路径基线（SGLang + Mooncake，PD 扫描）

**2026-04-24 更新**：规模由 7 节点下调到 **4 节点**（quota / Spot 容量现实约束）。Prefill 扩展（R1d 2P:5D、R1e 3P:4D）**放弃**；只保留 1P:ND decode 扩展曲线（R1a/b/c 三点）。这对客户的可交付价值损失是 prefill 侧扩展性缺失；决策见 `RUNBOOK.md` "2026-04-24 规模下调" 条目。

本部分不作栈对照；在 **4 节点** 预算下把 **1P:ND decode 扩展曲线** 扫出来，同时为 Lane K / E 提供 "端到端" 基线：

| Run | 拓扑 | 模型 | 用途 |
|---|---|---|---|
| R0 | 1 node smoke | Qwen3-Next-80B-A3B 单机 | 栈就绪确认 |
| R1a | 2 node 1P:1D | Kimi-K2 | 主路径基线 |
| R1b | 3 node 1P:2D | Kimi-K2 | Stage 4 再确认 |
| R1c | 4 node 1P:3D | Kimi-K2 | decode 侧扩展拐点（PD 曲线右端） |
| ~~R1d~~ | ~~7 node 2P:5D~~ | — | **砍**（规模受限） |
| ~~R1e~~ | ~~7 node 3P:4D~~ | — | **砍**（规模受限） |
| R2 | 3 node 1P:2D | DeepSeek-V3.1 reasoning on/off | 生产场景 |
| R3 | 2 node 1P:1D | GLM-4.6 长 ctx 128k/200k | 长 ctx |
| R4 | 2 node 1P:1D | Qwen3-235B-A22B-FP8 | 中等 MoE |
| **R5** | **4 node 1P:1D TP=16 / EP=none** | **GLM-5.1 FP16** | **收尾 run**：FP16 下 KV 传输与 HBM 占用压力；全部调优参数灌入做"最终工作点"画像 |
| ~~R6~~ | ~~4 node (p6-b300) 1P:3D TP=8~~ | ~~DeepSeek-V4-Pro FP8~~ | **取消**（2026-04-24）：SGLang 尚未接入 DSv4（PR #23600 open），等软件生态成熟 |

所有 R1~R4 都跑在 **SGLang 0.5.10 + Mooncake EfaTransport（upstream @`634b7097`, Henan 5 PRs, ECR tag `sglang-mooncake:v5`）**；R5 同栈，但精度切 FP16、TP 跨机（=16）。

**PD 曲线局限说明**（写进最终 `SUMMARY.md`）：仅有 decode 侧扩展（1P:1D→1P:2D→1P:3D），prefill 侧扩展点 2P:ND / 3P:ND **不在本轮数据范围内**；客户若要 prefill 扩展行为，需另做规模实验。

---

## 7. 关键参数清单（预检）

### 7.1 SGLang（所有 run 通用）

| Flag | 值 | 原因 |
|---|---|---|
| `--fp8-gemm-backend` | **cutlass** | Stage 4 验证：deep_gemm 冷启 30–60 min → cutlass 3 min |
| `--attention-backend` | `flashinfer` / `fa3`（Qwen3-Next） | 模型相关 |
| `--mem-fraction-static` | 0.88~0.92（按模型） | Kimi-K2 0.92，Qwen3-Next 0.85 |
| `--chunked-prefill-size` | 4096（旗舰）/ 8192（中型） | 避 OOM |
| `--disaggregation-mode / -transfer-backend` | `prefill|decode` / `mooncake|nixl` | 主 / Lane K |
| `--disaggregation-ib-device` | 16 × `rdmap*s0` | libfabric auto-discover |
| `--moe-a2a-backend` | `none`（R1–R4） / `mooncake|nccl|uccl`（Lane E） | 规避 EFA-EP（默认）/ Lane E 对比 |
| `--speculative-algorithm` | `EAGLE` / `MTP`（支持的模型） | 提 OTPS |
| `--enable-dp-attention` | True（MoE） | DP-attn |
| `--cuda-graph-max-bs` | 64 / 128 | 配合投机 |

### 7.2 Mooncake（主路径，v5 / `634b7097` / Henan 5 PRs）

| Env / API | 值 | 备注 |
|---|---|---|
| `MC_MS_AUTO_DISC` | 1 | |
| `protocol` | **efa**（launcher sed `rdma→efa`） | SGLang 0.5.10 硬编码 `"rdma"` → launcher 改成 `"efa"` 走 EfaTransport |
| `MC_LEGACY_RPC_PORT_BINDING` | 1 | Henan #1509/#1523 需要 |
| `MC_TRANSFER_SUBMIT_THREADS` | 4 / 8 / 16 扫 | |
| `MC_EFA_STRIPING_THRESHOLD` | **已废弃**（#1944 移除） | 若 env 存在会被忽略；保留用于回退到 v2 对照时 |
| `MC_EFA_MAX_PTE_ENTRIES` | 默认 22M（#1912） | 超大 KV pool 时才扫 |
| `warmup_efa_segment(name)` | Python 绑定（#1944 新增） | 可选 pre-connect；15× 提速 first submit；Lane K E2E 冷启动对照扫一次 on/off |

### 7.3 NIXL（Lane K，重点）

| Env / Flag | 候选 |
|---|---|
| Backend | UCX / UCX_MO |
| `UCX_TLS` | `rc,cuda_copy` / `ib,cuda_copy` / `rc,rdma,cuda_copy` |
| `UCX_NET_DEVICES` | `rdmap*s0`（全 16 / 8 / 4） |
| `UCX_MAX_RNDV_RAILS` | 1 / 4 / 8 / 16 |
| `UCX_RNDV_THRESH` | 256 KB / 1 MB / 4 MB |
| `UCX_IB_GPU_DIRECT_RDMA` | yes / no |
| `NIXL_BACKEND` | UCX / UCX_MO |
| `UCX_MEMTYPE_CACHE` | n / y |

### 7.4 UCCL-EP（Lane E，重点）

| Env / Flag | 候选 |
|---|---|
| `UCCL_RDMA_QUEUE_DEPTH` | 默认 / 扩大 |
| `UCCL_MAX_INFLIGHT` | 扫 |
| `UCCL_EP_TOPK` | 8（模型决定） |
| `FI_EFA_USE_DEVICE_RDMA` | 1（H200 v3 默认） |
| `FI_EFA_FORK_SAFE` | 1 |
| `FI_EFA_TX_SIZE` / `RX_SIZE` | 默认 / 2× / 4× |
| `FI_EFA_USE_HUGE_PAGE` | 0 (Stage 4 遇问题) |
| `FI_MR_CACHE_MONITOR` | memhooks / userfaultfd |
| `NCCL_DEBUG` | INFO（诊断期） |

### 7.5 EFA 通用（诊断用）

- `fi_info -p efa` 应看到 16 devices
- `EFA_USE_HUGE_PAGE=0`
- `NCCL_CROSS_NIC=1`（多 NIC 场景）
- `NCCL_NVLS_ENABLE=1`（H200）

---

## 8. 数据采集（统一口径）

| 指标 | 工具 |
|---|---|
| TTFT / TPOT p50/p90/p99 | `bench_serving.py` |
| OTPS（tok/s/user, tok/s/node） | 同上 |
| GPU util / HBM / SM | `nvidia-smi dmon -s umct` → CSV |
| EFA counters | `efa_counters.py` 1 s 采样（tx/rx bytes、pkts、rdma_cm） |
| 冷启动 | launcher 时间戳 |
| NIXL / UCCL 内部 | `UCX_LOG_LEVEL=info`、bench 自带输出 |
| cost-per-1M-tok | spot × node × h / total output tokens |

**负载矩阵**：
- input length: 512 / 2048 / 8192 / 32768 / 128k（长 ctx）
- output length: 128 / 1024 / 4096（reasoning 16k）
- concurrency: 1 / 4 / 16 / 64 / 256
- 每点 ≥ 3 min，warmup 30 s

---

## 9. Day-by-Day

> 原排 Day 1 = 04-24。实际 04-24 被 FSx 基建占满（见下 Day 0），Day 1 起跑滑到 04-25，全表顺延一天；Day 7 报告日对齐 **2026-05-01**。若 Spot 容量紧张可砍 R3/R4（风险矩阵已列）。

### Day 0（2026-04-24）— FSx Lustre 基建（非计划日，被迫插入）
| Time UTC | Action | 产出 |
|---|---|---|
| 08:00 | `fsx-sg-setup.sh` 建 Ohio + Oregon FSx SG（988 + 1018-1023） | `sg-062ae2f53a5e61e49` / `sg-0c2f826221429c8f3` |
| 08:01 | FSx SCRATCH_2 2400 GiB × 2 region 创建 | v1 Lustre 2.10（见下返工） |
| 09:03 | 两 cluster helm 装 `aws-fsx-csi-driver` | controller ×2 + node DaemonSet |
| 09:04 | 渲染 + apply 静态 PV/PVC `yanxi-model-cache` | ✅ |
| ~09:30 | **踩坑**：FSx 2.10 与 AL2023 client 2.15.6 不兼容 | `fsx-create.sh` pin `FSX_LUSTRE_VERSION=2.15` |
| 09:50 | 删库重建到 Lustre 2.15，PV/PVC 重 bind 新 ID | Ohio `fs-0e7e1313a9c964d34` / Oregon `fs-079832d056597a33b` |
| 10:06 | EC2 Fleet `capacity-optimized` 起两 region m7i Spot prefetcher（m6in 无容量） | Ohio `i-0e559f242487cc5f7` m7i.16x / Oregon `i-02606615a4464114a` m7i.24x |
| — | **Prefetcher 在跑** 5 模型（Qwen3-Next → Qwen3-235B-FP8 → GLM-4.6 → DeepSeek-V3.1 → Kimi-K2，~2.26 TB/region） | 完成后 self-terminate |

### Day 1（2026-04-25）— 实际执行
**战绩（详见 `results/stage5-p5en/2026-04-25_DAY1_SUMMARY.md`）**：
- ✅ **R1a** Kimi-K2 1P:1D on 2×p5en Ohio use2-az1 — 128/128 req PASS，1412 tok/s，TPOT P99 101ms
- ✅ **R3** GLM-4.6-FP8 1P:1D on 2×p5 Oregon usw2-az2 — 128/128 req PASS，2315 tok/s，TPOT P99 35ms（对 R5 GLM-5.1 FP16 是形状等价前置）
- ⚠️ R1b Kimi-K2 1P:2D abort — Ohio Spot 3 台同时回收，丢 /mnt/nvme
- ⚠️ R3 1P:2D 跨 AZ abort — 首请求 TransferEncodingError，**发现 Mooncake KV 必须同 AZ**
- ⚠️ R4 Qwen3-235B-A22B-FP8 abort — sglang 0.5.10 block-FP8 fused MoE 不支持 `moe_intermediate_size=1536` + TP=8（192 % 128 ≠ 0），需要上游修复

**新增 5 条工程约束（入 memory 库）**：跨 AZ FSx 大模型不能挂 PVC / Spot 回收擦 NVMe / 永远 Spot / PD 同 AZ / Qwen3-235B FP8 TP=8 park

### Day 2（2026-04-26）— R1b + R3 长 ctx + Lane K microbench（**2026-04-25 晚重排**）
| Time | Action | 机型 / AZ | 说明 |
|---|---|---|---|
| 00:00 | **R1b Kimi-K2 1P:2D 3 node 重做** | Ohio p5en use2-az2 (SPS=9 @ cap=3) | 当日早上 SPS=1 阻塞，22:00 回 9；HF hub 重预取 ~15 min |
| 04:00 | **R1c Kimi-K2 1P:3D 4 node** | Ohio p5en use2-az2 (SPS=9 @ cap=4 为 8，勉强) | 若容量紧再降回 Day 3 |
| 08:00 | **R3 长 ctx sweep** ISL=8k/32k/128k | Oregon p5 usw2-az2 same-AZ | 2 node 即可，利用 today's same-AZ fix |
| 12:00 | **Lane K microbench**：`transfer_engine_bench` 同 AZ + **跨 AZ 对照** | Oregon p5 (azA + azB) | 验证今日 R3 1P:2D 跨 AZ 挂是否发生在 Mooncake KV microbench 层（若是 → 报 upstream）|
| **20:00** | UCCL-EP SGLang 接入 pre-task 闭合（见 §9 原条目）| builder EC2 | `sglang-mooncake:v5-uccl` push ECR 或走 (c)/(d) 档 |

### Day 3（2026-04-27）— Lane K E2E + R2
| Time | Action | 机型 / AZ |
|---|---|---|
| 00:00 | **Lane K E2E**：K-E1 Kimi-K2 + NIXL 最优点 | Ohio p5en same-AZ |
| 04:00 | **Lane K E2E**：K-E2（最差参数）+ K-E3 DeepSeek-V3.1 | Ohio p5en same-AZ |
| 08:00 | **R2** DeepSeek-V3.1 reasoning on/off（Mooncake 基线） | Ohio p5en 或 **Oregon p6-b300** (192G HBM, SPS=9) 备选，B300 更宽裕 |

### Day 4（2026-04-28）— R4 重试 + §5.8 单节点 Lane E + 故障恢复专项（**R4 从 Day 1 移到此处**）
| Time | Action |
|---|---|
| 00:00 | **R4 Qwen3-235B-A22B-FP8 重试**：先看 sglang 有没有 upstream fix（`fused_moe_triton` block-FP8 padding）；否则 park，跑 **R4' Qwen3-30B-A3B-FP8** 作替代（`moe_intermediate_size=768`，TP=8 → 96 也不整除，但 TP=2 可跑；或者直接跑 Qwen3-235B TP=4）|
| 04:00 | Buffer / R1a-c 高并发补跑 |
| **08:00** | **§5.8 单节点 UCCL-EP vs NCCL（新增）**：1 × p5en Ohio，L1 microbench 2h（36 组）+ L2 E2E SGLang Qwen3-Next-80B 1.5h（5 run）+ 正确性 30min，共 4h；产出 `results/stage5-p5en/lane-e/intranode/<stamp>/` |
| **16:00** | **故障恢复专项 4 h**（kill pod / 断 EFA / OOM 各 ≥3 次复测）：NIXL 栈 2h + Mooncake 栈 2h，写 `LANE_K_FAILURE.md` |

### Day 5（2026-04-29）— Lane E microbench + 正确性
| Time | Action |
|---|---|
| 00:00 | **Lane E microbench**（2 node → 4 node）：`uccl-ep bench` + `deepep-tests` 改 EFA + NCCL-tests alltoall |
| 04:00 | **Lane E 正确性闸门**：UCCL-EP vs NCCL-EP logits 对齐 |
| 08:00 | **Lane E 端到端**：E-E1 Kimi-K2 EP=16（2 node）|
| **20:00** | **Lane E 5.7 附加项 — PR #904 验证**：沿用当日 2 node 镜像切 `v5-uccl-pr904` 跑 3 段 microbench（A baseline / B no-regression / C env-works）+ 非法值 stderr 测试，~1 h；产出贴到 PR #904 comment。若 Day 5 晚 SPS 不足，延到 Day 6 晚 |

### Day 6（2026-04-30）— Lane E E2E + R5 pre-flight
| Time | Action |
|---|---|
| 00:00 | **E-E2** DeepSeek-V3.1 EP=16（2 node） |
| 04:00 | **E-E3** Kimi-K2 EP=32（4 node）|
| 08:00 | Lane E sweep 补跑（长 ctx / 高并发组合）|
| **23:00** | **R5 Go/No-Go pre-flight**（15 min）：HBM dry-run GLM-5.1 FP16 @ 4 node TP=16，按 §10.1 表决定 Day 7 走 A/B/C/D/E 哪个 manifest |

### Day 7（2026-05-01）— R5 GLM-5.1 FP16 + 报告
| Time | Action |
|---|---|
| 00:00 | **R5** GLM-5.1 FP16（Ohio p5en × 4, TP=16 1P:1D）—— 把 Lane K + Lane E 得到的最佳参数全部灌进来，作为"收尾工作点"画像 |
| 05:00 | Lane K/E 缺点补跑（若 R5 早结束） |
| 07:00 | 写报告：`SUMMARY.md` / Lane K 四件套 / Lane E 五件套 / `PD_RATIO_CURVE.md` / `R5_GLM51_FP16.md` / `RECOMMENDATIONS.md` |
| 10:00 | 节点释放 |

---

## 10. 风险矩阵

| 风险 | 概率 | 影响 | Fallback |
|---|---|---|---|
| ~~us-west-2c Spot 7 台拿不齐~~ | — | — | **已接受**：下调到 4 节点；首选 us-east-2a（SPS=8 @ cap=7）；砍 R1d/R1e |
| ~~P Spot quota 未提~~ | — | — | **已解除**：4 节点 768 vCPU，现有 1152 够用；1344 申请可撤回 |
| UCCL-EP 正确性闸门不过 | 高 | Lane E 性能部分无数据 | 上 issue；Lane E 只出 NCCL-EP 数据 + UCCL 定性结论 |
| NIXL on EFA 某些参数组合 UCX 直接崩 | 中 | Lane K 某格数据缺 | 标注 "fail"；仍保留可运行组的调优清单 |
| Mooncake `EfaTransport` 不稳 | 低（Stage 4 稳） | 主路径塌 | 切 NIXL 作为主 KV；Lane K 数据顺势成主路径 |
| Spot 回收 | 中 | 中断 | launcher idempotent，断点续跑 |
| 7 天跑不完 | 中 | 报告降级 | 优先保 Lane K/E + R1 PD 曲线 + R5 GLM-5.1 FP16；R3/R4 可砍 |
| GLM-5.1 FP16 @ 4 node HBM 不够（显存 ≥ 710 GB，4 × H200 × 141GB = 564GB） | **高** | R5 OOM | 扩到 5 node TP=20（若 pp 切分支持）或等价 6 node TP=24；若仍不够，降级为 AWQ/FP8 量化的 GLM-5.1 备选；最差回退到 GLM-4.6 FP16（ctx 减半）。**Go/No-Go 见下 §10.1（2026-04-25 新增）** |
| GLM-5.1 上游 HF 未发布 / SGLang 未接入 | 中 | R5 无模型 | 等模型到位再跑；临时用 GLM-4.6 BF16 作"形状等价"替代，标注 |
| **PR #904 自测不过（B 段 > 1% 回归）**（§5.7 新增） | 低 | PR 要撤或修 | `git bisect` 定位，回退 helper 位置；不影响 Lane E 主线 |
| **PR #904 Day 5-6 SPS 不足无法 AWS 验证**（§5.7 新增） | 中 | PR 只能附 build log | 不阻塞 Stage 5；AWS 数据做 follow-up comment，不影响 Lane E 主交付 |
| **§5.8 单节点 Day 4 08-12 时段被 R4 / 故障恢复挤占** | 中 | 本项延 Day 6 或砍掉 | Day 6 08:00-20:00 有 8h 空窗（R5 preflight 前）吸收；或整项砍，只在 SUMMARY 标 follow-up |
| **§5.8 L1 实测与预估偏差 > 2×（即 UCCL-EP 单节点无明显收益）** | 中 | 预估模型失效 | `PREDICTION_VS_ACTUAL.md` 归因（NVLink 比 H800 宽 / SM 争用不同），不改结论；客户看到真实曲线，对决策反而更有价值 |

### 10.1 R5 Go/No-Go Pre-flight（**2026-04-25 新增**）

为避免 Day 7 凌晨 R5 启动时才发现 HBM 不够 / 模型未就绪 / SGLang 不支持，Day 6 末（UTC 23:00）必须做 15 min pre-flight：

**检查项（15 min）**：
1. `hf download` GLM-5.1 权重到 FSx（若 HF 已发布）→ `.prefetch-complete` 存在？
2. SGLang 0.5.10 / 0.5.11 `--model-type` 是否接受 `glm5` 或 `chatglm5`？`python -c "from sglang.srt.configs.model_config import ModelConfig"` 能否识别？
3. **HBM dry-run**：在 2 node TP=16 上 `--skip-server-warmup --enable-memory-saver` 只加载权重（不起服务），看 `nvidia-smi` 峰值 HBM / 节点。

**Go/No-Go 判据**：

| 情况 | HBM/节点峰值 | 结论 | 走向 |
|---|---|---|---|
| A | ≤ 130 GB | **GO** TP=16 1P:1D | Day 7 00:00 按原方案起 R5 |
| B | 130 < x ≤ 140 GB | **GO with caution** | Day 7 00:00 起 R5，但 mem-fraction-static 调 0.80 + ctx 砍到 64k |
| C | > 140 GB（单卡 OOM）| **NO-GO on 4 node** | 若 SPS 允许扩到 5-6 node 就走 TP=20/24；否则走 D |
| D | 5-6 node 也拿不齐 / 软件不支持 | **DOWNGRADE** | R5 改跑 GLM-4.6 BF16（权重 ~710 GB → 4 node 放得下）同拓扑，报告标注 "FP16 路径降级" |
| E | HF/SGLang 一项未就绪 | **POSTPONE** | R5 改跑 GLM-4.6 BF16 作"形状等价"；说明文档里标 FP16 缺 |

**产出**：`results/stage5-p5en/r5-preflight-<timestamp>.md`，含 HBM 快照 + 走向决策。Day 7 00:00 起的 R5 manifest 从 5 个预渲染版本（A/B/C1/C2/D）里选一个 apply。

---

## 11. 交付物

- `results/stage5-p5en/SUMMARY.md` —— 总报告（纯事实 + 数字，不下业务结论）
- `results/stage5-p5en/lane-k/TECH_DELTA.md` —— NIXL vs Mooncake 架构差异表
- `results/stage5-p5en/lane-k/NIXL_TUNING.md` —— NIXL 参数调优清单
- `results/stage5-p5en/lane-k/K_VS_MOONCAKE.md` —— **性能差值表**（Δ% 全列）
- `results/stage5-p5en/lane-k/SWITCH_OBSERVABLES.md` —— 切换可观测项（事实，无评价）
- `results/stage5-p5en/lane-e/TECH_DELTA.md` —— UCCL-EP vs NCCL-EP 架构差异表
- `results/stage5-p5en/lane-e/UCCL_EP_TUNING.md` —— UCCL-EP 参数调优清单 + env 白名单
- `results/stage5-p5en/lane-e/E_VS_NCCL.md` —— **性能差值表**（Δ% 全列 + 扩展性曲线）
- `results/stage5-p5en/lane-e/CORRECTNESS.md` —— 正确性闸门
- `results/stage5-p5en/lane-e/IB_REFERENCE.md` —— DeepEP IB 参考数字（标注不对齐）
- `results/stage5-p5en/lane-e/pr904-verify/<stamp>/` —— **2026-04-25 新增**：PR #904 AWS p5en benchmark 验证产出（STEPS.md / RESULT.md / env.txt / stderr_abc.log），直接贴到 upstream PR comment
- `results/stage5-p5en/lane-e/intranode/<stamp>/` —— **2026-04-27 新增 §5.8**：单节点 UCCL-EP vs NCCL 对比（STEPS.md / RESULT.md / PREDICTION_VS_ACTUAL.md / correctness.log），L1 microbench 36 组 + L2 E2E 5 run，汇入 `E_VS_NCCL.md` 单节点小节
- `results/stage5-p5en/PD_RATIO_CURVE.md` —— Kimi-K2 1P:ND 曲线
- `results/stage5-p5en/R5_GLM51_FP16.md` —— **GLM-5.1 FP16 收尾画像**（4 node TP=16 1P:1D，最终工作点 TTFT/TPOT/OTPS + HBM/EFA 压力曲线）
- `results/stage5-p5en/RECOMMENDATIONS.md` —— 给客户的一页调优总表（SGLang flag / NIXL / UCCL-EP 的最佳参数 + EFA env + PD 比例），**只给技术建议，不做引 / 不引判断**
- `manifests/stage5-*.yaml`、`scripts/stage5-*.sh`

---

## 12. 与客户对齐（启动前）

1. **PD 比例目标区间**（1P:1D / 1P:2D / 1P:3D 哪个最贴近欧洲 MaaS）—— 决定 R1 扫描重心
2. **UCCL-EP 接入 SGLang 的方式（BLOCKING — Day 1 必须答）**：SGLang 0.5.10 main 上游 `--moe-a2a-backend` 取值不含 `uccl`（只有 `none/deepep/mori`）。UCCL 团队在 sgl-project/sglang 应有开放 PR（Day 1-2 pre-task 会查），需确认接入路径：
   - (a) 客户自己有 fork 含 `uccl` 支持？→ 用客户 fork 的 patch build `sglang-mooncake:v5-uccl`
   - (b) UCCL 上游有 PR open？→ cherry-pick 到 SGLang 0.5.10 build 同上镜像
   - (c) 都没有？→ 用 `LD_PRELOAD` + 环境变量 hack 注入（风险高，Lane E E2E 数据含异常风险声明）
   - (d) 以上都走不通？→ Lane E E2E 退化为只有 microbench 数据，标 "pending SGLang integration"
   Day 1-2 pre-task 的查证结果决定 Lane E 镜像 build 方向，**Day 3 Lane E microbench 开始前必须闭合**。
3. **DeepEP IB 趋势线数据**：能否提供客户国内生产同模型的 dispatch/combine 延迟 & 带宽数字，作为 Lane E 的比对参考？
4. **投机解码（MTP/EAGLE）默认开关** —— 影响 OTPS 基线可比性
5. **reasoning 路径**：V3.1 `reasoning=on` 统一还是独立 SKU

---

## 13. 镜像栈整理 + Blackwell 分叉（2026-04-26 立项）

**背景**：见 Changelog 2026-04-26 条目。当前镜像栈的三个根本问题：
1. **Hopper 锁死**：base / mooncake / sglang 三层编译期 / pip install 期全绑 sm_90，B300 (sm_103) 无法 JIT 出可执行 kernel
2. **版本号撒谎**：ECR 上 `base-cuda-efa:v1/v2/v3` 三个 tag 内容基本一致，CLAUDE.md 描述与实际不符
3. **隐式依赖**：`sglang[all]` pip extras 每次 build 拉当时最新 flashinfer / triton wheel，不可重现且不适配新硬件

### 13.1 目标

1. 维持 Hopper 栈（`v5`）不变，**所有 p5 / p5en 上的 Stage 5 run 继续能跑**
2. 新增 Blackwell 栈（`blackwell-v1`），支撑 p6-b200 / p6-b300 上的 sglang / uccl-ep / mooncake 全套 e2e
3. 把 Dockerfile、ECR tag、mirror 脚本、CLAUDE.md 描述对齐到**单一真源**（`common/BUILD_MATRIX.md`）

### 13.2 范围 + 非目标

**范围内**：
- 重写 `common/Dockerfile.{base-cuda-efa,mooncake-nixl,sglang-mooncake,uccl-ep,nccl-tests}` 的 ARG 语义，引入 `CUDA_VARIANT={hopper|blackwell}` 或拆 `.hopper` / `.blackwell` 后缀（见 §13.4 决策）
- 新增 `common/BUILD_MATRIX.md` 作为单一真源
- 新增 `scripts/build-image-matrix.sh`（批量 build Hopper/Blackwell 两条线）
- `stage5-mirror-ecr.sh` 对齐现实（当前仍引用 `:v2` 老 tag）
- CLAUDE.md / README.md 修正虚构描述
- 所有新 manifest 统一用 `:{hopper-v5,blackwell-v1}` 命名（旧 `:v1/v2/v5` 保留给历史 manifest，不删）

**非目标**：
- 不删除 ECR 上任何已有 tag（避免 break 正在引用的 pod / manifest）
- 不动 Stage 1-4 历史产物的镜像依赖（停在 v5 hopper）
- 不在 Stage 5 剩余窗口内占用 GPU 节点时间（build 全部 builder EC2 异步）

### 13.3 Hopper 栈现状盘点（作为 **frozen baseline**）

| 层 | Dockerfile | ECR tag 当前 | 内容 |
|---|---|---|---|
| base | `Dockerfile.base-cuda-efa` | `base-cuda-efa:v1/v2/v3` | CUDA 12.6 / NCCL 2.23.4 / aws-ofi-nccl 1.19 / sm_90 only |
| transport | `Dockerfile.mooncake-nixl` | `mooncake-nixl:v5` | Mooncake @634b7097 + Henan 5 PRs + NIXL v1.0.1 / torch 2.4.* |
| serving | `Dockerfile.sglang-mooncake` | `sglang-mooncake:v5` | sglang 0.5.10 `[all]` + flashinfer sm_90 wheel + triton 3.1.x |
| ep | `Dockerfile.uccl-ep` | `uccl-ep:v2`（04-21 起冻结）| UCCL main @04-21 + DeepEP v1.2.1 / torch 2.5.1+cu124 |
| test | `Dockerfile.nccl-tests-v2`（`nccl-tests` 是旧版，重复）| `nccl-tests:v2` | NCCL-tests v2.14 / sm_90 only |

**决策**：Hopper 栈当前 tag 全部**冻结**，以 `hopper-v5`（以及 nccl-tests 的 `hopper-v2`、uccl-ep 的 `hopper-v2`）做**别名重打**。原 `v1/v2/v3/v5` tag 保留不删。

### 13.4 Dockerfile 组织方式（待决策）

两种选择，各自权衡：

**选项 A — 文件后缀拆分**（推荐）
```
common/
├── Dockerfile.base-cuda-efa.hopper        (CUDA 12.6 / sm_90，= 现有)
├── Dockerfile.base-cuda-efa.blackwell     (CUDA 13.0 / sm_90;100;103)
├── Dockerfile.mooncake-nixl.hopper        (torch 2.4 / sm_90)
├── Dockerfile.mooncake-nixl.blackwell     (torch 2.9 cu128 / sm_90;100;103)
├── Dockerfile.sglang-mooncake.hopper      (sglang[all] 预编 wheel)
├── Dockerfile.sglang-mooncake.blackwell   (sglang + 手动 source-build flashinfer/triton sm_103)
├── Dockerfile.uccl-ep.hopper              (= 现有，torch 2.5.1+cu124)
├── Dockerfile.uccl-ep.blackwell           (TBD，UCCL 本身是否 sm_103 兼容待查)
├── Dockerfile.nccl-tests.hopper           (= 现 nccl-tests-v2，rename)
└── Dockerfile.nccl-tests.blackwell        (NCCL 2.27 / sm_90;100;103)
```
优点：语义最清楚；每个文件独立可读；build 脚本简单
缺点：重复代码 ~60%，任何通用修改要改两处

**选项 B — 同一文件 + ARG**
```
Dockerfile.base-cuda-efa      (ARG CUDA_VARIANT={hopper|blackwell})
Dockerfile.mooncake-nixl      (同)
Dockerfile.sglang-mooncake    (同)
```
优点：DRY；通用改动一处搞定
缺点：Dockerfile 里大量 `if [ "$CUDA_VARIANT" = "blackwell" ]; then ... fi`，可读性差，调试时难以复现

**建议 A**，理由：Blackwell 的每一层都有独立的版本 pin（CUDA 13 vs 12.6、torch 2.9 vs 2.4、flashinfer 0.2.8 source-build vs 0.2.0 预编 wheel），条件分支太多会把 Dockerfile 变成脚本。**等你确认**。

### 13.5 Milestones（WBS）

按 **不吃 GPU 节点** + **builder EC2 串行 build** 的节奏，这是一个跨 2-3 天的工作项，不阻塞 Stage 5 主线 Lane K / Lane E。

| # | Milestone | 工时 | 依赖 | 产出 |
|---|---|---|---|---|
| M1 | 冻结 Hopper 栈 + 别名重打 ECR tag | 30 min | 无 | `hopper-v5` / `hopper-v2` 别名就绪；现有 manifest 不动 |
| M2 | 清理 repo 内冗余：`Dockerfile.nccl-tests`（旧）删除、`nccl-tests-v2` 重命名 | 10 min | 无 | PR 1 个 |
| M3 | 新增 `common/BUILD_MATRIX.md` 单一真源 | 30 min | §13.4 决策 | 文档 |
| M4 | 改 Dockerfile `ARG BASE_IMAGE` 去除默认值（强制外部传入，避免隐藏版本漂移）| 30 min | M3 | PR 1 个（改动 3 个 Dockerfile）|
| M5 | Blackwell base build + push：`base-cuda-efa.blackwell` | 30 min build + 15 min push | M4，选项 A | `base-cuda-efa:blackwell-v1` @ Ohio ECR |
| M6 | Blackwell mooncake build + push：`mooncake-nixl.blackwell`（含 Mooncake CMake `-DCMAKE_CUDA_ARCHITECTURES="90;100;103"`）| 45 min build | M5 | `mooncake-nixl:blackwell-v1` |
| M7 | Blackwell sglang build + push：`sglang-mooncake.blackwell`（含 flashinfer 0.2.8 source-build、triton 3.3 pin）| 60-90 min build | M6 | `sglang-mooncake:blackwell-v1`（预计 ~18 GB）|
| M8 | 单节点 B300 preflight：`torch.cuda.get_arch_list()` 应含 `sm_103`，`triton` 生成 MoE-like kernel 跑通 JIT，`fi_info -p efa` 16 NIC | 1h（1 × B300 Spot）| M7，B300 SPS ≥ 6 | `results/stage6.5/b300-preflight/<stamp>/STEPS.md`（**独立 run 目录，不污染 Stage 5**）|
| M9 | Oregon ECR mirror Blackwell 栈（`stage5-mirror-ecr.sh` 改 IMAGES 列表）| 20 min | M7 | Oregon ECR 有 `*:blackwell-v1` |
| M10 | 重跑 R6a @ Blackwell 栈（2 × B300 usw2-az2）| 1.5h | M8 M9，B300 SPS ≥ 6 | `results/stage5-p5en/r6-b300/<stamp-2>/RESULT.md` PASS |
| M11 | CLAUDE.md / README.md 修正 `base-cuda-efa:v3 = CUDA 13` 的虚构描述 | 15 min | M3 | PR 1 个 |

**路径总时长**：纯 build 3h；GPU 节点 2.5h（Spot 窗口允许的话，M8+M10 同一批 B300）；repo 工作 2.5h。**总预算 8h**，可分散到 2-3 天。

### 13.6 风险 + Fallback

| 风险 | 概率 | Fallback |
|---|---|---|
| CUDA 13.0 + EFA installer 1.47 runtime 不兼容（`libnvidia-ml.so` ABI） | 中 | 降到 CUDA 12.8（ptxas 也认 sm_103a，是 torch 2.9 cu128 wheel 的官配）|
| flashinfer 0.2.8 source-build 60+ min 失败（CMake 找不到 CUDA 13 header）| 中 | 用 flashinfer 0.2.6 或 triton-only attention backend|
| triton 3.3 和 sglang 0.5.10 API 不兼容 | 低 | 升 sglang 到 0.5.12（明确 merge 了 B300 fix）或 0.5.13|
| UCCL 本身不兼容 sm_103 | 中 | uccl-ep Blackwell 栈 park，Lane E B300 暂不做|
| Mooncake CMake 多架构 build 时间从 10 min → 30 min | 高 | 接受（只是 build，不影响运行时）|

### 13.7 完成判据

**M1-M4 完成**（repo + ECR 现状固化）：
- `git log` 上有 "freeze hopper stack + rename nccl-tests-v2" commit
- `common/BUILD_MATRIX.md` 存在且被 CLAUDE.md link
- `aws ecr describe-images --repository-name yanxi/base-cuda-efa` 能看到 `hopper-v5` alias

**M5-M9 完成**（Blackwell 栈 build 就绪）：
- Ohio + Oregon ECR 都有 `base-cuda-efa:blackwell-v1` / `mooncake-nixl:blackwell-v1` / `sglang-mooncake:blackwell-v1`
- 1 × B300 单节点 preflight STEPS.md 记录 `arch_list` 含 sm_103 + triton kernel JIT PASS

**M10 完成**（真正 unblock R6）：
- `results/stage5-p5en/r6-b300/<stamp>/RESULT.md` 记录 PASS
- GLM-4.6 2 × B300 1P:1D same-AZ bench 数字（tok/s + TPOT + TTFT）
- 作为 R3 Oregon p5 same-AZ（2315 tok/s）的 **single-variable diff** 对照

### 13.8 归属

**不属于 Stage 5 主报告**。结果存到 `results/stage6.5/image-stack-cleanup/<stamp>/` 下（新目录），分两份文档：
- `BUILD_MATRIX_IMPL.md` —— 各 Dockerfile 的实际 diff + 版本 pin rationale
- `B300_FIRST_RUN.md` —— M8/M10 的 STEPS/RESULT，作为 Blackwell 栈的"首次生产 run"证据

Stage 5 主 SUMMARY 只一句话引用："B300 run 见 `results/stage6.5/image-stack-cleanup/`，镜像栈整理专项"。
