# UCCL-EP on EFA 稳态 decode 优化：最终可执行 Checklist

**日期**：2026-04-26
**状态**：从"探索优化点"正式过渡到"可执行 checklist"
**依据**：全部基于 agent 独立核实 + 实测数据锚定（PR #745 post-baseline）+ 订正过的前人文档

---

## 0. 基线数字（必记）

p5en 2-node 16-GPU post-PR #745（从 PR body 官方数据）：

| 指标 | 值 |
|---|---|
| Dispatch both p50 | **174.9 µs** |
| Combine both p50 | **326.7 µs** |
| Dispatch send p50 / recv p50 | 44.45 / 30.50 µs |
| Combine send p50 / recv p50 | 47.74 / 46.72 µs |
| Dispatch BW | 42.88 GB/s |

**Combine recv 46.72 µs 是纯 GPU 计算（Agent A 证实），不是等网络**：
- Kernel launch 5 µs + grid sync 3-8 µs + reduce 33 µs + exit 1 µs
- 326 µs - 94 µs (send+recv) = 232 µs **正是 SBO Sprint B 攻击的网络等待**

**UCCL-EP init 1-2 秒（Agent B 证实），已经接近 Mooncake post-#1944 水平**：
- Stage 5 R1a Kimi-K2 TTFT 7329 ms **不是 UCCL 成本**，R1a 是 Mooncake-only PD
- UCCL-EP init 在 Lane-E（EP-MoE decode）跑起来才上 critical path

---

## 1. 立即可做的 Instrumentation（本周 2 天）

**没有这些数字，所有后续 ROI 声称都是空话**。优先级最高。

### P0 · 1 天 · `efadv_query_device` probe
- 文件：`/home/ec2-user/workspace/uccl/ep/src/rdma.cpp:884` `create_srd_qp_ex` 入口
- 加 `efadv_query_device()` + stderr dump
- Dump p5en / p6-b200 / p6-b300 各跑一次
- 输出：`max_sq_sge` / `inline_buf_size` / `device_caps bitmask` / `max_rdma_size`
- 存：`results/stage5-p5en/efa_caps/<instance>-<date>.txt`
- **Push 到 UCCL 上游作为 issue**: "AWS EFA capability dump for UCCL maintainer reference"——符合 `feedback_uccl_pr_aws_bench`

### P0 · 1 天 · combine kernel timing markers
- 文件：`internode_ll.cu` line 1083/1143/1149/1200
- 4 个 `clock64()` marker 分离 spin / grid_sync / reduce / exit
- Gate `UCCL_EP_KERNEL_TRACE` env
- **目的**：验证 Agent A 的分解是否准确（reduce 真的是 33 µs 吗）

### P1 · 1 天 · init-path timing
- 文件：`proxy.cpp:175/184/247-280/285-310/327-389` + `rdma.cpp:620/916`
- `StageTimer` helper + `INIT_STAGE(name)` macro
- Gate `UCCL_EP_INIT_TRACE` env
- **目的**：拿到真实 per-phase 时间，决定 L1 并行 QP 和 L4 warmup API 的优先级

### P1 · 0.5 天 · 开启 `combine_wait_recv_cost_stats`
- 文件：`buffer.py:438` + `uccl_ep.cc`
- **已经 plumbed 只是默认未用**
- 拿 per-peer flag-wait cycles 诊断尾延迟
- 免费的诊断，不需要新代码

**交付**：2 天工作，1 个 UCCL issue（caps dump），2 个开 env gate 的小 diff。

---

## 2. SBO Sprint A 主 PR 的实施级设计已完成

见 `docs/SBO_SPRINT_A_IMPLEMENTATION.md`（41 KB，12 节），可直接开工。**订正了前人 5 处文档错误**：

| # | 错误 | 订正 |
|---|---|---|
| 1 | SBO_SPRINT_PLAN §A.3 说 `packed_recv_src_info` 必须 int32→int64 升级 | **SBO Sprint A 不需要**。SM-stripe 按 `(local_expert, block_in_expert)` 键，保留外 `for (dst_rank)` 循环，src_info 保持 int32。ABI 不变。**延到 Sprint B 再考虑** |
| 2 | SBO_SPRINT_PLAN §A.5 workspace 算错 | 正确：`atomic_clean_flag[1] + grid_sync_barrier[1] + finish_counter_per_expert[num_local_experts]` |
| 3 | SBO_COMP_SIGNAL_DEEP_DIVE §3 称 `__nanosleep` sm_90a 是 "100-cycle busy-wait" | **错**——Hopper `__nanosleep` 是真硬件定时 pause，释放 issue slot（sibling warp 能跑）。overlap 含义不变但机制不同 |
| 4 | Memory ordering 决策未明 | Sprint A 用 `.gpu`+`.gpu`（producer/consumer 同 device 同 process）。**DeepGemm `release.sys` patch 延到 Sprint B**（那时 CPU 才真读 signal） |
| 5 | Finish flag race 位置只说 `:1069` | 正确：整个 `internode_ll.cu:1037-1078` finish block |

