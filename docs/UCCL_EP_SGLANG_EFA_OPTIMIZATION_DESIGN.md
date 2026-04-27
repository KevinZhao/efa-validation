# UCCL-EP on AWS EFA：SGLang 推理延迟优化设计文档

> ⚠️ **STALE / SUPERSEDED (2026-04-26)**
> 本文档是最早的 P0-P5 roadmap，其中 **P0-P5 有 4 个已被 `docs/SGLANG_OPT_FEASIBILITY_REVIEW.md` 驳回**，另外 1 个被订正：
> - P0 (combine signal API) — **重设计**，API 名字 `src_signals` 错，应为 `comp_signal`；真实收益 -5~-8% 而非 -20%
> - P1 (dispatch per-expert early release) — **驳回**（DeepGemm/CuteDSL 是 grouped GEMM，消费端不存在）
> - P2 (single-token fast path) — **驳回**（EFA 驱动不暴露 doorbell/WQE 给 GPU）
> - P3 (LL TBO) — **驳回**（decode+LL 本来就启用；DeepEP 官方改走 SBO）
> - P4 (Ctrl/Data QP 分离 inline) — **驳回**（EFA SRD max_inline=0 驱动级硬约束；sq_sig_all=1）
> - P5 (prefill/decode 分 QP) — **WEAK**（编译期 define，改成 env 8-10 天非 4 天）
>
> **§1.2 "decode 单 token 预算 EP dispatch 450 µs / combine 600 µs / 总 1500 µs"** 是 p5 BF16 test_internode 非-LL 数字。**p5en LL post-PR #745 实际 dispatch both 174.9 µs, combine both 326.7 µs**，整体 ~500 µs/layer（详见 `docs/ALLTOALL_DEEP_DIVE.md` 基线纠正）。
>
> **最新 roadmap**：`docs/FINAL_EXECUTION_CHECKLIST.md`
> **最新预期**：`docs/EXPECTED_PERFORMANCE_GAINS.md`
> 本文件保留作历史参考。

**日期**：2026-04-25
**目标场景**：SGLang + UCCL-EP + AWS EFA（p5en/p6）推理 decode 延迟优化
**基于版本**：
- UCCL HEAD `f1ecbaf7`（`Fix/bdf connect API and bug fixes (#899)`）
- SGLang main (2026-04-25 shallow clone)
- DeepEP 原生 API 作为参考接口

---

## 1. 背景与目标

### 1.1 核心目标
降低 SGLang 使用 UCCL-EP 在 AWS EFA 上做 MoE 推理（DeepSeek-V3 / Qwen3-235B 级别）时的 **decode 延迟**，重点是 **P99 ITL**。

### 1.2 延迟剖析（p5en EP32, batch=1-8 baseline）

| 阶段 | Decode 单 token 预算 | Prefill 每 4K token 预算 |
|---|---|---|
| Attention | ~150 µs | ~8 ms |
| **EP dispatch** | **~450 µs** | **~2 ms** |
| GroupedGEMM (MoE expert) | ~200 µs | ~6 ms |
| **EP combine** | **~600 µs** | **~5 ms** |
| 其他 (norm/residual) | ~50 µs | ~500 µs |
| **总计** | **~1.5 ms** | **~21 ms** |

**EP 通信占 decode 70%、prefill 33%**。推理 decode 完全是 communication-bound。

### 1.3 单次 combine 600 µs 的展开

```
[GPU kernel 启动]─[GPU 写 FIFO]─[CPU proxy poll]─[ibv_wr_*]─[NIC DMA out]─[wire]─[NIC DMA in]─[CQE]─[CPU 处理]─[GPU 写 atomic]─[GPU kernel recv]
    10 µs         1 µs          5 µs            3 µs        10 µs       50 µs   10 µs       3 µs    5 µs         5 µs             20 µs
```

**核心洞察**：
- wire 时间 50 µs 是物理下限（光速 + PCIe + NIC 处理 ~80-100 µs）
- 总 600 µs = 12× wire time，**软件开销占 92%**
- 推理延迟优化是 **"软件开销清零"** 游戏，**不是带宽优化** 游戏

---

## 2. SGLang 现有架构的关键发现

