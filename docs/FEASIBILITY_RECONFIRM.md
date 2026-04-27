# CPU-Proxy 独占 Lever 可行性复核报告

> 🔧 **REVISED FOOTNOTE (2026-04-26)** — `docs/SRD_PROTOCOL_DEEP_DIVE.md` 进一步精细化"EFA 硬约束"定义：
> - `sq_sig_all=1` 是**真驱动级硬约束**（A2 驳回仍然成立）
> - **但** `max_inline_data=0` 和 `max_send_sge=1` **不是**硬约束——是 UCCL 没开 `EFADV_QP_FLAGS_INLINE_WRITE` flag + 没查 `efadv_query_device` 真实 caps
> - **含义**：P4 / B2 的 inline 相关部分可能要重新审视（需要先做 1 天 `efadv_query_device` dump 实测 caps）
>
> 基于本文结论的执行顺序和预期收益已整合到 `docs/FINAL_EXECUTION_CHECKLIST.md` + `docs/EXPECTED_PERFORMANCE_GAINS.md`。

**日期**：2026-04-25
**复核方式**：6 个独立 agent 对 `docs/CPU_PROXY_ADVANTAGE_LEVERS.md` 的 TOP 10 lever 逐条核实，**不盲信前面 agent 的断言，独立读代码 + 实测数据 + 上游 PR**
**动机**：我们有过一次类似教训（`SGLANG_OPT_FEASIBILITY_REVIEW.md` 发现原设计 API 名字错、语义错），不能再让 P0 建在错误前提上
**结论**：原 TOP 10 里 **6 个直接垮掉**，**2 个收益被砍到 1/10**，**2 个成立但已有上游 PR**

---

## 总表：核实后的 10 个 lever

| 原排名 | Lever | 原声称 | 核实结论 | 真实收益 | 决策 |
|---|---|---|---|---|---|
| 🏆 1 | **C1 Persistent combine kernel** | 600-1200 µs/token | **NO-GO 前提错** | ≤0（24% SM tax 抵消） | ❌ 驳回 |
| 🥈 2 | **B1 Multi-NIC rail 聚合** | 带宽 2× | **CONDITIONAL** dispatch 已满 / combine 非 BW 瓶颈 | dispatch 1.6-2×，**combine <1.15×** | ⚠️ 延后 |
| 🥉 3 | **C2 Early-drop 非 top-k** | 200-400 µs/token | **NO-GO 概念错** | 0（payload 本来就按 topk 枚举）| ❌ 驳回 |
| 4 | **C3 Clean-elision** | 150-300 µs/token | **NO-GO 前提错** | 0（kernel 只在 mode 切换时跑一次）| ❌ 驳回 |
| 5 | **A1 Dynamic QP load balance** | 尾延 -30-50% | **GO 但收益砍半** | dispatch P50 个位 %，combine tail 10-20% | ✅ rebase #485 |
| 6 | **A6 NUMA/PCIe-local pinning** | 50-80 µs/step | **PARTIAL** 已 pin NUMA，可优化 CCX | 3-8 µs/token（砍 5-10×）| ✅ 小做 |
| 7 | **A2 Selective signaling** | proxy CPU -85% | **NO-GO EFA 硬限** | 0（`sq_sig_all=1` 驱动强制）| ❌ 驳回 |
| 8 | **A5 Straggler soft degrade** | decode P99 从 timeout 变正常 | **NO-GO 多重错** | 0（stage 5 无 straggler 事件 + 精度不可接受 + double-free）| ❌ 驳回 |
| 9 | **B2 SL 分流** | P99 -10-20 µs | **CONDITIONAL** 硬件隔离未证 | 0-10 µs/P99（需实测）| ⚠️ 实测再定 |
| 10 | **A3 Post-send batching window** | 3-6 µs | **NO-GO 前提错** | 0（已经隐式 batch）| ❌ 驳回 |

**净结果**：10 个里 **5 直接驳回 / 2 延后 / 3 可做但规模大幅缩水**。

---

## 1. 彻底驳回的 5 个 lever

### C1 · Persistent combine kernel ❌
**声称**：60 层 × 10-20 µs launch = 600-1200 µs/token 可省

