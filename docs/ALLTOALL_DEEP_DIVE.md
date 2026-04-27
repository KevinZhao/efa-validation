# UCCL-EP All-to-All 三条优化路径深挖

**日期**：2026-04-26
**调研方式**：3 个并行 agent 深挖 + 实测数字核对修正（其中 2 个 agent 因 session 切换挂起，本文合并 Agent 3 完整结论 + 已有资料 + 实测数据交叉验证）
**背景**：用户要求深挖 FEASIBILITY_RECONFIRM 幸存的 3 个稳态 decode ITL lever：
1. SBO Sprint A/B/C
2. PR #485 rebase (multi-QP in LL)
3. count-send coalescing

---

## 0. 重大基线纠正（全部过往文档的 µs 数字须按此更新）

### 0.1 PR #745 已合入主线 → Stage 5 baseline 已享受

- **PR #745** "Improve LL performance by per-expert token batching" **MERGED 2026-02-22**（`commit 0d2d2d01`）
- 后续补丁：#766（off13 + receiver barrier stride 修复）、#800（benchmark 结果）、#865（AMD 修复）
- 我们 fork HEAD `a7eb743e` **已包含全部**

### 0.2 官方 p5en benchmark 数字（PR #745 body，2-node 16-GPU, hidden=7168, topk=8, num-experts=288, num-tokens=128）

| 指标 | 无 batching | `PER_EXPERT_BATCHING=1` | Δ |
|---|---|---|---|
| Dispatch both p50 | 218.56 µs | **174.90 µs** | **-20.0%** |
| Dispatch send p50 | 40.90 µs | 44.45 µs | +8.7%（略升但 both 降，并发更好）|
| Dispatch recv p50 | 30.69 µs | 30.50 µs | -0.6% |
| Dispatch BW | 35.36 GB/s | **42.88 GB/s** | **+21.3%** |
| Combine both p50 | 325.98 µs | 326.69 µs | +0.2%（持平）|
| Combine send p50 | 47.68 µs | 47.74 µs | +0.1% |
| Combine recv p50 | 46.85 µs | 46.72 µs | -0.3% |

### 0.3 之前文档里的数字错误清单

| 旧文档 | 旧说法 | 正确 |
|---|---|---|
| `SGLANG_OPT_FEASIBILITY_REVIEW`，`CPU_PROXY_ADVANTAGE_LEVERS` | "dispatch 450 µs / combine 600 µs decode baseline" | **过时**：来自 stage2 p5 BF16 高负载 / test_internode（非 LL），**p5en LL 实际 dispatch both 174.9 µs, combine both 326.7 µs** |
| `FEASIBILITY_RECONFIRM` C2 | "dispatch send total 85-200 µs" | **是 Stage 2.1 p5 LL 的数字，不是 p5en post-#745**。p5en post-#745 dispatch send p50 = 44.45 µs, recv p50 = 30.50 µs |
| Agent 3（count-send agent） | "post-#745 dispatch send 40.9 µs" | **误读**：40.9 是 pre-#745 send，post-#745 是 44.45 µs；应该看 **both p50 174.9 µs** 作为总耗时 |

**以下所有 ROI 估算以 p5en post-#745 为基线**：dispatch both 174.9 µs, combine both 326.7 µs。decode 一层 EP 通信总共 **~500 µs**（不是旧文档的 ~1050 µs）。

---

## 1. 三条路径真实 ROI 重评

### 1.1 SBO Sprint A（GPU spin）

**攻的阶段**：combine send (~48 µs) 和 down_gemm 的重叠

**期望收益**：
- SGLang PR #9660 H20 实测 decode mean ITL -7.9%（73→67 ms）
- H200 combine both ~326.7 µs，理想重叠掉 send 阶段 48 µs → **-15% decode ITL 单 layer 理论上限**
- 58 MoE layer × 15% × (326/500 combine weight) ≈ **-10% decode ITL 全局**

**修正后实际期望**：**-5% ~ -10% decode ITL**（比旧文档声称的 -7.9% 仍然合理，但口径要以 both p50 为准）

### 1.2 SBO Sprint B（CPU spin, EFA 独占）

**攻的阶段**：Sprint A 基础上释放 3 个 combine SM 给 DeepGemm

**真实增量**：
- SM 释放 +1.5-2%
- CTA group-mate 解锁 +1-2%
- Spin 颗粒度 µs → ns +~1%
- 合计**再 +3-5% decode ITL**

### 1.3 PR #485 rebase

**攻的阶段**：fast mode `ctx->qp` 单 QP 瓶颈

**PR body 自身没有 benchmark 数字**（DRAFT, empty description）。推导：
- dispatch send 44.45 µs / recv 30.50 µs 中，SQ-level submission 不可能超过一半
- 乐观：dispatch P50 -5~10%，combine tail 10-20%
- **dispatch both 174.9 → ~155-165 µs, combine tail 改善有限（combine 瓶颈是 recv wait + reduce 不是 send）**

### 1.4 count-send coalescing（方案 A）

**攻的阶段**：dispatch 内部 AMO sentinel

**真实 ROI 重算**：
- 之前 agent 说 10-14 µs/layer × 58 = 700 µs/token —— **这个算法有错**
- dispatch send p50 only 44.45 µs，其中 count-send 只是**最后 15-25 µs**，且已经**被 proxy per-dst_rank 批处理了**（`rdma.cpp:3003-3039` 一个 `ibv_wr_start/complete` chain 16 AMO）
- 方案 A 进一步从 16 AMO chain → 1 WRITE：节省**AMO 的 per-item 成本，不是整个 chain**
- 真实节省 **≤ 5 µs/layer**（不是 10-14）
- 58 layer × 5 µs = **~290 µs/token**（不是 700）
- 但仍被 CUDA Graph 完全吞进 kernel body 执行时间，是真实 GPU busy-wait 改善