### 2.1 SGLang 的 LL dispatch/combine 架构

**文件**：`sglang/python/sglang/srt/layers/moe/token_dispatcher/deepep.py`

**关键类和方法**：
- `_DeepEPDispatcherImplLowLatency`（545-746 行）
  - `dispatch_a` (557): 启动 dispatch，返回 (hidden_states, ..., event, hook)
  - `dispatch_b` (583): `hook() or event.current_stream_wait()` — **当前是整体同步点**
  - `combine_a` (664): 启动 combine
  - `combine_b` (677): `hook() or event.current_stream_wait()`

### 2.2 SGLang 已设计好 combine-GEMM overlap（但 UCCL-EP 未实现）

**文件**：`sglang/python/sglang/srt/batch_overlap/single_batch_overlap.py`

`CombineOverlapArgs` (62 行) 包含：
- `signal: Optional[torch.Tensor]` — per-expert 信号张量
- `threshold: int` — 等待阈值
- `num_sms: int` — 分配给 combine 的 SM 数量

调用处（`deepep.py:724`）：
```python
combined_hidden_states, event, hook = buffer.low_latency_combine(
    ...,
    overlap=overlap_args.overlap,
    src_signals=overlap_args.signal,
    src_signal_expect_value=overlap_args.threshold,
    ...
)
```

**Blackwell**: 用 uint32 per-expert signal；**H100/H200**: 用 int32 array `[num_local_experts × num_blocks]`

### 2.3 UCCL-EP 当前未实现的 DeepEP 原生 API

**文件**：`uccl/ep/src/uccl_ep.cc:1287-1373`

UCCL-EP `low_latency_combine` 签名**缺少**：
- `src_signals`
- `src_signal_expect_value`
- `overlap`
- `num_sms`（用于 overlap SM 分割）

**后果**：SGLang 在 UCCL-EP 下，`SBO_enable_combine_down_gemm_two_stream_overlap` 永远走不通。当前测得的 baseline 性能**没有任何 overlap**。

### 2.4 LL TBO 被主动禁用

**文件**：`sglang/python/sglang/srt/batch_overlap/two_batch_overlap.py:405-412`

```python
local_can_run_tbo = (self.local_tbo_split_seq_index is not None) and not (
    (local_batch.forward_mode.is_extend() and not local_batch.forward_mode.is_target_verify())
    and enable_a2a_moe
    and (resolved_deepep_mode.is_low_latency())  # ← LL 模式下 TBO 被关
)
```

**原因**：LL 模式下两个 batch 共享同一个 `Buffer`，会发生 handle/low_latency_buffer_idx 冲突。

### 2.5 LL 不支持 CUDA Graph（共同限制）

Ziming 在 issue #734 确认：UCCL-EP 和 DeepEP 的 LL 模式**都不支持 CUDA Graph**。10-20 µs × N experts × M layers 的 launch overhead 成为推理延迟的隐性杀手。

---

## 3. 已识别的优化方向汇总

### 3.1 已有 PR 级修补（战术性）

| PR | 状态 | 收益 | 核心改动 |
|---|---|---|---|
| **#903** | OPEN | +3% TFLOP/s, **13h 稳定** | `__threadfence` + `__nanosleep` + `rdma_recv 128→512` |
| **#522** | OPEN | EP=16 dispatch +8-15% | Connectionless mode: `dst_ah_per_nic[]` + `dst_qpn_per_nic[]` |
| **#485** | DRAFT | LL 单 QP → multi-QP | 把 `data_qps_by_channel[]` 从 normal 扩到 LL |
| **#486** | DRAFT | `kMaxInflight 8→16` + `FastCombineTokenCounter` | 扩 inflight + 数组查表替代 map |
| **#601** | DRAFT | cross-rail 15 → 43 GB/s | Rail-aligned 两跳路由 |
| **#728** | DRAFT | WR 505 → 142 (-72%) | Rank-batch coalescing |
| **#534/#542** | DRAFT | — | LL kernel chunk / full_expert_count 预统计 |
| **#766** | MERGED | — | off13 overflow + PER_EXPERT_BATCHING stride fix |

### 3.2 架构级改造方向