**真相**：
- SGLang decode **默认开 CUDA Graph**（`server_args.py:622-625` `disable_cuda_graph=False`），LL 路径有 `DeepEPCudaGraphRunnerAdapter`（`cuda_graph_runner.py:603, 1429-1446`），UCCL PR #620 已经合入 Graph 支持
- CUDA Graph replay **<2 µs per step**（不是 per layer × 60）
- 10-20 µs 是 eager-mode cold launch 数字，不是 SGLang 实际场景
- 真实 leftover 只有 `cudaGetDevice`/`cudaDeviceGetAttribute` host 查询导致的 ~60-180 µs/token，**launcher 侧缓存 ~1 天工作量就能修**，不需要 persistent kernel
- Persistent kernel 占 32 SM = H200 132 SM 的 24% = **反而拖慢 attention/gemm**
- Issue #734 真实标题是 "vLLM hangs in LL mode over EFA"，**不是 persistent kernel 请求**，且已 closed 2026-04-21

**代码证据**：
- `/home/ec2-user/workspace/sglang/python/sglang/srt/server_args.py:622-625`
- `/home/ec2-user/workspace/uccl/ep/src/internode_ll.cu:1242-1246`（`cudaGetDevice` + `cudaDeviceGetAttribute` 这才是真实 leftover）

**替代 lever**：launcher-cache (`cudaDeviceGetAttribute` 结果静态化) = 1 天，1-3 µs/layer × 58 层 = 60-180 µs/token。**这才是 C1 该做的**。

---

### C2 · Early-drop 非 top-k ❌
**声称**：decode batch=1 × top-8 场景每层白发 248 个非 topk expert 的 WR

**真相**：
- UCCL-EP dispatch kernel `internode_ll.cu:121-291` 严格按 `topk_idx` 枚举，只有 `dst_expert_idx >= 0` 才发 payload WR
- decode batch=1 × top-8 每 token 只发 **8 个 payload WR**，**不存在 248 白发**
- Agent 把 **payload-send**（per-topk，7.5 KB）和 **count-send**（per-(expert, rank)，8 字节 AMO sentinel）混了——count sentinel 是 receiver 死锁检测必需，不能省
- Stage 2 实测 dispatch total send **85-200 µs**，塞不下"200-400 µs 节省"——**原声称硬上限违反**

**代码证据**：
- `/home/ec2-user/workspace/uccl/ep/src/internode_ll.cu:121-291, 403-453`
- `/home/ec2-user/workspace/efa-validation/results/stage2/PERF_RESULT.md`

**替代 lever**：count-send coalescing（per-rank 把 32 个 AMO 合并成 1 个 RDMA WRITE），**上限 10-30 µs/层**，不是 200-400，重新评估后算小 lever。

---

### C3 · Clean-elision ❌
**声称**：`clean_low_latency_buffer` 每 step 启 256 线程 kernel，150-300 µs/token

**真相**：
- kernel 确实存在（`internode_ll.cu:40-47`）
- 但调用路径是 `Buffer::clean_low_latency_buffer` ← `DeepEPBuffer.clean_buffer()` ← `set_dispatch_mode_as_low_latency` **只在 `_dispatch_mode == NORMAL` 时跑一次**（prefill → decode 切换），**不是每 step**
- decode 内部的清零是 dispatch/combine kernel 内联 warp-level `next_clean[i] = 0`，已经只清 live slot
- "150-300 µs/token × 60 层" 模型**完全错**

**代码证据**：
- `/home/ec2-user/workspace/sglang/python/sglang/srt/layers/moe/token_dispatcher/deepep.py:242-258`（gate 证据）
- `/home/ec2-user/workspace/uccl/ep/src/internode_ll.cu:298-299, 780-781`（inline clean 证据）

---

### A2 · Selective signaling ❌
**声称**：每 8 WR signal 1 次，proxy CPU -85%

**真相**：
- `rdma.cpp:903` `sq_sig_all = 1` 是 **SRD QP 创建时驱动硬限**，不是可选配置
- 对比 `rdma.cpp:975` 非 EFA (RC) path `sq_sig_all = 0`，selective signaling 是 RC 正常行为
- 所有 EFA post 调用点都显式写 `IBV_SEND_SIGNALED`（`rdma.cpp:1437, 1866, 2005, 2019, 2033`）和 `sq_sig_all=1` 一致
- EFADV SRD 文档：**SRD CQE 不可抑制**，和 UD 不同
- 和之前 SGLANG_OPT_FEASIBILITY_REVIEW 里 Agent 结论（"EFA SRD 强制 signaled"）**一致**，这次 claim 是错的

