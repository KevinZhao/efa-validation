# SGLang+UCCL-EP+EFA 推理延迟优化方向可行性复核

**日期**：2026-04-25
**复核方式**：5 个独立 agent 并行核查 `docs/UCCL_EP_SGLANG_EFA_OPTIMIZATION_DESIGN.md` §4 的六个优化方向（P0-P5）
**目的**：推翻或确认原设计中的价值 / 可行性声称，避免在错误前提上投入工程时间

---

## 总结表

| 优先级 | 名称 | 原声称收益 | 复核结论 | 真实可达收益 | 主要致命伤 |
|---|---|---|---|---|---|
| **P0** | combine signal API | -20% decode | **GO-but-conditional** | -10~15% | 原设计 API 名称搞错（`src_signals` 是 Blackwell 死分支，生产用 `comp_signal` 在 DeepEP `antgroup-opt` 分支） |
| **P1** | dispatch per-expert early release | P99 -30-40% | **NO-GO** | ≤5% | 下游 DeepGemm/CuteDSL 是 grouped GEMM 一次 launch，per-expert signal 消费端不存在 |
| **P2** | single-token fast path | dispatch -45% | **NO-GO** | 1-3%（退化版 5-8%） | EFA 驱动不暴露 doorbell/WQE 给 GPU map，"单 warp 直写 WQE" 硬件不可行 |
| **P3** | LL TBO 启用 | throughput +30-50% | **NO-GO（定位错）** | 0 | decode+LL 本来就启用；被禁的只是 extend+LL；且 DeepEP 自己承认 TBO 对 decode 负收益，已改走 SBO |
| **P4** | Ctrl/Data QP 分离 + inline | -500 ns/count | **NO-GO（前提破）** | 0 | EFA SRD 不支持 inline（硬件约束）+ 强制 signaled + count 本来就是 WRITE_WITH_IMM 无 DMA fetch 可省 |
| **P5** | prefill/decode 分 QP 配置 | proxy CPU -60% | **WEAK-GO** | 未知 | kChannelPerProxy/kNumProxyThs 是编译期 `#define`，改起来 8-10 天（非 4）；且 proxy CPU 省下不转化为 GPU 延迟降低 |

**净结论**：**六个方向里只有 P0 可以继续走，且必须重新设计**。P1/P2/P3/P4 基于错误前提，P5 收益模糊。

---

## 详细核查结论

### P0：combine signal API — GO-but-conditional

**原设计**：在 `low_latency_combine` 加 `src_signals` + `src_signal_expect_value` 参数，让 SGLang SBO 的 combine↔down_gemm 两流 overlap 走通。声称 -20% decode。

**核实发现**：
1. `src_signals` 在 DeepEP 官方 main 分支**不存在**、UCCL-EP 不存在、全 GitHub 只有 SGLang `deepep.py:707-708` 一处（Blackwell 独占分支），**曾被本文判定为死代码**——2026-04-26 更正：Producer 在 FlashInfer CuteDSL (`grouped_gemm_masked_blackwell.py:1790+`)，**不是死代码**，Blackwell 分支真实可达。详见 `docs/SBO_COMP_SIGNAL_DEEP_DIVE.md` §0 和 `docs/SRD_PROTOCOL_DEEP_DIVE.md`。
2. 生产用的是另一个名字 `comp_signal` + `packed_recv_count` + `block_m` + `threshold` + `num_sms`，活在 **DeepEP `antgroup-opt` 分支**（PR #483，2025-11-21 合入）。SGLang 非-Blackwell 分支 `deepep.py:711-717` 用的是这套。
3. SBO 本身默认关（`server_args.py:649 enable_single_batch_overlap=False`），且需要 `flashinfer_cutedsl` 或 `deep_gemm`-non-Blackwell 才能走通。
4. DeepEP PR #483 同时改了 `low_latency_dispatch` 产生 `packed_recv_count`——这是原设计没提到的额外 scope。

**执行前 must-hold conditions**：
1. 把 PR 目标 API 从 `src_signals` 改成 `comp_signal`（DeepEP antgroup-opt PR #483 + DeepGemm #14 的对齐协议）。
2. 验证路径用 **Hopper H100/H200**（p5en），不是 Blackwell（p6-b200）。Blackwell 需要另设计 `src_signals` shape。
3. 必须同步实现 `packed_recv_count` 的 dispatch-side 产生逻辑。
4. 和 SGLang 维护者确认：UCCL-EP 的参数命名必须和 DeepEP `comp_signal` 完全一致（duck-typing 依赖）。

**真实可达收益**：-10~15% decode（原 -20% 还是有道理的，但要打折扣因为 SBO 只在 MoE backend 是 flashinfer-cutedsl 或 deep_gemm 时才开；我们 Stage 5 用的默认 MoE runner 可能不在内）。