| 方向 | 颠覆性 | 工作量 | 推理场景收益 |
|---|---|---|---|
| [1] Receiver-driven FC | 🔴 极高 | 20 p.d. | 大 batch prefill 才有效 |
| [2] GPU-resident Proxy | 🟠 高 | 10-30 p.d. | per-token proxy -2 µs |
| [3] Ctrl/Data QP 分离 | 🟢 低 | 5 p.d. | count msg -500 ns |
| [4] Per-sender slab | 🟢 低 | 5 p.d. | receive latency -20-30% |
| [5] Persistent kernel | 🟠 高 | 15 p.d. | 解决 CUDA Graph 限制 |
| **[6] Async early-release** | 🟡 中 | 10 p.d. | **P99 ITL -30-40%** |
| [7] Adaptive routing | 🟢 低 | 5 p.d. | 跨 AZ 场景 20-40% |
| [8] Connectionless mesh | 🟢 低 | 8 p.d. | 启动 -30s |

---

## 4. 针对 SGLang 的精准优化方案（按 ROI 排序）

### 4.1 🏆 P0: UCCL-EP 实现 DeepEP 原生 combine signal API

**动机**：
- SGLang 已经写好了 `CombineOverlapArgs` 机制
- 但 UCCL-EP 没实现对应 C++ 接口，SGLang 的 overlap 代码路径在 EFA 上**永远走不通**
- **零 API 破坏、零 SGLang 改动**，做完立刻有收益

**UCCL-EP 改造点**：

1. **`ep/src/uccl_ep.cc:1287` 签名扩展**：
```cpp
low_latency_combine(
    std::uintptr_t x_ptr, ..., 
    std::uintptr_t out_ptr,
    // 新增参数
    bool overlap = false,
    std::uintptr_t src_signals_ptr = 0,
    int src_signal_expect_value = 0,
    std::uintptr_t packed_recv_count_ptr = 0,
    int comp_signal_ptr = 0,
    int block_m = 64,
    int threshold = 0,
    int num_sms = 0)
```

2. **`ep/src/internode_ll.cu combine kernel` 增加 signal spin-wait**：
```cuda
// 在 combine 开始发送 local_expert_idx 数据前
if (src_signals != nullptr && lane_id == 0) {
  while (ld_acquire_global(src_signals + local_expert_idx) < src_signal_expect_value) {
    __nanosleep(100);
  }
}
```

3. **`ep/src/internode_ll.cu combine kernel` 支持动态 SM 数**：
替换 `num_device_sms` 为 `num_sms` 参数

4. **`ep/python/uccl_ep/buffer.py`** 透传新参数给 C++ 绑定

5. **`ep/src/uccl_ep.cc:2132` nanobind binding 添加参数**

**预期效果**（SGLang p5en EP32 decode）：
- Down GEMM 和 combine send 从串行 → 并行
- Decode step time **1500 µs → 1200 µs (-20%)**

**工作量**：8 人天
- UCCL-EP C++ 改造: 5 天
- 测试和验证: 2 天
- SGLang 集成测试（零代码改动）: 1 天

**风险**：低（新增参数，向后兼容）

---

### 4.2 🥈 P1: Dispatch 侧 per-expert early release

**动机**：
- SGLang combine 侧有 per-expert signal，dispatch 侧没有
- 这是**最自然的对称补齐**
- EFA P99 尾延迟在 dispatch 阶段最明显

**现状（`deepep.py:593`）**：
```python
def dispatch_b(self, ...):
    hook() if self.return_recv_hook else event.current_stream_wait()  # 等所有 rank
    return DeepEPLLDispatchOutput(hidden_states, ..., masked_m, ...)
```

**改造目标**：
```python
def dispatch_b(self, ...):
    # 不整体 wait，返回 per_expert_signal
    per_expert_signal = buffer.get_per_expert_ready_signal()
    return DeepEPLLDispatchOutputAsync(
        hidden_states=hidden_states,
        masked_m=masked_m,
        per_expert_signal=per_expert_signal,
        event=event,
    )
```

**下游 MoE layer 改造**（`ep_moe/layer.py:forward_deepgemm_masked`）：
```python
for expert_id in range(num_local_experts):
    if per_expert_signal is not None:
        wait_expert_ready(per_expert_signal, expert_id)  # busy-wait on signal tensor
    run_gemm(hidden_states[expert_id], masked_m[expert_id])
```

