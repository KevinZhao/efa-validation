# SBO / `comp_signal` UCCL-EP 三个 Sprint 优化方案

> 🔧 **PARTIALLY REVISED (2026-04-26)** — 整体方案和工期仍有效，但实施细节已被 `docs/SBO_SPRINT_A_IMPLEMENTATION.md` 订正：
> - **§A.3 `packed_recv_src_info` int32→int64 升级**：**不是必需**——Sprint A 的 SM-stripe 按 `(local_expert, block_in_expert)` 键保留外 `for (dst_rank)` 循环即可。int64 升级延到 Sprint B 再考虑。Sprint A 从此是 non-breaking ABI change。
> - **§A.5 workspace 算术错误**：正确形式是 `atomic_clean_flag[1] + grid_sync_barrier[1] + finish_counter_per_expert[num_local_experts]`
> - **§B Memory ordering 决策**：Sprint A 用 `.gpu`+`.gpu`（producer/consumer 同 device 同 process），DeepGemm `release.sys` patch 延到 Sprint B
> - **§A finish flag race 精确位置**：整个 `internode_ll.cu:1037-1078` finish block（不只 :1069）
>
> **实施时请以 `docs/SBO_SPRINT_A_IMPLEMENTATION.md` 为准**。本文件提供整体 Sprint 工期和原理概念，实施细节已被订正。
>
> **预期收益**：见 `docs/EXPECTED_PERFORMANCE_GAINS.md`（Sprint A -5~-8%，Sprint B 再 -3~-5%，Sprint C Blackwell 兼容）。

**日期**：2026-04-25
**上下文**：基于 `docs/SBO_COMP_SIGNAL_DEEP_DIVE.md` 的 4 agent 调研结论，把 P0 实施分成 3 个 Sprint
**目标**：把 SGLang decode 的 `down_gemm ↔ combine_send` 串行重叠成流水，降低 decode P50/P99 ITL
**兼容性基线**：必须 duck-type DeepEP `low_latency_combine` 新 API 签名，让 SGLang 不改代码即可切 UCCL-EP

---

## 0. 共同背景：Combine 为什么值得 overlap

SGLang decode 一步里，combine 阶段原本是 `down_gemm 完成 → barrier → combine 发送 → 等对端 recv + reduce` 的严格串行链，总计 ~600 µs（p5en EP32 实测）。其中：
- `down_gemm` ≈ 280 µs
- `combine send` ≈ 35 µs（本机 + wire）
- 对端 recv + GPU reduce ≈ 280 µs

**关键事实**：`down_gemm` 不是最后一瞬间一起吐出全部 token 的 hidden state，而是**按 block_m (64 或 128) 一个 tile 一个 tile 地写出来**。当 GEMM 算完前 64 token 时，后面还有 N-64 token 在算，但这 64 个已经可以发到网络了。

**SBO 的核心思想**：让 combine 发送咬住 down_gemm 的 tile 产出时序。每产完一个 block_m，combine 立刻把这 64 个 token 打包上 NIC。原来 "GEMM 280 µs + combine 320 µs 串行 = 600 µs" 变成 "GEMM 280 µs 期间 combine 已发出 80%，只剩最后一个 block_m 的尾巴 ~30 µs"。

**实现这个流水需要一个 producer-consumer 信号**：
- Producer = `down_gemm`，每写完一个 block_m 就 `atomic_add(comp_signal[expert, block_idx], 1)`
- Consumer = combine kernel，发送某个 block_m 前先等 `comp_signal >= threshold`

这就是 `comp_signal` 协议的本质。问题在于：**把这个 consumer 放在 GPU 上 spin 是唯一选择吗？** 对于 DeepEP NVIDIA IBGDA 是（GPU 直接敲 doorbell），对于 UCCL-EP EFA **不是**（CPU proxy 反正已经在 hot path 上）。三个 Sprint 分别围绕这个分叉展开。

---

## Sprint A · Scheme A（GPU spin）—— 兼容性底座