**关键文件**：
- `/home/ec2-user/workspace/sglang/python/sglang/srt/layers/moe/token_dispatcher/deepep.py:704-732`（两个分支，对照 Hopper vs Blackwell）
- `/home/ec2-user/workspace/sglang/python/sglang/srt/batch_overlap/single_batch_overlap.py:28-144`（gates + CombineOverlapArgs）
- `/home/ec2-user/workspace/uccl/ep/src/uccl_ep.cc:1287, 2132`（UCCL binding patch point）
- DeepEP PR #483 merge commit `9f2fc4b3` on branch `antgroup-opt`（参考实现）

---

### P1：dispatch per-expert early release — NO-GO

**原设计**：dispatch 完成后返回 per-expert ready signal，下游 MoE layer 逐 expert busy-wait → GEMM。声称 P99 ITL -30-40%。

**核实发现**（三个致命伤）：
1. **消费端根本不是 per-expert launch**：
   - `flashinfer_cutedsl_moe.py:137, 163`：`grouped_gemm_nt_masked(..., masked_m)` 一次 kernel 处理所有 experts
   - `moe_runner/deep_gemm.py:267, 345`：`grouped_gemm_nt_f8f8bf16_masked(..., masked_m, expected_m)` 同样一次性
   - `ep_moe/layer.py:312-326`：`forward_flashinfer_cutedsl` **没有 `for expert_id in range` 循环**
   - 老的 `forward_deepgemm_masked` 已 deprecated（`layer.py:248 assert False`）
2. **SGLang 零 consumer 接口**：grep `per_expert_signal|dispatch_ready|expert_ready` → 0 结果。现有的 `dst_signals` 是 combine → downstream 方向，**不能反向复用**。
3. **DeepEP 上游无此概念**：gh API search `per_expert_signal` → 0 matches。我们会在上游方向之外单独造协议。

**真实可达收益**：≤5%（straggler 尾巴差量）——原声称的 -30-40% 在 "一次 grouped kernel" 现实下不可能。

**建议**：移出 roadmap，或降级为"待 flashinfer/DeepGemm 上游支持 per-expert sub-launch 后再评估"。

**关键文件**：
- `/home/ec2-user/workspace/sglang/python/sglang/srt/layers/moe/flashinfer_cutedsl_moe.py:137,163`
- `/home/ec2-user/workspace/sglang/python/sglang/srt/layers/moe/moe_runner/deep_gemm.py:267,345`
- `/home/ec2-user/workspace/sglang/python/sglang/srt/layers/moe/ep_moe/layer.py:244,248,312-326`

---

### P2：single-token fast path — NO-GO

**原设计**：num_tokens ≤ 8 时走专用 kernel，单 warp 直写 WQE 跳过 ring buffer + per-expert counter。声称 dispatch -45%。

**核实发现**：
1. **"GPU 单 warp 直写 WQE" 在 EFA 上硬件不可行**：
   - UCCL-EP EFA 强制走 CPU proxy：GPU 只能往 `D2HHandle` FIFO 写 `TransferCmd` 结构（`uccl_ibgda.cuh:27-94`），根本没有 WQE 概念
   - EFA 驱动不暴露 doorbell/WQE 给 GPU map（不像 Mellanox IB DV-WQE + GDRCopy）——这是 EFA 内核驱动硬约束，UCCL 绕不过
   - 对比：内节点有真 `nvshmemi_ibgda_*` GPU-initiated 路径，EFA 不在这个能力集里
2. **退化版（只优化 kernel 端）收益很小**：450 µs 里可影响的是 GPU kernel launch + FP8 cast + FIFO push 15-25 µs 这段。FP8 cast 不可省（hidden=7168 全量）。atomic+barrier 空转省 5-10 µs，**占总 450 µs 的 1-3%**。
3. **真正的大头是 `kMaxInflightLowLatency` 流控等待 + per-expert finish counter barrier sync（约 250-300 µs）**——fast path 碰不到。
4. SGLang decode path 上 `masked_m` 上限 256，**不是 1-8**，fast path 不覆盖主流 batch。

**真实可达收益**：1-3%（激进退化版 5-8%）。6 人天投资不值。

**建议**：如果非要动 kernel micro-opt，做编译期 `PER_EXPERT_BATCHING` small-batch 分支即可，<1 人天。

**关键文件**：
- `/home/ec2-user/workspace/uccl/ep/include/uccl_ibgda.cuh:27-94`（CPU proxy FIFO 路径）
- `/home/ec2-user/workspace/uccl/ep/src/rdma.cpp:884-964`（EFA SRD QP 走 `ibv_post_send`）
- `/home/ec2-user/workspace/uccl/ep/src/internode_ll.cu:50-449`（dispatch kernel，无 batch=1 fast path）