**UCCL-EP 侧改造**：
1. `ep/include/ep_config.hpp` `LowLatencyLayout` 加字段 `per_expert_ready_signal`
2. `ep/src/internode_ll.cu dispatch kernel` 在每个 expert dispatch 完成后 atomic_add signal
3. `ep/src/uccl_ep.cc low_latency_dispatch` 返回 signal tensor 指针
4. `ep/python/uccl_ep/buffer.py` 暴露 `get_per_expert_ready_signal()`

**预期效果**：
- Decode P99 ITL **-30-40%**（最慢 rank 延迟不再阻塞快 expert）
- 和 SGLang combine signal 机制对称，零语义冲突

**工作量**：10 人天
- UCCL-EP: 6 天
- SGLang: 3 天
- 测试: 1 天

**风险**：中（需要下游 GEMM kernel 支持 per-expert launch，SGLang 的 `forward_deepgemm_masked` 已是 per-expert）

---

### 4.3 🥉 P2: Single-token Fast Path

**动机**：
- Decode 大部分时间 batch=1-8，**全链路 1 token**
- 现有 kernel 为 batch=4096 优化：128 SM 只用 8-32 个
- `__syncthreads` + grid sync 在 1 token 下纯粹浪费

**改造方式**：LL 路径检测 `num_tokens ≤ 8` 走专用 kernel
```cpp
if (num_tokens <= 8) {
    // 单 warp 路径，跳过 ring buffer，直接写 WQE
    // 跳过 per-expert counter，直接 topk_idx[0..7] 展开
    launch_single_token_fast_dispatch(...);
} else {
    launch_regular_dispatch(...);
}
```

**延迟收益**：单 token dispatch 从 **450 µs → 200-250 µs (-45%)**

**工作量**：6 人天
**风险**：低（新增路径，现有路径不动）

---

### 4.4 P3: LL TBO 启用（Two-Batch Overlap）

**动机**：
- SGLang 代码明确禁用 LL TBO（`two_batch_overlap.py:405-412`）
- 原因：LL 模式下两个 batch 共享同一 `Buffer`，handle 冲突

**改造思路**：
1. UCCL-EP `Buffer` 加 dual-instance 模式：maintain 两套 `handle` / `packed_recv_count` / `low_latency_buffer_idx`
2. SGLang 侧 `_DeepEPDispatcherImplLowLatency` 维护两个并发 state
3. 解除 `two_batch_overlap.py:411` 的 `(resolved_deepep_mode.is_low_latency())` gate

**收益**：Decode batch 拆半交替 → comm 完全 overlap → throughput **+30-50%**

**工作量**：15 人天
**风险**：中高（UCCL-EP Buffer 状态机要重构）

---

### 4.5 P4: Ctrl/Data QP 分离 + Inline Send

**动机**：
- 所有业务（token data / atomic counter / ack）共用一组 SRD QP
- Atomic imm 只有 4B 但和 7KB token 共享 QP，inline data 被关闭（`rdma.cpp:899`）
- Count update 的 SIGNALED 和 token 的 SIGNALED 混在 CQ 里，poll 时要分类

**新架构**：
```
[Data QP pool]   8 QP/proxy, SRD, max_inline=0, unsignaled-mostly, depth=2048
                 专发 token data (7KB WRITE)
                 
[Ctrl QP]        1 QP/proxy, SRD, max_inline=32, all signaled, depth=128
                 专发 atomic count (SEND_INLINE 4B) + barrier msg
                 
[Ack QP]         保留现有逻辑
```

**收益**：
- Ctrl QP inline：count msg 延迟 **-500 ns/count**
- Data QP 大量 unsignaled：CQE 数 **-85%**
- 解锁 4-bit → 6-bit seq 扩展（atomic 独立 QP 后 `AtomicsImm` 32 bit 全可用）

**工作量**：5 人天
**风险**：低（现有 ack_qp/recv_ack_qp 分离模式成熟）

---

### 4.6 P5: Prefill/Decode 分离的 QP 配置

**动机**：
- Prefill 和 decode 对 UCCL-EP 要求完全不同
- 现有架构用同一套 ProxyCtx 服务两种