### A.1 目标
实现和 DeepEP antgroup-opt PR #483 完全一致的 API 语义，让 SGLang 在 p5en (H200+FP8+DeepGemm) 开启 `--enable-single-batch-overlap` 后可以把 UCCL-EP 当 DeepEP 用。**这是后续 B、C Sprint 的必要前置**。

### A.2 性能原理（为什么能提升）

三件事叠加起来：

**(1) 串行 → 流水**
原来 combine 必须等 `down_gemm` 全部完成才能启动，两者串行 ~600 µs；SBO 下 combine 发送阶段和 `down_gemm` 后半部分并行，**重叠掉 down_gemm 后 70-80% 的时间**。Combine 的 send 阶段 (~35 µs) 几乎被完全吞进 compute 时间里。

**(2) NIC pipeline 预热**
传统模式下 combine 第一个 WR 投递到 EFA NIC 时，NIC 的 SQ/CQ 都是冷的（刚经历 `down_gemm` 的 280 µs 无流量期）；SBO 下从 `down_gemm` 一开始就慢慢喂 WR，NIC 硬件一直处于 warm 状态，最后一个 block_m 的 wire latency 不付 cold-start cost。

**(3) CPU proxy 不被调度器偷走**
UCCL-EP proxy 线程原本在 combine 启动前一直空转 poll FIFO，OS 调度器可能把它降频或进 C-state；SBO 下 FIFO 里一直有新命令进来，proxy 维持 busy-poll 不降频。

### A.3 主要修改位置

**UCCL-EP C++ 侧**：

| 文件 | 改动 | 类型 |
|---|---|---|
| `ep/src/uccl_ep.cc` (`low_latency_combine` 签名, ~line 1287) | 新加 6 个入参：`overlap / packed_recv_count / comp_signal / block_m / threshold / num_sms` | API |
| `ep/src/uccl_ep.cc` (pybind 绑定, ~line 2132) | 暴露新 kwargs，参数命名必须和 DeepEP `antgroup-opt` 分支完全一致 | binding |
| `ep/src/uccl_ep.cc` (dispatch, ~line 1239) | `packed_recv_src_info` 从 int32 升级到 int64，低 32 bit 存 src_idx，高 32 bit 存 src_rank | **ABI-break** |
| `ep/src/internode_ll.cu` (combine kernel, ~line 735-1077) | kernel signature 加上新参数 + `atomic_finish_counter_per_expert` 工作区 | kernel sig |
| `ep/src/internode_ll.cu` (combine send loop, ~line 792-858) | 把原来 "一个 SM 负责一个 expert 的全部发送" 改成 "SM-striped scan of prefix-sum"（见 A.4） | **major** |
| `ep/src/internode_ll.cu` (send 前 ~line 857) | 插入 `while (ld_acquire_global(signal) < threshold) __nanosleep(100);` spin | hot path |
| `ep/src/internode_ll.cu` (finish flag, ~line 1028) | overlap 模式下只由最后一个完成的 block_m 对应 SM 发 finish flag，避免重复发 | fix race |
| `ep/src/layout.cu` | `src_info` stride 翻倍 | layout |
| workspace 分配 | `atomic_clean_flag + 1` → `(1 + num_experts) * sizeof(int)` | workspace |

### A.4 为什么要做 SM-stripe（重要设计决策）

原 UCCL-EP combine kernel 设计是 **"一个 SM 负责一个 expert 的全部发送"**。这在 `num_experts = num_device_sms` 的场景能打满 GPU，但 **SBO 下 `num_sms` 参数是一个小数字（Hopper 默认 3）**——因为 combine 只是 push FIFO 不做重活，剩下 SM 要留给 DeepGemm。

新设计是**一个 SM 负责多个 signal-slot（按 prefix-sum 轮询调度）**：
- 把 all experts 的 signal-slot 拼成一条 `[0, signal_sum)` 的线性序列（prefix-sum）
- SM i 处理所有 `slot_idx % num_sms == i` 的 slot
- 每个 slot 发送前查对应 expert 的 `comp_signal`，够 threshold 就发

这样 `num_sms=3` 也能覆盖 256 experts 的所有 signal-slot 轮询发射。

### A.5 协议陷阱（implementation must-handle）

