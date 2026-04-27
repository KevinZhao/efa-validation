# UCCL-EP on EFA 优化预期性能收益汇总

**日期**：2026-04-26
**基线来源**：UCCL PR #745 post-merge 官方 p5en benchmark（`gh pr view 745 --repo uccl-project/uccl`）
**目的**：给所有"Sprint A/B/C + PR #485 + count-coalesce + Lever B + init 侧"的优化一个**诚实可验证的收益预期**，替代过往各份文档里的夸大声称。
**规则**：遵守 `feedback_claim_verification_discipline.md`——所有数字必须锚实测或明确标 UNKNOWN/推导。

---

## 0. 基线（必记）

**p5en 2-node 16-GPU, DSv3 shape** (hidden=7168, topk=8, num-experts=288, num-tokens=128, post-PR #745 `PER_EXPERT_BATCHING=1`)：

| 指标 | 值 |
|---|---|
| Dispatch both p50 | **174.9 µs** |
| Combine both p50 | **326.7 µs** |
| Dispatch send / recv p50 | 44.45 / 30.50 µs |
| Combine send / recv p50 | 47.74 / 46.72 µs |
| Dispatch BW | 42.88 GB/s |

**推导出的 decode per-token 数字**：
- 一层 EP 通信 ~500 µs（dispatch + combine）
- DSv3 58 MoE layer → EP 通信 ~29 ms/token
- 加 attention + GEMM → per-token ITL **~50 ms 数量级**
- 验证：SGLang PR #9660 H20 DP16+EP16 decode baseline mean ITL = 72 ms（数量级吻合）

---

## 1. 高置信预期（有 SGLang PR #9660 H20 实测锚）

### SBO Sprint A · GPU spin combine↔down_gemm

- **每层节省**：~7-10 µs combine overlap
- **全局 ITL**：**-5~-8%**
- **置信度**：高——SGLang PR #9660 H20 实测 mean ITL -7.9% (73 → 67 ms)
- **锚点**：`docs/SBO_COMP_SIGNAL_DEEP_DIVE.md` §8、SGLang PR #9660 body

### SBO Sprint B · CPU spin + 3 SM 释放给 DeepGemm

- **每层节省**：额外 3-5 µs
- **全局 ITL**：**再 -3~-5%**
- **置信度**：中
- **推导**：DeepGemm 多拿 2-3 SM → ~2% 吞吐线性增；CTA group-mate 解锁 ~1-2%
- **锚点**：`docs/SBO_COMP_SIGNAL_DEEP_DIVE.md` §4 OPT-1

**SBO 链小计**：decode ITL **-8~-13%**，对 50 ms baseline = **-4~-7 ms/token**

---

## 2. 中置信预期（推导未实测）

### PR #485 rebase · multi-QP in LL

- **每层节省**：5-10 µs dispatch send + combine tail
- **全局 ITL**：**-3~-5%**
- **依据**：消除 fast mode 单 QP 瓶颈（`rdma.cpp:1834` 单 `ctx->qp`）
- **不确定性**：decode batch=1 × top-8 并发度有限，实际收益可能偏下限
- **锚点**：`docs/FEASIBILITY_RECONFIRM.md` A1 条目

### count-send coalescing (Scheme A, 必须 #485 后)

- **每层节省**：3-5 µs dispatch
- **全局 ITL**：**-2~-3%**
- **依据**：16 AMO chain → 1 RDMA_WRITE + 1 IMM
- **锚点**：`docs/ALLTOALL_DEEP_DIVE.md` §4.1

### Lever B · Reduce kernel shared-mem prefetch

- **每层节省**：3-6 µs/token × 128 tokens = 400-800 µs/layer
- **全局 ITL**：**-1~-2%**
- **依据**：reduce 33 µs 里的内存访问模式优化
- **锚点**：`docs/COMBINE_RECV_DEEP_DIVE.md`（Agent A 产出）

**中置信小计**：decode ITL **-6~-10%**，对 50 ms = **-3~-5 ms/token**

---

## 3. 低置信预期（需先 instrumentation 验证）

> 🔧 **2026-04-26 Part 2 订正**（`docs/SRD_PROTOCOL_PART2.md`）：B2 SL 分流 + L6 DATA_POLLING_128 **埋掉**（SL firmware-opaque + efadv.h 未暴露 DATA_POLLING_128 userspace flag）；L1 **降级 Sprint D**（原理可行但工程链 4-6w）；**新增 L9 shared-SRD-QP 是 AWS 独占 lever**。

| 优化 | 预期 | 依赖 | Part 2 状态 |
|---|---|---|---|
| **L1 CQ_WITH_EXT_MEM** (GPU-BAR CQ) | 和 Sprint B 量级相当 | amzn-drivers ≥ r2.17.0 + rdma-core 自编 + L1-preview micro-bench | **降级 Sprint D** |
| **L2 INLINE_WRITE flag** | ACK 每 send 省 0.5-1 µs → P99 -几 µs | caps 确认 `INLINE_WRITE` bit + `efadv_get_max_sq_depth` 链 | 保留 |
| **L6 DATA_POLLING_128** | proxy CPU -10-30% | userspace efadv 未暴露，要走 uverbs 私有 | **降级（实施风险 ↑）** |
| **B2 SL 分流** | P99 -5-10 µs | SL firmware-opaque；UCCL 已全 SL=8 | **永久埋掉** |
| **L9 shared-SRD-QP** (Mooncake #1944 思路) | QP 数 / peers 倍减，消 cap 触顶；不直接减 ITL 但消 regression 风险 | S0-ext 先确认 max_qp runtime 值 | **新主排名**（AWS 独占） |

**低置信不计入汇总预期**——Instrumentation (见 `docs/FINAL_EXECUTION_CHECKLIST.md` §1) 后才能定。

---

## 4. 综合预期（假设 1+2 全部落地）

| 场景 | 当前 | 优化后 | 改善 |
|---|---|---|---|
| Decode mean ITL | 50 ms | **42-45 ms** | **-10~-15%** |
| Decode P99 ITL | ~100 ms | **80-87 ms** | **-12~-18%** |
| Output tok/s | 6667（PR #9660 H20 baseline）| **7400-7800** | **+10~15%** |

**对应 SGLang PR #9660 H20 数据**（SBO-only -7.9% mean ITL / +6.7% tok/s），叠 3 个额外优化到 -10~-15%，**数量级合理**。

---

## 5. TTFT 侧（完全不同的战场）

| 优化 | 预期 |
|---|---|
| L2 删除 `usleep(50ms)×2` | **-100 ms init**（确定）|
| L4 warmup API (port Mooncake #1944) | Cold first submit -50-100 ms |
| L1 并行 QP 创建 | init 阶段 2-3× 加速 |
| **TTFT 总改善** | **-200-500 ms first request**（Lane-E 场景）|

### 重要澄清

- **Stage 5 Kimi-K2 R1a TTFT 7329 ms 不会被 UCCL 优化影响**——R1a 是 Mooncake-only PD，不走 UCCL-EP
- UCCL TTFT 改善只在 **Lane-E EP-MoE 推理启动**时看到
- 锚点：`docs/FINAL_EXECUTION_CHECKLIST.md` §4 (Agent B)

---

## 6. 不会看到的改善（必须强调，防误读）

### 6.1 带宽数字不会大变
- Combine BW 从 17 GB/s → **不会** 变 34 GB/s
- 瓶颈不是带宽而是延迟协调
- SBO 攻延迟不攻带宽

### 6.2 不是"翻倍"级提升
- 之前 `CPU_PROXY_ADVANTAGE_LEVERS.md` 声称的 "P50 -63% P99 -74%" **是错的**（FEASIBILITY_RECONFIRM 已订正）
- 真实上限 **-15~-20%**，**不是 -63%**
- 不要期望数量级提升

### 6.3 Spot 场景收益有限
- A5 straggler soft degrade 已被驳回（FEASIBILITY_RECONFIRM）
- Stage 5 实测 Spot 回收是**整 node fatal**，不是 rank 慢
- UCCL 优化不解决 Spot 稳定性问题——那是 Karpenter / checkpoint 层面

### 6.4 大部分改善来自第一个 Sprint A
- Sprint A 单独 = 全部收益 **50-60%**
- 后续 lever 边际递减
- **不要为了 -1% ITL 做 2 周工程**

---

## 7. 工期 vs 收益密度

| 投入（人周）| 累计 ITL 改善 | µs/人周 | 价值密度 |
|---|---|---|---|
| 3 天 instrumentation | 0（但解锁一切）| — | **前置必须** |
| +2w SBO Sprint A | **-5~-8%** | **2-4%/w** | **最高** |
| +1.5w SBO Sprint B | -8~-13% | 2%/w | 高 |
| +1w PR #485 rebase | -11~-16% | 3%/w | 高（白嫖上游）|
| +1w count-coalesce | -13~-18% | 2%/w | 中 |
| +1w Lever B reduce prefetch | -14~-20% | 1%/w | 中 |
| +1.5w SBO Sprint C (Blackwell) | -14~-20% | 0 ITL 但开 p6 市场 | 兼容性必需 |

**最高 ROI 密度是 Sprint A**（2-4% ITL / 人周），其他是锦上添花。

---

## 8. 按决策点组织的投入建议

### 决策点 1 · 花 3 天做 instrumentation
- 投入 3 天 → 解锁所有后续 lever 的真实数字
- Outputs:
  - UCCL issue: AWS EFA caps dump（上游贡献）
  - 我们 fork 的 kernel/init timing marker 分支
  - 开启 `combine_wait_recv_cost_stats`
- **必做**（否则所有 ROI 声称都是空话）

### 决策点 2 · 是否做 SBO Sprint A (2w)
- 单独价值 **-5~-8% decode ITL**
- 上游 merge 门槛适中
- 同时建立 DeepEP antgroup-opt PR #483 的 AWS companion 关系
- **强建议做**

### 决策点 3 · Sprint B CPU-spin vs L1 GPU-BAR CQ
- **2026-04-26 Part 2 订正：两者不互斥**
- Sprint B 是增量改动（不依赖新 driver/库）1.5w → **先做**
- L1 是 greenfield（amzn-drivers r2.17.0 + rdma-core 自编 + UCCL 新代码 + P2P bench + persistent kernel）4-6w → **降级 Sprint D**
- 触发 L1 的条件：Sprint A+B+C 完成后 decode ITL 仍有 > 5% 头部可压 + L1-preview micro-bench 测 Nitro→HBM P2P CQE < 2 µs
- 本周 0.5 天 L1-preview micro-bench 零依赖，用数据决定 Sprint D 是否入 roadmap

### 决策点 4 · PR #485 rebase (3-5d)
- 低风险，白嫖上游 DRAFT
- 3-5 天我们加 p5en bench 推 MaoZiming merge
- **强建议做**，建立第二个合作接触点

### 决策点 5 · 其他（count-coalesce / Lever B / Sprint C）
- 每个边际 -1~-3% ITL
- 只在 Sprint A/B 落地后再考虑
- Sprint C 是 p6-b200 兼容必需

---

## 9. 预期对比旧文档声称（审计）

| 文档/声称 | 旧数字 | 本文修订 | 订正理由 |
|---|---|---|---|
| `UCCL_EP_SGLANG_EFA_OPTIMIZATION_DESIGN.md` P0 combine signal | -20% decode ITL | **-5~-8%** | 原对齐错 API (Blackwell src_signals)；Hopper comp_signal + H200 vs H20 compute 差距 |
| `CPU_PROXY_ADVANTAGE_LEVERS.md` | P50 -63% P99 -74% | **-15~-20%** | FEASIBILITY_RECONFIRM 6 agent 推翻 80% 声称 |
| `SBO_SPRINT_PLAN.md` Sprint A | decode ITL -5~8%, P99 -6~10% | **保持（与本文一致）** | 这份数字早就对齐了 |
| `ALLTOALL_DEEP_DIVE.md` count coalesce | ~700 µs/token | **400-800 µs/layer = -1~-2% ITL** | µs 数字正确但被错算成全局 ITL；58 layer 后累加真正意义要看 |
| `CPU_PROXY_ADVANTAGE_LEVERS.md` C1 persistent kernel | 600-1200 µs/token | **0（已驳回）** | FEASIBILITY_RECONFIRM 确认 CUDA Graph 已摊销 launch overhead |

---

## 10. 一句话结论

**全做完：decode ITL -10~-15%（50 ms → 42-45 ms）+ TTFT cold -200-500 ms（Lane-E 首次请求）**。

**只做 Sprint A：decode ITL -5~-8%**——2 周拿总收益 50-60%，**最划算的单步优化**。

**关键决定不是"做多少"，而是"按顺序做什么"**：先 3 天 instrumentation 拿权威数字，再按 Sprint A → #485 → Sprint B 顺序推，每步实测确认真实收益再推下一步。

---

## 11. 引用文件

- `docs/ALLTOALL_DEEP_DIVE.md` · p5en 新基线数字来源
- `docs/SBO_COMP_SIGNAL_DEEP_DIVE.md` · SBO 原理和 lever
- `docs/SBO_SPRINT_PLAN.md` · Sprint A/B/C 工期
- `docs/SBO_SPRINT_A_IMPLEMENTATION.md` · Sprint A 实施级设计
- `docs/COMBINE_RECV_DEEP_DIVE.md` · Lever B reduce prefetch 来源
- `docs/SRD_PROTOCOL_DEEP_DIVE.md` · efadv caps 漏查 + INLINE_WRITE
- `docs/FEASIBILITY_RECONFIRM.md` · 驳回清单
- `docs/FINAL_EXECUTION_CHECKLIST.md` · 执行计划
- SGLang PR #9660 body · H20 实测基准
- UCCL PR #745 body · p5en post-merge baseline