**改造**：
```bash
UCCL_EP_MODE=prefill  → kChannelPerProxy=16, kNumProxyThs=8, 大 SQ depth
UCCL_EP_MODE=decode   → kChannelPerProxy=2,  kNumProxyThs=2, 小 SQ depth, inline=enabled
```

**收益**：decode 侧 proxy poll CPU **-60%**；每 poll cycle **-2-3 µs**

**工作量**：4 人天
**风险**：低（纯 env var 控制）

---

## 5. 完整 Roadmap

### Sprint 1 - 解锁 SGLang 已有能力（2 周）

| Day | 任务 | 人天 |
|---|---|---|
| 1-5 | **P0**: UCCL-EP 加 combine signal API | 5 |
| 6-8 | **P0**: 测试 + SGLang SBO 验证 | 3 |
| 9-14 | **P2**: Single-token fast path | 6 |

**里程碑**：
- ✅ SGLang `SBO_enable_combine_down_gemm_two_stream_overlap` 在 EFA 上可用
- ✅ Decode P50 latency **1500 µs → 1100-1200 µs**

**Stage 5 Run 变体**：
- R0: baseline SGLang + UCCL-EP HEAD
- R1: + P0 combine signal（验证 SGLang SBO 生效）

---

### Sprint 2 - P99 根治（3 周）

| Day | 任务 | 人天 |
|---|---|---|
| 15-20 | **P1**: UCCL-EP per-expert ready signal | 6 |
| 21-23 | **P1**: SGLang `dispatch_b` + `forward_deepgemm_masked` 改造 | 3 |
| 24 | **P1**: 端到端测试 | 1 |
| 25-29 | **P4**: Ctrl/Data QP 分离 | 5 |

**里程碑**：
- ✅ Decode P99 ITL **3-5 ms → 1.8-2.2 ms (-55%)**
- ✅ Proxy CPU 占用 -30%

**Stage 5 Run 变体**：
- R2: + P1 dispatch per-expert early release
- R3: + P4 Ctrl/Data QP 分离

---

### Sprint 3 - 高阶优化（4 周，可选）

| Day | 任务 | 人天 |
|---|---|---|
| 30-32 | **[2] GPU-resident proxy spike**（验证 AWS EFA SQ 是否可 GPU-map） | 3 |
| 33-37 | 基于 spike 结果：继续 GPU-resident proxy 或转 [5] Persistent kernel | 5-15 |
| 38-52 | **P3**: LL TBO 启用 | 15 |
| 53-56 | **P5**: Prefill/Decode 分离配置 | 4 |

**里程碑**：
- ✅ Throughput +30-50%
- ✅ 推理 EP 性能接近 IB/CX7 水平

---

## 6. Stage 5 集成

按照用户 memory 的 feedback：
- `feedback_stage5_run_docs.md`: 边做边写 `STEPS.md`（流水）+ `RESULT.md`（结构化数据），存 `results/stage5-p5en/<run>/<stamp>/`
- `feedback_sps_before_launch.md`: 每次起 Stage 5 测试前先跑 SPS，按实际 target-capacity 扫
- `feedback_fsx_crossaz_hostpath.md`: 跨 AZ FSx 大模型必须先 hostPath 到本地 NVMe
- `feedback_r0_preflight.md`: 镜像必须含 Mooncake v0.3.10.post2 + 4 Henan PR + rdma→efa 补丁

### 6.1 Docker 镜像构造

在现有 `common/Dockerfile.mooncake-nixl` 基础上：

```dockerfile
# Stage 5 + UCCL-EP 优化镜像
FROM <base-mooncake-nixl>

# UCCL HEAD + Sprint 1 patches
RUN git clone https://github.com/uccl-project/uccl.git /opt/uccl && \
    cd /opt/uccl && git checkout f1ecbaf7 && \
    # Sprint 1 patches (from this repo)
    git apply /patches/p0-combine-signal.patch && \
    git apply /patches/p2-single-token-fastpath.patch && \
    cd ep && PER_EXPERT_BATCHING=1 python setup.py install

# SGLang from source (为了改 dispatcher)
RUN git clone https://github.com/sgl-project/sglang.git /opt/sglang && \
    cd /opt/sglang && git checkout <pinned-sha> && \
    git apply /patches/sglang-per-expert-early-release.patch && \
    pip install -e python/
```