1. **零 token expert 也要保留 1 个 signal-slot**：`ceil_div(packed_recv_count[e], block_m)` 在 0 token 时等于 0 → prefix-sum underflow。修正：`(count == 0 ? 1 : ceil_div(count, block_m))`
2. **`overlap && async_finish=True` 死锁**：异步完成语义和 overlap 等待不兼容。必须 host assert `overlap → return_recv_hook=True`
3. **finish flag race**：overlap 模式下每个 expert 可能被多个 SM 处理，finish flag 必须由 "该 expert 最后一个完成的 block_m" 对应 SM 统一发送，否则对端 recv 死等。用 `atomic_finish_counter_per_expert` 做 counter，每个 SM 自减，归零的 SM 负责发 finish
4. **`num_sms` 必须 ≥ 1**：`num_sms=0` 会除零；`num_sms` 过大不致命（多余 SM 会 early-exit 浪费 launch 开销）

### A.6 预期收益

对齐 SGLang PR #9660 H20 实测基线（DP16+EP16 decode DeepSeek-V3/R1, input 4096 / output 1536, concurrency 512）：
- mean ITL -7.9%, P99 ITL -8.6%, output tok/s +6.7%

迁移到 p5en (H200) 打保守折扣：**mean ITL -5~8%, P99 -6~10%, tok/s +5~7%**。H200 的 GEMM 本身更快，compute-side 可 overlap 的绝对时间更短。

### A.7 工期与产出

- 工期：**2 周（10 个工作日）**
- 产出：UCCL-EP fork 上的主 PR（对齐 DeepEP API）+ p5en benchmark 报告

---

## Sprint B · Scheme B（CPU-proxy spin）—— EFA 独占 lever

### B.1 目标
在 Sprint A 的基础上加一个隐藏 env `UCCL_EP_COMBINE_SIGNAL_ON_CPU=1`，**把 `comp_signal` 的轮询从 GPU warp 移到 CPU proxy 线程**。在 EFA 上拿到 DeepEP NVIDIA 做不到的额外收益。

### B.2 性能原理（为什么 EFA 能赢 NVIDIA）

**根本优势**：DeepEP NVIDIA 走 GPU-initiated IBGDA，GPU 直接敲 MLX5 doorbell，**整条路径 CPU 完全不参与**——它必须 GPU 上 spin，别无选择。UCCL-EP 走的是 "GPU 写 FIFO → CPU proxy 读 FIFO → CPU post_send" 的 CPU-in-the-loop 路径，**CPU 反正已经在 hot path 上**，多让它查一次 pinned memory 成本几乎为零。

具体有四层收益叠加：

**(1) 3 个 SM 直接释放给 DeepGemm**
Hopper 默认 `num_sms=3`，H200 共 144 SM，Scheme A 下 `compute_num_sms = 141`。Scheme B 下 combine kernel 不需要持续占 SM 做 spin，只需要 push FIFO 就退出——`num_sms` 可以压到 1（OPT-2），DeepGemm 多拿到 2 SM；或再进一步 push 完全用 ring buffer 不需要 kernel，GEMM 拿全部 144 SM。
- 估算：DeepGemm tile 吞吐约线性 scale with SM 数量，多 2-3 SM ≈ **+1.5-2% GEMM 吞吐**

**(2) 解锁同 CTA 内的 group-mate**
Combine kernel 的 occupancy 已被 smem (202KB/228KB) 压到 50%——一个 CTA 独占一个 SM 的 32 warps 全部。Scheme A 下一个 warp 在 `__nanosleep` spin 的时候，**同 CTA 里其他 warp 想过 `sync_barrier` 都得一起等**。Scheme B 下整条 CTA 不存在 spin warp，这个隐性 tax 消失。
- 估算：ITL tail 由此降低 **~1-2%**（具体多少取决于 down_gemm tile 产出时序方差）

**(3) Spin 颗粒度从 µs 降到 ns**
- GPU 上 `__nanosleep(100)` sm_90a 实测约等价于 100 cycle busy-wait（不是真 sleep）；唤醒颗粒度 **µs 级**
- CPU 上 pinned memory `__sync_load` 直接查 L1 cache（Hopper coherent）；颗粒度 **~80 ns**
- 意味着 combine 更贴着 down_gemm 的 tile 产出时序发——overlap 利用率更高