---

### P3：LL TBO 启用 — NO-GO（定位错）

**原设计**：解除 SGLang `two_batch_overlap.py:405-412` 对 LL 模式的禁用，让 UCCL-EP Buffer 支持 dual-instance。声称 throughput +30-50%。

**核实发现**：
1. **SGLang gate 的真实范围**：`two_batch_overlap.py:405-412` 只禁 **EXTEND + LL + a2a_moe**（prefill + LL）。**decode + LL 本来就启用**（`compute_split_seq_index:87` 明确 `is_decode()` 也走 split）。原设计"decode 需要 TBO 解锁"的前提**不成立**。
2. **gate 原因不是 Buffer 冲突**：`two_batch_overlap.py:77` 有 TODO 注释 "may smartly disable TBO when batch size is too small b/c it will slow down"——更像是**性能考虑 / WGMMA block_m=64 对小 batch 退化**，不是架构冲突。
3. **DeepEP 官方已判 TBO 死刑对 decode**：DeepEP PR #390 原文 "The optimization effect of Two-Batch Overlap (TBO) is **suboptimal for the Decode phase on low-compute-power cards** ... positive throughput gain only at batch size 64/128"。DeepEP 团队自己开发 SBO 替代。
4. **工作量被严重低估**：`uccl_ep.cc` Buffer 私有字段 35 个（line 1583-1636），含 IPC handles、proxy 线程、atomic buffer、D2H queue、moe counters。**LL 本来就有 double-buffering**（`low_latency_buffer_idx` XOR-toggle, line 1225）。真要"双实例"得跨仓库（UCCL + DeepEP shim + SGLang）同步，**实际 25-30 人天**，不是 15。
5. **+30-50% throughput 数字不成立**：SBO 实测 H20 decode +6-7%；EFA wire latency 比 IB 高 5×，overlap 收益比例**缩小**；"+30-50%" 来自 IB + prefill 大 batch 场景。

**真实可达收益**：0（decode 已启用，不需要做）。

**建议**：移出 roadmap。把精力转到 **SBO 集成**（DeepEP PR #390 + SGLang #9660 路径），它才是"降低 decode 延迟"的正道。P0 (combine_signal) 是 SBO 的前置依赖。

**关键文件**：
- `/home/ec2-user/workspace/sglang/python/sglang/srt/batch_overlap/two_batch_overlap.py:77,87,405-412`
- `/home/ec2-user/workspace/uccl/ep/src/uccl_ep.cc:315,1225,1583-1636`

---

### P4：Ctrl/Data QP 分离 + Inline Send — NO-GO（前提破）

**原设计**：atomic count 4B 走独立 QP 开 inline，token data 7KB QP 大量 unsignaled。声称 count -500 ns/count、CQE -85%、解锁 4-bit→6-bit seq。

**核实发现**（三个 killer facts）：
1. **EFA SRD 不支持 inline**：
   - `rdma.cpp:899` `create_srd_qp_ex()` 显式 `qp_attr_ex.cap.max_inline_data = 0`
   - 不是代码风格选择：EFA SRD 通过 `efadv_create_qp_ex + EFADV_QP_DRIVER_TYPE_SRD` 创建，**驱动从来不暴露 non-zero max_inline_data**
   - 设计"把 inline 开成 64"NIC/驱动会强制 cap 为 0
2. **EFA SRD 强制每 WQE signaled**：
   - `rdma.cpp:903` `sq_sig_all = 1`
   - 所有 WR 调用点显式 `IBV_SEND_SIGNALED`（1437/1586/1866/2019/2033/2722/2883/2948/3032/3078/3231/3390）
   - EFA provider **只对 signaled WR 产生完成**——"unsignaled burst CQE -85%" 不是可暴露的 knob
3. **count 本来就是 WRITE_WITH_IMM，没有 DMA fetch 可省**：
   - `rdma.cpp:1459-1482, 2879-2886` count 通过 RDMA WRITE_WITH_IMM 发送，值和 offset 打进 32-bit imm
   - `ibv_wr_set_sge(..., 0)` payload 长度 0
   - **没有任何 DMA fetch**，"500 ns 收益" 物理上不存在

**真实可达收益**：0。

**建议**：彻底删除 P4。如果设计想走 inline，目标必须是 MLX5/IB，不是 EFA。EFA 上唯一诚实的变体是"把 count 打进 data WR 的 tail"——**代码已经这么做**（rdma.cpp:1483-1492）。

**关键文件**：
- `/home/ec2-user/workspace/uccl/ep/src/rdma.cpp:885-1005,1437,1459-1482,2879-2886`
- `/home/ec2-user/workspace/uccl/ep/include/common.hpp:68-69`

---