### 6.2 Manifest 配置

`manifests/stage5-p5en/sglang-decode-bench.yaml`：
```yaml
env:
  - name: UCCL_IB_MAX_INFLIGHT_LOW_LATENCY
    value: "48"
  - name: UCCL_IB_MAX_INFLIGHT_BYTES
    value: "8388608"
  - name: UCCL_EP_MODE                # 需要 P5 改造
    value: "decode"
  - name: SGLANG_ENABLE_SBO_COMBINE_OVERLAP  # 解锁 SGLang 现有 SBO
    value: "1"
```

### 6.3 Bench 脚本改造

从 `scripts/stage5-bench.sh` 切换到 **SGLang decode benchmark**（不是 `test_internode.py`），测量：
- **P50/P99 ITL**（inter-token latency）
- **TTFT**（time to first token）
- 不再看带宽（GB/s）

### 6.4 Run 变体顺序

| Run | 内容 | 预期 P50 ITL | 预期 P99 ITL |
|---|---|---|---|
| R0 | baseline HEAD | 1500 µs | 3500 µs |
| R1 | + P0 combine signal | 1200 µs | 3000 µs |
| R2 | + P2 single-token fastpath | 1050 µs | 2800 µs |
| R3 | + P1 dispatch per-expert early release | 950 µs | **1800 µs** |
| R4 | + P4 Ctrl/Data QP 分离 | 920 µs | 1700 µs |
| R5 (optional) | + P3 LL TBO | 900 µs | 1600 µs (+throughput +30%) |

每个 Run 按规则存 `results/stage5-p5en/<run>/<stamp>/STEPS.md + RESULT.md`。

---

## 7. 风险和限制

### 7.1 物理下限
EFA 光速 + PCIe + NIC 处理 = **~80-100 µs 物理下限**。不管怎么优化，EFA decode 一次 EP 操作不可能低于 200 µs（vs IB 120 µs）。

### 7.2 CUDA Graph 不支持是最大隐患
- 10 µs × 每层 2 kernel × 60 层 = **1.2 ms/token launch overhead**
- Sprint 3 必须解决（GPU-resident proxy 或 Persistent kernel）

### 7.3 下游适配
- SGLang 是 P0 焦点；vLLM 也用 UCCL-EP 但接口不同
- 做 SGLang 优化时不破坏 vLLM 路径（保持参数默认值兼容）

### 7.4 上游 UCCL 可能做掉部分工作
- P0 (combine signal) 最有可能被 UCCL 官方做（因为是补 DeepEP API）
- P1 (dispatch early release) 上游不会很快做（不懂 SGLang workload）
- P4 (Ctrl/Data QP 分离) 上游可能做（基础 RDMA 清理）

**策略**：优先做 P0 + P1，即使 P0 被 merge 也不亏（自己能提前 2-3 个月拿到收益）。

---

## 8. 参考资料

### 8.1 UCCL 代码位置
- `uccl/ep/src/uccl_ep.cc:1287` — `low_latency_combine` 签名
- `uccl/ep/src/uccl_ep.cc:2132` — nanobind binding
- `uccl/ep/src/internode_ll.cu` — combine/dispatch kernel
- `uccl/ep/include/common.hpp` — 常量定义（`kMaxInflightLowLatency=32` 等）
- `uccl/ep/src/rdma.cpp:884` — EFA SRD QP 创建
- `uccl/ep/src/rdma.cpp:1834` — LL 单 QP 瓶颈位置

### 8.2 SGLang 代码位置
- `sglang/python/sglang/srt/layers/moe/token_dispatcher/deepep.py:545` — `_DeepEPDispatcherImplLowLatency`
- `sglang/python/sglang/srt/layers/moe/token_dispatcher/deepep.py:724` — `low_latency_combine` 调用（传 signal 参数）
- `sglang/python/sglang/srt/batch_overlap/single_batch_overlap.py:62` — `CombineOverlapArgs`
- `sglang/python/sglang/srt/batch_overlap/two_batch_overlap.py:405` — LL TBO 禁用位置
- `sglang/python/sglang/srt/layers/moe/ep_moe/layer.py:312` — `forward_flashinfer_cutedsl`
- `sglang/python/sglang/srt/layers/moe/token_dispatcher/fuseep.py` — NPU `fused_deep_moe` 参考（未来方向）