**(4) 和 proxy 批处理叠加（OPT-3 reorder 的基础）**
`proxy::post_gpu_commands_mixed` 本来就有 batch window。Scheme B 下可以在同一窗口内**优先选已 signal ready 的 cmd 先 post**，把慢 expert 的等待挤到后面——跨 expert 全局重排。DeepEP GPU-per-warp send 完全做不了这个。
- 估算：per-expert 尾差约 5-15% 情况下，reorder 可 **进一步降低 P99 3-5%**

### B.3 主要修改位置

**GPU 侧**：
| 文件 | 改动 |
|---|---|
| `ep/include/ring_buffer.cuh` (`TransferCmd` 结构, ~line 57-90) | 加 signal-wait 描述符字段（signal pointer + threshold + block_m 索引）。TransferCmd 64B 本身就有空位，或借用 `atomic_offset` 的 16-bit 空闲位 |
| `ep/src/internode_ll.cu` (combine kernel) | 删除 spin 循环；改为 "填好 TransferCmd 的 signal-wait 字段就 commit FIFO"，kernel 本身 launch-to-exit 时间降到 ~5 µs |

**CPU 侧（proxy）**：
| 文件 | 改动 |
|---|---|
| `ep/src/proxy.cpp` (`run_sender`, ~line 464-543 + 655-749) | 在 `post_gpu_commands_mixed` 之前先扫 pending cmd 的 signal-wait 字段，检查 `comp_signal` 是否达 threshold。未达标 → 进延迟队列；已达标 → 立刻 post |
| `ep/src/uccl_proxy.cpp` (~line 59-87) | `comp_signal` 张量通过 `cudaHostAlloc(cudaHostAllocMapped)` 分配（模板：已有的 `atomic_buffer_ptr_`），或对 SGLang 传入的 device pointer 做 `cudaHostRegister` 映射 |

**DeepGemm 侧（可选但推荐）**：
- 原子 scope 从 `atom.add.release.gpu.global.s32` 改成 `atom.add.release.sys.global.s32`——**一个字符的 PTX 改动**
- 正确性要求：`release.gpu` 只保证 GPU 内可见，CPU 读 pinned memory 在 PTX semantics 上不保证看到最新值（实测 Hopper cache coherent 能看到，但不 portable）
- 建议顺手提一个 DeepGemm PR，同时建立和 DeepGemm 团队联系

### B.4 关键实现决策

**Signal 用 pinned page 还是 device memory？**
选 pinned page（`cudaHostAlloc(cudaHostAllocMapped)`）。GPU 写入通过 PCIe POST 直达主存，CPU 读命中 L1，延迟对称 ~80 ns。如果用 device memory + proxy 拉 DMA，CPU 要通过 PCIe read ~1 µs，比 GPU spin 还慢，不可行。

**GPU 写 signal 会 PCIe 瓶颈吗？**
不会。signal 4 B/次，DeepSeek-V3 decode 每层 ≈ 32 experts × ceil(128/64) = 64 次 × 4B = 256 B/layer。相比 PCIe Gen5 128 GB/s 完全微不足道。

**Proxy 延迟队列会不会让小 batch 更慢？**
有风险。如果 `down_gemm` 对某个 expert 慢到 signal 迟迟不达标，proxy 持续 re-poll 不能 post，其他 expert 的 combine 也被窗口阻塞。
- 缓解策略：设置软 deadline（建议 20-50 µs）超过就强制 post——GPU kernel 必然会 finish，最差退化成 "post 时 DeepGemm 其实也完成了" 的 Scheme A 等效

### B.5 协议陷阱

1. **PTX scope 问题**：如果不推 DeepGemm 改 `release.sys`，实测 Hopper 上 Scheme B 可能工作但依赖微架构 coherent guarantee（不稳）。稳妥路径：同时提 DeepGemm PR。
2. **CUDA Graph 外不可用**：`cudaHostAlloc` 映射要和 SGLang 的 CUDA Graph capture 流程兼容。非 graph 路径（prefill / 非 capture decode）需要 fallback
3. **Spot preemption 场景 watchdog**：Scheme B 下 proxy 如果在等一个 signal 时 GPU 被抢走，proxy 会死等。必须加 CPU proxy 侧的 watchdog timeout（可复用 PR #904 的 `UCCL_EP_CPU_TIMEOUT_SECS` 机制）