**唯一相关的**：`ibv_poll_cq` batch（一次 poll N 个 CQE），是 poll 端不是 signal 端，**和声称不是同一件事**。

---

### A5 · Straggler soft degrade ❌
**声称**：spot preemption / NIC flake 时 proxy 合成 ack + GPU 跳过死 rank，P99 从 timeout 变正常

**真相**：
- **Stage 5 实测没有 straggler 事件**，stuck 都是 FSx/cross-AZ（`r1a-kimi-k2-1p1d/ROOT_CAUSE_FINAL.md`, `r3-glm46-1p2d/ABORT.md:44`）
- Spot 回收是**整 node fatal**（R1b 3 台同时被抢），不是"rank 慢 100 ms"；合成 ack 顶不过去
- "zero-fill 精度不敏感"**是伪命题**：combine 是 **gating-weighted sum**，单 token 有可能 60% 权重押在死 rank 上，输出严重走样，greedy decode 立即分叉
- 生产 SLA "正确 or 5xx"，**不接受概率性错误输出**
- 假 ack 后真 CQE 到会 **double-free**（`acked_wrs_` 状态已推进不可撤回，`proxy.cpp:580-599`）
- Atomic imm 编了 seq（`rdma.cpp:1473-1480`），假 ack 后 seq 冲突
- UCCL 上游 **0 篇 straggler/soft-degrade 讨论**，DeepEP fail-fast 语义颠覆**不会被接受**

**代码证据**：
- `/home/ec2-user/workspace/uccl/ep/src/uccl_ep.cc:686-698, 933-946`（timeout 抛异常路径）
- `/home/ec2-user/workspace/uccl/ep/src/proxy.cpp:580-599`（acked_wrs_ 推进不可撤回）

---

### A3 · Post-send batching window ❌
**声称**：当前每次 dequeue 立刻 post，加 3 µs 窗口聚合能省 3-6 µs

**真相**：
- **当前已经有隐式 batch**：`proxy.cpp:624-671` drain loop `for (take=0; take<budget; ++take)` 一次拿多个 cmd
- `post_gpu_commands_mixed` 按 (dst_rank, ring_idx) 聚合，所有 WR chain 在一个 `ibv_wr_start`/`ibv_wr_complete` 之间（`rdma.cpp:1426-1505`）
- decode top-8 dispatch 自然填 8 组 × ≥1 WR，doorbell 数 = 实际组合数，不是 N
- 声称"每次只 1-2 WR 付 doorbell"**前提错误**
- 加 3 µs window 会拖慢 barrier/atomic（`proxy.cpp:635-642` 已 inflight 时提前 break），**净收益可能为负**
- 1-2 天工作量低估，需要 critical/bulk 分流 + A/B bench ≥ 3-5 天

---

## 2. 部分成立但收益砍掉的 2 个 lever

### B1 · Multi-NIC rail 聚合 ⚠️ CONDITIONAL
**代码层声称 100% 成立**：
- `rdma.cpp:487-495` p5en 代码里 hardcoded comment "first half proxies use first NIC, second half use second NIC"
- **每 GPU 确实只用 2 NIC 不是 4**
- 8 channel QP 都绑同一 `pd`（`rdma.cpp:994-1008`）
- UCCL issue #146 + PR #374 ("Debug why p5en two GPU internode ll only has 3GB/s bandwidth") 都确认是已知 pain point

**但 "带宽 2×" 要按流量类型分**（Stage 2 实测数据）：
| 流量 | 实测 | 2-NIC 理论上限 | 4-NIC 后预期 |
|---|---|---|---|
| Dispatch FP8 | **408 Gbps** | 400 Gbps | 1.6-2× ✅ |
| Dispatch BF16 | 517 Gbps（含 NVL）| 400 Gbps | 1.6-2× ✅ |
| **Combine BF16** | **137 Gbps** | 400 Gbps | **<1.15×** ❌ |

**Combine 瓶颈不是带宽**，是 receiver-barrier + notify overhead（transmit 6806 µs, notify 390 µs）。**decode 场景 combine 占比高，B1 对 decode 延迟目标收益有限**。

**工作量严重低估**：声称 2 周，实际 3-5 周（需要改 ProxyCtx 成 per-NIC、MR 多 NIC 注册、DMA-BUF cache 多 NIC key、ack_qp 多 NIC）。