### Sprint A 关键 API 摘要

```cpp
// uccl_ep.cc:1287 新签名 (新增 6 个 kwargs，默认值保持老路径)
std::optional<EventHandle> low_latency_combine(
    ..., // 现有参数
    bool overlap = false,
    std::uintptr_t packed_recv_count_ptr = 0,
    std::uintptr_t comp_signal_ptr = 0,
    int block_m = 64,
    int threshold = 0,
    int num_sms = 3)
```

### smem 预算
- 当前：`kNumTMABytesPerWarp = 6336 B × 32 warps = 202 KB`
- 新增：`num_local_experts * sizeof(int)` (128 B) + `scan temp` = 520 B
- 总：203 KB / 228 KB Hopper opt-in ✅

### 测试策略（文档里详细）
- 4 个新 unit test
- p5en 2-node 16-GPU microbench（overlap on/off × num_sms ∈ {1,2,3,4,8}）
- SGLang E2E Kimi-K2 decode
- CUDA Graph 兼容（`comp_signal` 必须 pre-allocate + zero_() in captured region）

### 工作量
**2 周**（前人预估），文档里有逐日任务分解。

---

## 3. Combine recv 路径的新 lever（Agent A 发现）

**46.72 µs = 33 µs reduce + 13 µs 其它**。真正可压缩的是 reduce kernel。

### Lever B（**最大新发现**，3-6 µs）· Reduce kernel shared-mem prefetch
- 文件：`internode_ll.cu:1155-1199` reduce loop
- 当前：每 token 读 top-8 source rows 直接 DRAM
- 改：re-tile hidden-chunk 到 shared memory 后逐 top-k 读
- 预期：3-6 µs/token × 128 tokens = **省 400-800 µs/layer**
- 复杂度：MEDIUM，~1 周
- **和 SBO 正交**，可独立做

### Lever A（MEDIUM，0.5-1 µs）· combine-send atomic 合进 data WR
- 当前：combine 发送 data + 单独 atomic recv_flag
- 改：最后一个 data WR 的 imm 夹带 recv_flag trigger
- 预期：对端 proxy 省一次 CQE poll
- **和 Sprint A 叠加**

### Lever C（HIGH，3-5 µs）· Epilogue fuse with next attention pre-norm
- 需要 SGLang 侧改
- **和 FEASIBILITY_RECONFIRM 驳回的 C4 attention↔dispatch overlap 是不同路径**
- HIGH 复杂度，放到后期

### 不做
- **Lever D 替换 grid sync 为 global counter spin**：低 ROI (1-2 µs) skip
- **LogFMT decode 优化**：recv 侧根本没有 decode，cost = 0
- **Flag atomic memory model**：已经 `.acquire.sys`，已最优

---

## 4. Init 路径 lever（Agent B 发现）

**UCCL-EP init 1-2 秒，不是瓶颈**——但 Lane-E 跑起来后会上 critical path。

### L2（无风险 0.5 天，确定 +100 ms）· 删除 `usleep(50ms) × 2`
- 文件：`proxy.cpp:282, 390`
- 改为显式 sync（close listen_fd ack）
- **零风险确定收益**

### L4（1 周，最高 TTFT 影响）· 显式 `warmup()` API
- 对应 Mooncake #1944 的 `warmup_efa_segment()`
- SGLang 启动阶段调用
- 预热 SQ/CQ + EFA AH cache
- Cold first submit 省 50-100 ms

### L1（1 周）· 并行化 `for (peer) create_srd_qp_ex`
- 文件：`proxy.cpp:247-280`
- 串行 → thread pool
- 2-3× 此段加速

### L3（2 周）· OOB `bootstrap_allgather` 替代 pair-wise TCP
- 基于已 merged PR #902 OOB refactor
- 省 ~100 ms