### B.6 预期收益

在 Scheme A 基础上**再 +3-5% decode ITL**：
- 释放 SM 贡献：+1.5-2%
- CTA 解锁贡献：+1-2%
- Spin 颗粒度降低：+~1%
- OPT-3 reorder（可选追加）：P99 -3-5%

### B.7 工期与产出

- 工期：**1.5 周（7-8 个工作日）**
- 产出：`UCCL_EP_COMBINE_SIGNAL_ON_CPU=1` 隐藏 env + DeepGemm `release.sys` 配套 PR + p5en 量化 benchmark（GPU spin vs CPU spin delta）

---

## Sprint C · Blackwell `src_signals`—— 兼容性硬要求

### C.1 目标
支持 Blackwell (p6-b200, SM100) 上 SGLang 走 FlashInfer CuteDSL 的第二个 signal 协议。**这不是性能选择题，是 Blackwell 兼容性硬要求**。

### C.2 为什么必须做

SGLang 的硬件分叉是**硬 gate**（`is_blackwell()` 判断）：
- p5en 永远走 `comp_signal` 分支（Hopper + DeepGemm）
- p6-b200 永远走 `src_signals` 分支（Blackwell + FlashInfer CuteDSL）

如果 UCCL-EP 只支持 Hopper 协议，那 Stage 5 切到 p6-b200 时 SBO 整个关闭，Sprint A/B 所有收益归零。Blackwell 是 Stage 5 后期的主力机型（p6-b200/b300 SPS 稳定后）。

### C.3 两个协议的差异

| 维度 | Hopper `comp_signal`（Sprint A/B） | Blackwell `src_signals`（Sprint C） |
|---|---|---|
| Producer | DeepGemm SM90 kernel | FlashInfer CuteDSL SM100 kernel |
| Shape | `[num_local_experts × ceil(M/block_m)]` | `[num_local_experts]` |
| Dtype | int32 | uint32 |
| Granularity | 每 block_m × expert 一个信号 | **每 expert 一个信号（整个 expert 完成才发）** |
| Threshold | 运行时返回 `ceil(N, block_n)` | 固定 1 |
| 消费点参数 | 5 个 kwargs | 2 个 kwargs (`src_signals`, `src_signal_expect_value`) |

### C.4 性能特性（相比 Hopper）

**理论收益更小**：
- 粒度粗：expert 级 vs block_m 级，combine 的等待窗口更长（必须等整个 expert GEMM 完成才能发它的 token）
- SGLang 默认 Blackwell `num_sms=32`（vs Hopper 3）——combine 占 SM 更多，让出 GEMM 的比例小

**但绝对收益不一定小**：
- B200 FP4 ~20 PFLOPS，GEMM 本身更快 → combine 时间占比反而更大 → overlap 的绝对 µs 节省接近 Hopper
- 具体数字要 p6-b200 实测

### C.5 主要修改位置

相对 Sprint A 的增量：

| 文件 | 改动 |
|---|---|
| `ep/src/uccl_ep.cc` (`low_latency_combine` 签名) | 再加 2 个可选 kwargs：`src_signals` + `src_signal_expect_value` |
| `ep/src/uccl_ep.cc` (kernel dispatch) | 根据 `comp_signal` vs `src_signals` 哪个非空选择 kernel variant（exactly one 必须非空） |
| `ep/src/internode_ll.cu` | 新增第二个 combine kernel 实现（模板化分离编译），简化逻辑：没有 block_m 子粒度，prefix-sum 直接按 expert，每个 SM 发完一个 expert 的全部 token 再去下一个 |
| pybind | 两组 kwargs 都暴露 |