**决策**：**延后**。不做 decode ROI 差；做的话作为 Stage 5 后期 prefill 优化。

---

### A6 · NUMA/PCIe-local CPU pinning ⚠️ PARTIAL
**真相**：
- proxy 线程**已经 pin 到 NIC NUMA**（`proxy.cpp:119-124` 读 `ctx_.numa_node` = NIC 的 NUMA）
- 声称"cross-socket 300-500 ns vs local 60-80 ns"**前提不成立**（已经同 NUMA）
- 真正可优化的是 NUMA 内"任意核 → PCIe-local CCX"（30-80 ns/doorbell）
- decode 每 token doorbell 数 ~120，60-80 ns × 120 = **7-10 µs/token 上限**
- **真实收益 3-8 µs/token，不是声称的 50-80**（砍 5-10×）

**决策**：**可做但降级**。2 天工作量，3-8 µs 收益，作为小改进。

---

## 3. 成立但已有上游 PR 的 1 个 lever

### A1 · Dynamic QP load balancing ✅ rebase #485
**代码层声称 100% 成立**：
- `rdma.cpp:1834` fast mode 确实单 QP：`qpx = ctx->qp`，完全不用 `data_qps_by_channel`
- `data_qps_by_channel` 在 LL 模式**根本没被分配**（`use_normal_mode` gate）
- fast mode per-peer 3 SRD QP（qp/ack/recv_ack），**只有 1 走数据**

**但"HOL blocking" 措辞不准**：SRD 是 datagram 无协议层 HOL，真正是 submission-side SQ congestion

**收益砍半**：
- 声称 P99 -30-50%
- decode batch=1 每 peer 才 1-8 WR，多 QP 需要 >4 inflight 才线性分摊
- 真实：dispatch P50 **个位数 %**，combine tail **10-20%**，不是 30-50%

**🎯 上游已有 PR #485**：
- **UCCL PR #485 "[EP] mult-qp for ll"** by **MaoZiming**（UCCL 维护者，也是 PR #904 / P0 reviewer）
- 2025-10-28 创建，2025-11-02 更新，**DRAFT 5 个月没动**
- 单 commit 就是去掉 `#ifdef USE_NORMAL_MODE` 把 `data_qps_by_channel` 扩到 LL——**完全就是我们想要的**
- 无测试、空 PR description

**决策**：**rebase #485 到我们 fork + 加 p5en benchmark + 推 MaoZiming merge**。不重写。符合 memory `feedback_uccl_pr_aws_bench`（UCCL 团队无 AWS 环境我们出数据是权威），还能和 MaoZiming 建立第二个合作接触点。

---

## 4. 需要实测才能定的 1 个 lever

### B2 · Service Level 分流 ⚠️ 实测再定
**代码改动易**：
- `common.hpp:30 EFA_QP_LOW_LATENCY_SERVICE_LEVEL=8`
- `rdma.cpp:911` 当前所有 EFA QP 都走 SL=8
- 改成 signal QP SL=8 / data QP SL=0 代码改动 <1 天

**但物理隔离存疑**：
- EFA SRD 的 `sl` 是 software-visible hint
- AWS **未公开** SRD 调度细节：SL=0 vs SL=8 是独立硬件 queue 还是软 tag
- 如果是软 tag → 没有物理隔离 → P99 收益 0
- 如果是独立 queue → 乐观 P99 -5-10 µs

**决策**：**改 1 天 + p5en 实测 1 天**，2 天内拿数据决定做不做。**不先投**。

---

## 5. 重大更正：之前文档里的错误

### 更正 1：C1 不是最大 lever
`docs/CPU_PROXY_ADVANTAGE_LEVERS.md` 把 C1 排 🏆 1，单步 600-1200 µs。**全错**。SGLang 已 CUDA Graph 摊销，leftover 60-180 µs。

### 更正 2：C2 完全是概念错误
agent 把 payload-send 和 count-send 路径混了。payload WR 严格按 topk_idx 只发 8 个，不存在 248 白发。

### 更正 3：C3 kernel 不是 per-step
只在 prefill↔decode mode 切换时跑一次，不是每 decode step。

### 更正 4：A2 和之前结论矛盾时应该信之前的
之前 agent（SGLANG_OPT_FEASIBILITY_REVIEW）说 EFA SRD 强制 signaled，这次 agent 说能 selective——这次 agent **错**，`sq_sig_all=1` 硬限是 SRD 驱动级，不是代码开关。