### P5：prefill/decode 分 QP 配置 — WEAK-GO

**原设计**：`UCCL_EP_MODE=decode` env 切换 `kChannelPerProxy` / `kNumProxyThs` 小配置 + inline。声称 decode proxy poll CPU -60%、每 poll cycle -2-3 µs。4 人天。

**核实发现**：
1. **`kChannelPerProxy=8` / `kNumProxyThs=4` 是编译期 `#define`**（`common.hpp:68-69`），被用作**数组尺寸**：
   - `rdma.hpp:43` `data_qp_num[kChannelPerProxy]`
   - `uccl_ibgda.cuh:334,382` `slots[kNumProxyThs]`
   - `proxy.hpp:32` `listen_ports[kNumProxyThs]`
   - CUDA kernel `EP_DEVICE_ASSERT`（:39,196,331）
   - 改运行时化：需要重写 6+ 个结构体、改 CUDA kernel 断言、重验 `kRemoteBufferSize` 依赖——**8-10 人天**，不是 4
2. **"proxy CPU -60%" 不转化为 GPU 延迟降低**：
   - proxy 线程被 pin 到专用核（`proxy.cpp:106`）
   - 省下的 CPU **没被 GPU 等着**——是纯空闲
   - 反而**更少 proxy 线程 = bursty decode 下尾延迟更高**（一个堵住的线程占更大 channel 份额）
   - 当前 8×4=32 channels 的已 warm 核做的 poll 是 ns 量级
3. P5 inline 部分继承 P4 的 EFA 约束 → 零收益
4. **没有现成 CPU 竞争证据**：原设计没给出 decode 模式下 proxy 线程 CPU 饱和数据

**真实可达收益**：未知，可能为 0 或负。

**建议**：**不要先做 P5**。先花 1 天 instrument `proxy.cpp` 的 poll cycle 时长和 queue 深度，在 active decode 下采样。如果 CPU-contention 真实存在再做；否则跳过。

**关键文件**：
- `/home/ec2-user/workspace/uccl/ep/include/common.hpp:68-69`
- `/home/ec2-user/workspace/uccl/ep/include/rdma.hpp:43`
- `/home/ec2-user/workspace/uccl/ep/include/proxy.hpp:32`
- `/home/ec2-user/workspace/uccl/ep/include/uccl_ibgda.cuh:334,382`
- `/home/ec2-user/workspace/uccl/ep/src/proxy.cpp:106,620`

---

## 下一步的正道

**基于复核结果，真正值得投的只有一条半路径**：

1. **P0 重设计 → `comp_signal` API**（半条：必须重新设计）
   - 对标 DeepEP antgroup-opt PR #483，不是原文档说的 Blackwell `src_signals`
   - 同时实现 `packed_recv_count` 的 dispatch 端产出
   - 先在 Hopper (p5en) 验证，Blackwell 暂不做
   - 预估：**真实工作量 12-15 人天**（非原 8），收益 -10~15% decode（非原 -20%）

2. **SBO 集成链路**（完整一条）
   - DeepEP PR #390 SBO + SGLang PR #9660 + DeepGemm #14 是 SGLang decode 降延迟的**上游官方路线**
   - UCCL-EP 要做的是"duck-type `comp_signal` API"让自己能被 SGLang SBO 路径当成 DeepEP 使用
   - 这条路线和 P0 重设计是**同一件事**——P0 就是它的 UCCL 侧实现

**不做**：P1、P2、P3、P4。
**不先做**：P5（先 instrument 再决定）。

**已识别的其他可行方向**（见 `docs/NEXT_OPTIMIZATION_CANDIDATES.md`）：
- P1-a：#901 `previous_event=None` 硬编码（修 SGLang 推理启动报错，2 天）
- P1-b：#895 `ibv_fork_init`（修训练 DataLoader fork SIGSEGV，1.5 天）
- P1-c：#893 GPU timeout follow-up（PR #904 续篇，2.5 天）

---

## 方法论反思

这次复核暴露了原设计文档的系统性问题：

1. **API 名称靠记忆，不靠查仓库** — `src_signals` vs `comp_signal` 是同一个功能的两个分支，原设计选错了
2. **"下游能消费"被假设而非验证** — P1 假设 DeepGemm per-expert launch 其实是 grouped
3. **硬件约束被忽略** — P2/P4 都撞上 EFA SRD 驱动约束
4. **Gate 被误读** — P3 把"extend+LL 被禁"误当成"LL 全部被禁"
5. **收益数字来自别人的场景** — +30-50% 来自 IB+prefill+大 batch，直接搬到 EFA+decode+小 batch 不成立

**规则**（往后适用）：任何延迟 / 吞吐数字必须标清"场景三元组"（backend + phase + batch size），否则不可复用。