**Scheme B 能否复用？**
能。CPU-proxy signal wait 的逻辑在 Blackwell 上同样适用——`src_signals[expert]` 的 pinned mapping + proxy spin 和 Hopper 机制一致。所以 Sprint B 的 env + proxy 基础设施可直接复用，Sprint C 只需要加一个"按 expert 粒度 spin" 的 proxy 分支。

### C.6 为什么放在 Sprint C（而不是 A 同期）

1. **p6-b200 Spot 不稳**（已有 memory 记录），Stage 5 当前聚焦 p5en，先把 Hopper 跑通再展开
2. **FlashInfer CuteDSL 上游演进快**，等 Hopper 路径稳定后再做 Blackwell 可避免跟着上游变更反复返工
3. **降低一次踩坑半径**：Scheme A/B 的 SM-stripe + CPU-spin 基础设施在 Hopper 验证后再 port 到 Blackwell，只需要增量改协议层

### C.7 工期与产出

- 工期：**1.5 周（7-8 个工作日）**
- 产出：p6-b200 上 SGLang + UCCL-EP + SBO 可用；Blackwell p6-b200 benchmark 报告

---

## Sprint 间依赖关系

```
Sprint A (2w) ────┬──→ Sprint B (1.5w)     ← EFA 独占增量
                  │
                  └──→ Sprint C (1.5w)     ← Blackwell 兼容
```

**Sprint A 是所有后续的 prereq**：
- API 规范（新 kwargs 列表 + ABI int64 升级）
- SM-stripe 基础设施（combine kernel 重写）
- 测试框架（bit-exact vs DeepEP 验证）

B 和 C 本质上都是 "A 加一条 runtime 分支"：
- B 加的是"signal consumer 位置"分支（GPU spin / CPU spin），**同一份代码多一条路径**
- C 加的是"signal 协议"分支（block_m / expert 粒度），**增加第二个 kernel variant**

所以 A 做成熟后，B 的边际成本 ~1.5 周（复用 SM-stripe），C 的边际成本 ~1.5 周（复用 pybind、smem 布局、CPU proxy 基础设施）。

---

## 总工期与里程碑

| Sprint | 工期 | 关键交付 | 预期累计收益（p5en） |
|---|---|---|---|
| **A** | 2w | Scheme A 主 PR + 对齐 DeepEP API | mean ITL -5~8%, P99 -6~10% |
| **B** | 1.5w | CPU-spin env + DeepGemm release.sys PR | **再 +3-5%** decode ITL |
| **C** | 1.5w | Blackwell 第二协议 variant | Blackwell 兼容（p5en 不影响）|

**总计：5 周**（不含等 PR review 时间）。

---

## 一句话总结每个 Sprint

- **Sprint A**：UCCL-EP combine kernel 实现 GPU-spin 版 `comp_signal`，把 combine send 和 down_gemm 咬合成流水，重叠掉 70-80% combine 时间——**SBO 的兼容性底座**
- **Sprint B**：利用 EFA 架构 CPU proxy 本来就在 hot path 的独特优势，**把 signal 检测从 GPU 搬到 CPU**，释放 SM 给 DeepGemm + 解除同 CTA 阻塞——**DeepEP NVIDIA 做不了的 EFA 独占 lever**
- **Sprint C**：为 Blackwell (p6-b200) 加第二个协议 variant，让 Stage 5 后期切到 p6-b200 时 SBO 依然可用——**Blackwell 兼容性硬要求**

---

## 相关文档

- `docs/SBO_COMP_SIGNAL_DEEP_DIVE.md`——协议规范、EFA 独占优化 lever 全集、ROI 排序
- `docs/SGLANG_OPT_FEASIBILITY_REVIEW.md`——5 agent 复核 P0-P5，只 P0 可走的依据
- `docs/NEXT_OPTIMIZATION_CANDIDATES.md`——和 SBO 正交的 UCCL-EP 贡献候选（#901/#895/#893）
- `docs/UCCL_CONTRIBUTION_GUIDE.md`——PR 提交流程、维护者结构、CI 要求
- 上游参考：DeepGemm PR #183、DeepEP PR #390 / #483（antgroup-opt 分支）、SGLang PR #9660（已 merged）、SGLang PR #17289（Blackwell 分支）