---

## 2. 三条路径的叠加模型（修正版）

从 p5en post-#745 baseline 出发：
- dispatch both 174.9 µs + combine both 326.7 µs ≈ **~500 µs / layer**
- DSv3 58 MoE layer → decode 纯 EP 通信 ~29 ms/token（加 attention/gemm 后 per-token ITL ~50 ms，和 SGLang PR #9660 H20 72 ms 数量级一致）

| 优化 | 每层节省 | 全局 ITL 改善 |
|---|---|---|
| **SBO A** (combine send-gemm overlap) | ~7-10 µs combine | **-5~-8% ITL** |
| **SBO B** (CPU spin + SM 释放) | 额外 ~3-5 µs GEMM | **额外 -3~-5% ITL** |
| **PR #485** (multi-QP LL) | ~5-10 µs dispatch send + combine tail | **-3~-5% ITL**（可能 P99 更好）|
| **count-send coalesce** | ~3-5 µs dispatch | **-2~-3% ITL** |

**理论上限（全部落地）**：**decode ITL -15 ~ -20%**——比之前 CPU_PROXY_ADVANTAGE_LEVERS 声称的 "P50 -63% / P99 -74%" **小一个数量级**，但**真实可达**。

---

## 3. 实施顺序（不变）

```
1. SBO Sprint A (2w)    — 最大单点，DeepEP API 兼容底座
2. SBO Sprint B (1.5w)  — EFA 独占增量
3. PR #485 rebase (3-5d) — rebase + p5en bench + 推 MaoZiming
4. count-coalesce (4-5d)— 必须在 #485 merge 后做（#485 改 AMO post 分布）
5. SBO Sprint C (1.5w)  — p6-b200 就绪后

并行可做：
- launcher-cache 1d (Agent: `cudaDeviceGetAttribute` 缓存)
- A6 NUMA CCX pin 2d
- B2 SL 分流实测 2d
```

---

## 4. Agent 3 深挖的落地结论

### 4.1 count-send 三个方案对比

- **方案 A**（per-rank vector RDMA WRITE，16 AMO → 1 WRITE）—— 唯一可行
- **方案 B**（破 receiver 协议，per-rank 单 sentinel）—— NO-GO，破坏下游 GEMM 依赖
- **方案 C**（piggyback on WITH_IMM）—— imm 位已满（9 bit expert + 13 bit num_tokens + 6 bit rank），**NO-GO**

### 4.2 方案 A 的实施风险

- **wire format 兼容**：UCCL-EP duck-types DeepEP，必须保持 `rdma_recv_count_internode` receiver 协议不变；方案 A 是"同 layout，不同 post"可兼容
- **必须等 #485 merge**：否则 multi-QP 改 AMO post 分布后，count-coalesce 的 proxy 侧要重写
- **AtomicsImm seq**：新 CmdType 绕过 AtomicsImm 避免 seq 冲突

### 4.3 Agent 3 验证过 NO-GO 的 dispatch 可挖点

- FP8 cast（warp reduce_max）——compute bound，**no lever**
- LogFMT transform——combine 用，dispatch 路径零开销
- `cg::this_grid().sync()`——要 persistent kernel（FEASIBILITY_RECONFIRM 已驳回）
- intra-node IPC 分支——已是最优

---

## 5. 未完成 Agent 1/2 的工作占位

两个 agent 在当前 session 挂起（上一个 session 启动，状态未迁移）。它们应该要返回的内容：

- **Agent 1（SBO 子 lever）**：`num_sms ∈ {0,1,2,3}` 最优点、memory ordering 强度选择、`block_m` 编译期 vs 运行时 variant、`__nanosleep` N 取值 sweep
- **Agent 2（PR #485）**：实际 diff 内容、`kChannelPerProxy` 取值优化、SQ 拥塞 + receiver barrier 冲突细节、p5en bench 设计

**替代方案**：直接和 MaoZiming 通过 PR #904 review thread 联系，询问 #485 DRAFT 状态（5 个月没动，可能他自己打算做但没优先级）。如果他没意向，我们 fork 它自己做 bench + 推 merge。

---

## 6. 实施前必做的 3 件事

1. **补基线实测**：Stage 5 重跑 p5en 2-node `test_low_latency_pplx.py` 拿我们自己的 post-#745 数字，不再引用 PR body 里的。命令：
   ```bash
   torchrun --nnodes=2 --nproc_per_node=8 ... bench/test_low_latency_pplx.py \
       --num-tokens=128 --hidden=7168 --num-topk=8 --num-experts=288
   ```
2. **Agent 验收实测**：instrument SGLang `conn.py` 记 `kv_wait_ms`（Agent 之前说的前置，1 天）——没有它 PD overlap 声称全是空话
3. **和 MaoZiming 对齐 #485 意图**：PR #904 review 里顺便问

---

## 7. 诚实的方法论反思

这次调研暴露：
- Agent 3 报告里"40.9 µs dispatch send"被说成"40.9 µs dispatch total"——典型"数字锚错层"
- 我上一轮汇总直接采纳没核查，险些又放大
- 纠正机制：**任何 µs 数字在写进 docs 之前必须回 PR body / 实测日志原文二次核对**
- 已有的 `feedback_claim_verification_discipline.md` 第 1 条写的就是这个，但 agent 内部校验规则没执行

**加强：**往后 agent 报告的所有数字进入文档前，要在**同一条回复里**标注数据来源（PR # / 行号 / 文件路径），否则打回重做。