### 更正 5：A5 精度声称是伪命题
"zero-fill 一个 rank 精度不敏感" 错。combine 是 gating-weighted sum，权重重尾分布，单 token 严重走样。

---

## 6. 真正剩下可做的 lever（按诚实的 ROI 排序）

| 排名 | Lever | 真实收益 | 工作量 | 状态 |
|---|---|---|---|---|
| 1 | **C1→launcher-cache**（替代 C1 的小版本）| 60-180 µs/token | 1 d | 新 lever，未提交 |
| 2 | **A1 rebase PR #485** | dispatch +% / combine tail 10-20% | 3-5 d（含 bench）| 上游 DRAFT 等合入 |
| 3 | **A6 PCIe-local CCX pin** | 3-8 µs/token | 2 d | 小改 |
| 4 | **C2→count-send coalescing**（替代 C2 的小版本）| 10-30 µs/层 | 3-5 d | 新 lever |
| 5 | **B2 SL 分流 + 实测** | 0-10 µs/P99 | 2 d | 需实测决定 |

**总计能赚到的真实收益**：80-220 µs/token + dispatch 带宽 % 提升 + combine tail 10-20%

**比原声称（单个 C1 就 600-1200 µs/token）**砍到 **1/5 ~ 1/10**。

---

## 7. 方法论反思

**为什么原文档错那么多？**

1. **"声称链"式放大**：agent 1 说 A，agent 2 基于 A 推出 B，B 带了 A 的错误
2. **数字没锚定实测**：很多 µs 估计建立在假设上（"每层 × 60 层 × 10 µs"），实测 Stage 2 数据没引入
3. **忽略上游已存在的工作**：PR #485 / PR #620 没 check，重新造轮子声称
4. **CUDA Graph 被低估**：SGLang 默认开，但被当成 disabled 算 launch overhead
5. **EFA SRD 硬约束被软化**：`sq_sig_all=1` 在一个 agent 里被当作可配置

**往后规则**（已立 memory feedback）：
- 任何延迟声称必须引用 Stage 2/3 实测数据锚定
- 任何架构优化必须先 grep 上游 PR/Issue 查已有工作
- 任何 CUDA 路径优化必须区分 eager vs CUDA Graph vs 图捕获路径
- 任何 EFA 硬件特性必须从 `rdma.cpp:884-964` SRD QP 创建代码读实际约束

---

## 8. 最终建议

**不要做**（从 roadmap 移除）：
- C1 persistent kernel（做 launcher-cache 即可）
- C2 early-drop（改成 count coalescing 小 lever）
- C3 clean-elision（压根没 per-step kernel）
- A2 selective signaling（硬限）
- A3 batching window（已有）
- A5 straggler degrade（问题不存在 + 语义不可接受）

**延后**（Stage 5 后期考虑）：
- B1 multi-NIC（只对 dispatch 带宽，3-5 周工作量）

**近期做**：
1. **launcher-cache** `cudaDeviceGetAttribute` 缓存（1 天，60-180 µs/token）—— 换皮"简化版 C1"
2. **rebase PR #485 + p5en bench** A1 multi-QP（3-5 天，dispatch P50 个位 %/combine tail 10-20%）
3. **A6 CCX pinning**（2 天，3-8 µs/token）
4. **count-send coalescing**（3-5 天，10-30 µs/层，可选）
5. **B2 SL 分流 + 实测**（2 天，0-10 µs P99，可选）

**总工期**：~2 周认真投入就能覆盖 1-3；优先级最高的 **SBO Sprint A 仍是主轴**——这几个小 lever 是 Sprint A 之后的"补丁"，不是替代。

---

## 9. 相关文档

- `docs/CPU_PROXY_ADVANTAGE_LEVERS.md`：被本文档**大幅订正**的原 20 lever 大全
- `docs/SBO_SPRINT_PLAN.md`：SBO 三 Sprint 计划，仍是主线
- `docs/SBO_COMP_SIGNAL_DEEP_DIVE.md`：4 agent 的 SBO 深度调研（可信）
- `docs/SGLANG_OPT_FEASIBILITY_REVIEW.md`：之前的 P0-P5 可行性复核方法论
- UCCL 上游 PR：#485（multi-QP LL）、#620（CUDA Graph 合入）、#904（our warmup PR）