### 8.3 关键 GitHub Issues/PRs
- UCCL #893: Megatron EP=32 p5en 5.4× slowdown（false timeout）
- UCCL #878: Qwen3-235B EP=16 intermittent crash on EFA
- UCCL #901: SGLang + EFA assertion error (leoleoasd)
- UCCL #684: duplicate seq 4 arrival（inflight > 32 根因）
- UCCL #734: vLLM hangs LL on EFA；Ziming 确认 LL 不支持 CUDA Graph
- UCCL #737 (MERGED): shared RDMA context（EFA 未受益，DMABUF-only）
- UCCL #522 (OPEN): connectionless EFA mode
- UCCL #728 (DRAFT): rank-batch coalescing
- UCCL #601 (DRAFT): rail-aligned routing
- UCCL #903 (OPEN): dispatch deadlock + memory ordering fix

### 8.4 基准性能（p5en 8×H200 + 16×200Gb/s EFA）
| Type | Dispatch #EP | BW & Latency | Combine #EP | BW & Latency |
|---|---|---|---|---|
| Intranode | 8 | 320 GB/s, 500 µs | 8 | 319 GB/s, 973 µs |
| Internode | 16 | 50 GB/s, 1196 µs | 16 | 18 GB/s, 6379 µs |
| Internode | 32 | 54 GB/s, 2022 µs | 32 | 43 GB/s, 4899 µs |

Low-latency 模式（DS-V3 inference 设置，128 tokens/batch）：
| Dispatch #EP | Latency | BW | Combine #EP | Latency | BW |
|---|---|---|---|---|---|
| 16 | 226 µs | 36 GB/s | 16 | 293 µs | 48 GB/s |
| 32 | 465 µs | 16 GB/s | 32 | 694 µs | 25 GB/s |

---

## 9. 决策记录

### 9.1 为何不优先做 [1] Receiver-driven FC
- 工作量 20+ 人天
- 推理 decode batch 小，incast 不是主要瓶颈
- 研究级改动，风险高
- **推理场景 ROI 低，训练大 batch prefill 才有价值**

### 9.2 为何不优先做 [5] Persistent kernel
- 需要 15+ 人天
- 调试 persistent kernel 困难
- DeepEP API 兼容风险高
- **作为 Sprint 3 备选方案**

### 9.3 为何优先做 P0 (combine signal)
- SGLang 已准备好消费端，零改动即获益
- 新增 API 不破坏现有调用
- 上游不会很快做（非其主要测试场景）
- **性价比最高的单点投资**

### 9.4 为何优先做 P1 (dispatch early release) 而不是 [1] [5]
- 对称补齐 SGLang 已有 combine 机制
- 核心瓶颈（P99 tail）的直接解法
- 10 人天即可交付
- **护城河强**：需要同时理解 UCCL-EP C++ 和 SGLang MoE layer

---

## 10. 下一步行动

### 立即（本周）
1. ☐ 开 UCCL-EP fork，branch `uccl-ep-sglang-efa-opt`
2. ☐ 搭建 Stage 5 推理测试环境（SPS → p5en spot）
3. ☐ 写 R0 baseline benchmark 脚本（SGLang decode）

### Sprint 1（2 周）
1. ☐ P0: 实现 `low_latency_combine` 的 signal 参数
2. ☐ P0: 本地验证 SGLang SBO 路径可用
3. ☐ P2: Single-token fast path
4. ☐ Stage 5 R1 运行，对比 R0

### Sprint 2（3 周）
5. ☐ P1: UCCL-EP per-expert signal + SGLang 集成
6. ☐ P4: Ctrl/Data QP 分离
7. ☐ Stage 5 R2, R3 运行

### Sprint 3（可选）
8. ☐ GPU-resident proxy spike
9. ☐ LL TBO 启用
10. ☐ 推理 EP 性能最终报告

---

**文档维护**：每个 Sprint 结束后更新 "里程碑" 和 "Run 变体" 小节的实测数据。