### 不做 / 延后
- **L5 `g_shared_rdma_cache` audit**：Agent B 实测发现已经最优，mutex 不 hold during `ibv_reg_mr`
- **L6 shared QP across proxies (port of #1944)**：真实收益 500ms-1s 而不是 10-25s（UCCL 已经接近 Mooncake 的 1944 post 水平）
- **L7 lazy peer QP**：EP 全 mesh 通信，无价值

---

## 5. 修订后的完整执行 Roadmap

### Week 1-2 · Instrumentation + Sprint A 启动
1. **Day 1-2**：Section 1 全部 instrumentation（efadv caps + kernel timing + init timing + recv_cost_stats）
2. **Day 3-5**：用数字验证 Sprint A 设计的每个假设（smem 预算、spin cycle、reduce 实测 33 µs 吗）
3. **Day 6-14**：执行 SBO Sprint A 按 `docs/SBO_SPRINT_A_IMPLEMENTATION.md` 的 12 节

**交付**：
- UCCL issue："AWS EFA capability dump"
- UCCL PR：Sprint A GPU spin（主 PR）
- 我们 fork 的 instrumentation 本地使用

### Week 3-4 · Sprint A review + 第二批小 PR
1. 等 Sprint A 上游 review
2. 并行推 **L2 删除 usleep**（0.5 天）和 **count-send coalescing**（如果 #485 已 merge）
3. Lever B reduce shared-mem prefetch 独立 PR

### Week 5-6 · Sprint B 二元决策
决策依据：P0 instrumentation + "CPU poll vs GPU poll" 二元 bench
- 分支 A: SBO Sprint B CPU spin
- 分支 B: L1 CQ_WITH_EXT_MEM (`EFADV_CQ_EXT_MEM`)

### Week 7-8 · Init 优化 + 其他
- L4 warmup API
- L1 并行 QP 创建
- L3 bootstrap_allgather (如果 #902 OOB 稳定)

### Week 9+ · Sprint C (Blackwell) + Follow-up
- p6-b200 上 `src_signals` 协议
- FlashInfer CuteDSL 集成

---

## 6. 下一步具体动作（今天就能做的）

1. **起一个新分支** `instrumentation/efa-caps-dump` 在 `KevinZhao/uccl` fork
2. **加 `efadv_query_device` dump**（1 天 P0），跑 p5en bench 一次
3. **Push 到 UCCL 上游**作为 informational issue（不是 PR）
4. **同时起 `instrumentation/kernel-init-timing`** 分支做 Section 1 剩下的 3 个 marker
5. **Stage 5 p5en run 时顺带开 trace**，dump 到 `results/stage5-p5en/instrumentation/`

---

## 7. 关键决策点清单（等 instrumentation 数据）

| 决策 | 等什么数据 |
|---|---|
| Sprint A `num_sms` 默认值 (1 / 2 / 3) | microbench overlap on × num_sms sweep |
| Sprint B CPU spin vs L1 GPU poll | Instrumented CPU poll latency vs GPU poll latency bench |
| DeepGemm `release.sys` patch 要不要提 | Sprint B 方向定后 |
| `kChannelPerProxy` 默认值 (当前 8) | PR #485 multi-QP bench 结果 |
| B2 SL 分流要不要做 | efa_caps 看 SL 是否物理隔离 |
| L1 GPU-BAR CQ 要不要做 | efa_caps `CQ_WITH_EXT_MEM` bit 是否 1 |

---

## 8. 和上游沟通计划

按次序：
1. **本周**：提 EFA caps dump issue → 建立和 MaoZiming/YangZhou1997 的第二个对话点（第一个是 #904）
2. **下周**：Sprint A 主 PR (WIP)，标注 "companion to DeepEP antgroup-opt PR #483"
3. **3 周内**：通过 #485 review thread 问 MaoZiming 进度，若 5 个月没动意向接管
4. **Sprint A merged 后**：发现的 5 个前人文档错误作为 PR review feedback，展示我们的核查深度

---

## 9. 文档更新追踪

本次深挖产出的 3 份新 docs + 1 份本 checklist：
- `docs/COMBINE_RECV_DEEP_DIVE.md`（Agent A）
- `docs/SBO_SPRINT_A_IMPLEMENTATION.md`（Agent C）
- `docs/FINAL_EXECUTION_CHECKLIST.md`（本文）
- Agent B 的 init timing analysis 直接进入本 checklist §4，未独立成 doc

**本 checklist 订正的前人文档**（需要打 footnote）：
- `SBO_SPRINT_PLAN.md` §A.3, §A.5（见 §2）
- `SBO_COMP_SIGNAL_DEEP_DIVE.md` §3（`__nanosleep` 行为）

---

## 10. 方法论收获

这一轮深挖验证了 `feedback_claim_verification_discipline.md` 的 4 条规则依然有效：

1. **数字锚实测**：PR #745 post-baseline 174.9/326.7 µs 取代所有过时 "450/600 µs" 估算
2. **grep 上游 PR**：#745 已 merged，#485 DRAFT 5 个月，#902 已 merged，#904 是我们自己的——这些决定了 lever 实施顺序
3. **CUDA Graph 区分**：Agent A 发现 recv 46.72 µs 在 graph 下不变（kernel body 本来就不摊销）
4. **EFA 硬约束从代码读**：SRD_PROTOCOL_DEEP_DIVE 发现 `max_inline_data=0` 不是驱动硬约束，是 UCCL 没开 flag

**新加规则**（应入 feedback）：
5. **API 不要凭空设计，要先读对应 DeepEP PR 的 diff**：Sprint A `packed_recv_src_info` int32→int64 是从 DeepEP #483 照搬的，但用不同的 SM-stripe 策略可以不升级。Agent C 订正了这个设计继承错误。

---

**一句话结论**：之前所有"探索式调研"都给完了。现在进入"按 checklist 执行"阶段——先做 3 天 instrumentation 拿权威数据，再按 SBO_SPRINT_A_IMPLEMENTATION.md 开工。
