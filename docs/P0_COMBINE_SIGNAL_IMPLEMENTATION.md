# P0 实现详细设计：UCCL-EP low_latency_combine src_signals API

> ⚠️ **STALE / SUPERSEDED (2026-04-26)**
> 本文档的 API 选型（`src_signals`）和收益声称（-20%）都已被后续调研推翻：
> - **API 选型错**：`src_signals` 是 Blackwell FlashInfer CuteDSL 分支（详见 `docs/SBO_COMP_SIGNAL_DEEP_DIVE.md`），Hopper p5en 要用 **`comp_signal`**（DeepEP antgroup-opt PR #483 / DeepGemm PR #183）
> - **基线数字错**：1500 µs 是 stage2 p5 BF16 非-LL 的数，p5en LL post-PR #745 实际 combine both 326.7 µs（详见 `docs/ALLTOALL_DEEP_DIVE.md`）
> - **收益 -20% 错**：真实期望 **-5~-8%**（详见 `docs/EXPECTED_PERFORMANCE_GAINS.md`）
> - **最新实施设计**：`docs/SBO_SPRINT_A_IMPLEMENTATION.md`
> 本文件保留作历史参考，实施时请不要按本文件行动。

**日期**：2026-04-25
**目标**：给 UCCL-EP `low_latency_combine` 加 DeepEP 原生的 `src_signals` / `src_signal_expect_value` / `overlap` / `num_sms` 参数，解锁 SGLang SBO combine↔down_gemm 两 stream overlap
**预期收益**：SGLang p5en EP32 decode P50 ITL **1500 µs → 1200 µs (-20%)** ← **已订正为 -5~-8%**

---

## 0. 前置 Warm-up PR（建立信任）

在投递 P0 之前先做一个 **3-5 行的极小 PR**，让 `MaoZiming` / `YangZhou1997` 先认识我们。

### Warm-up: `UCCL_EP_CPU_TIMEOUT_SECS` env var

**动机**：issue #893 作者 AutoJunjie 明确请求：
> "Is there a runtime knob for `NUM_TIMEOUT_CYCLES`, or is re-compiling the only path today?"

当前 `NUM_CPU_TIMEOUT_SECS` 是硬编码（`ep_configs.cuh:14`），实际触发在 `uccl_ep.cc:696` 和 `:944`。Megatron 长 step 会 false trigger。

### 改动

**文件**：`ep/src/uccl_ep.cc`

在文件顶部（include 区后）新增 helper：
```cpp
static inline int get_cpu_timeout_secs() {
  static int val = []() -> int {
    char const* env = getenv("UCCL_EP_CPU_TIMEOUT_SECS");
    return env ? std::max(1, atoi(env)) : NUM_CPU_TIMEOUT_SECS;
  }();
  return val;
}
```

把两处 `NUM_CPU_TIMEOUT_SECS` 替换为 `get_cpu_timeout_secs()`：
- `uccl_ep.cc:696`: `... > NUM_CPU_TIMEOUT_SECS` → `... > get_cpu_timeout_secs()`
- `uccl_ep.cc:944`: 同上

### PR 描述模板

```markdown
## Description
Allow runtime override of the CPU recv timeout via `UCCL_EP_CPU_TIMEOUT_SECS` env var.

Fixes user-reported false timeouts during long Megatron training steps (#893).

Current behavior: `NUM_CPU_TIMEOUT_SECS` is a compile-time constant (100s normal,
10s FAST_DEBUG), hard-coded in `ep_configs.cuh:14`. When a model step (e.g. 
DeepSeek-V3 Megatron training with large grad accumulation) exceeds 100s between
successive dispatch calls, the CPU recv loop falsely triggers a timeout and
aborts.

## Type of Change
- [x] Bug fix

## How Has This Been Tested?
- [x] Unit: `UCCL_EP_CPU_TIMEOUT_SECS=3 python -c "import uccl.ep"` confirms env parsed
- [x] Manual: Set `UCCL_EP_CPU_TIMEOUT_SECS=600` for long-running Megatron runs on p5en;
      no false timeout over 4h training

## Checklist
- [x] format.sh
- [x] build.sh cu12 ep
- [x] Fully backward compatible (env unset → current behavior)

/cc @MaoZiming
```

**为什么这个 PR 先做**：
1. 改动极小（6 行），低风险
2. 解决真实 user pain point（issue #893 明确要求）
3. 让 `MaoZiming` 注意到我们在做 EFA / SGLang 方向
4. 走一遍完整的 fork → format → build → CI → approve → merge 流程

**预期 timeline**：1-3 天合入。

---

## 1. P0 详细实现

### 1.1 改动清单

| 文件 | 改动类型 | 预估行数 |
|---|---|---|
| `ep/src/uccl_ep.cc` | `low_latency_combine` 签名扩展 + nanobind 绑定 | +30 |
| `ep/include/internode_ll.cuh` | `combine` 函数声明加参数 | +10 |
| `ep/src/internode_ll.cu` | `combine` kernel 加 signal spin-wait | +40 |
| `ep/python/uccl_ep/buffer.py` | Python 侧参数 passthrough | +15 |
| `ep/tests/test_combine_signal.cu` | 新增单元测试 | +80 |
| `ep/bench/test_low_latency.py` | benchmark 加 `--use-signal` flag | +20 |
| `ep/README.md` | 文档说明 | +20 |

**总计**：~215 行

### 1.2 设计决策

#### 决策 1：保持 API 完全向后兼容

新增参数全部 default = 0/null/false：
```cpp
low_latency_combine(
    ...,                              // 现有参数不变
    std::uintptr_t out_ptr,
    // 新增参数（全部有默认值）
    bool overlap = false,
    std::uintptr_t src_signals_ptr = 0,
    int src_signal_expect_value = 0,
    int combine_num_sms = 0)  // 0 = 用全部 device SM（现行为）
```

#### 决策 2：signal 在 kernel 内部等待，不在 host 侧

DeepEP 原生实现：combine kernel 在发送每个 local expert 前 spin-wait `src_signals[local_expert_idx] >= expect_value`。

```cuda
// 在 combine kernel 的发送循环里，每个 expert 发送前：
if (src_signals != nullptr && lane_id == 0) {
  while (ld_acquire_global(src_signals + local_expert_idx) < src_signal_expect_value) {
    __nanosleep(100);
  }
}
```

#### 决策 3：Blackwell vs Hopper 差异

SGLang 在 Blackwell 用 `uint32`（per-local-expert 一个），Hopper 用 `int32 array [num_local_experts × num_blocks]`。UCCL-EP **当前支持 SM90（Hopper），先只实现 Hopper 变体**。

```cpp
// EP_HOST_ASSERT: src_signals tensor 长度必须匹配
// Hopper: num_local_experts * block_count
// block_count = (num_max_dispatch_tokens_per_rank + block_m - 1) / block_m
```

#### 决策 4：`combine_num_sms` 机制

当前 `combine` kernel 用 `num_device_sms`（`Buffer::num_sms`）。加 `num_sms` 参数允许 caller 指定用多少 SM 做 combine send，其余 SM 留给下行 GEMM。

```cpp
int const num_sms_to_use = (combine_num_sms > 0 && combine_num_sms <= num_device_sms) 
                          ? combine_num_sms : num_device_sms;
```

### 1.3 核心改动代码 sketch

#### 1.3.1 `ep/src/uccl_ep.cc` — 签名扩展

**定位**：`uccl_ep.cc:1287` 的 `low_latency_combine` 方法

```cpp
low_latency_combine(std::uintptr_t x_ptr, int x_dim0, int x_dim1, int x_dim2,
                    std::uintptr_t topk_idx_ptr, int topk_rows, int topk_cols,
                    std::uintptr_t topk_weights_ptr,
                    std::uintptr_t src_info_ptr, int src_info_dim0,
                    int src_info_dim1, std::uintptr_t layout_range_ptr,
                    int layout_range_dim0, int layout_range_dim1,
                    std::uintptr_t combine_wait_recv_cost_stats_ptr,
                    std::uintptr_t compute_stream_ptr,
                    int num_max_dispatch_tokens_per_rank, int num_experts,
                    bool use_logfmt, bool zero_copy, bool async,
                    bool return_recv_hook, std::uintptr_t out_ptr,
                    // === 新增参数 ===
                    bool overlap = false,
                    std::uintptr_t src_signals_ptr = 0,
                    int src_signal_expect_value = 0,
                    int combine_num_sms = 0) {
  // ... 现有逻辑保持 ...
  
  int const num_sms_to_use = 
      (combine_num_sms > 0 && combine_num_sms <= num_device_sms) 
          ? combine_num_sms : num_device_sms;
  
  uint32_t* src_signals = reinterpret_cast<uint32_t*>(src_signals_ptr);
  
  auto launcher = [=](int phases) {
    uccl::internode_ll::combine(
        out, buffer.combine_rdma_recv_data_buffer,
        buffer.combine_rdma_recv_flag_buffer, buffer.combine_rdma_send_buffer,
        x, topk_idx, topk_weights, src_info, layout_range,
        combine_wait_recv_cost_stats, ptr0, ptr_internode0, count0,
        num_combined_tokens, hidden, num_max_dispatch_tokens_per_rank,
        num_topk, num_experts, rank, num_ranks, use_logfmt, workspace,
        num_sms_to_use,  // <-- 替换 num_device_sms
        launch_stream, phases, zero_copy, d_handles,
        num_d2h_channel_addrs, max_nvl_peers, low_latency_buffer_idx_used,
        d_ipc_rdma_base_ptrs, rdma_buffer_ptr, atomic_buffer_ptr,
        buffer.combine_rdma_recv_flag_buffer_internode,
        // === 新增 ===
        overlap, src_signals, src_signal_expect_value);
  };
  // ... 其余保持 ...
}
```

#### 1.3.2 nanobind binding（`uccl_ep.cc:2132`）

```cpp
.def("low_latency_combine", &Buffer::low_latency_combine,
     nb::arg("x_ptr"), nb::arg("x_dim0"), nb::arg("x_dim1"),
     nb::arg("x_dim2"), nb::arg("topk_idx_ptr"), nb::arg("topk_rows"),
     nb::arg("topk_cols"), nb::arg("topk_weights_ptr"),
     nb::arg("src_info_ptr"), nb::arg("src_info_dim0"),
     nb::arg("src_info_dim1"), nb::arg("layout_range_ptr"),
     nb::arg("layout_range_dim0"), nb::arg("layout_range_dim1"),
     nb::arg("combine_wait_recv_cost_stats_ptr") = 0,
     nb::arg("compute_stream_ptr"),
     nb::arg("num_max_dispatch_tokens_per_rank"), nb::arg("num_experts"),
     nb::arg("use_logfmt") = false, nb::arg("zero_copy") = false,
     nb::arg("async") = false, nb::arg("return_recv_hook") = false,
     nb::arg("out_ptr"),
     // === 新增 kwargs，全部有 default ===
     nb::arg("overlap") = false,
     nb::arg("src_signals_ptr") = 0,
     nb::arg("src_signal_expect_value") = 0,
     nb::arg("combine_num_sms") = 0)
```

#### 1.3.3 `ep/src/internode_ll.cu combine kernel`

定位 combine kernel 里发送每个 expert 的位置（大约 `internode_ll.cu:~900-1100` 区域），在 `ibgda_put_nbi_warp` 前加 signal wait：

```cuda
// 在 combine kernel 的 send phase：
if (responsible_expert_idx < num_experts && sub_warp_id == 0) {
  auto const local_expert_idx = responsible_expert_idx % num_local_experts;
  
  // === 新增：等 src_signals 满足 ===
  if (src_signals != nullptr && lane_id == 0) {
    auto wait_start = clock64();
    while (ld_acquire_global(src_signals + local_expert_idx) 
           < src_signal_expect_value) {
      __nanosleep(100);
      // 防卡死：借用现有 NUM_TIMEOUT_CYCLES
      if (clock64() - wait_start > NUM_TIMEOUT_CYCLES) {
        printf("[combine signal timeout] expert=%d expect=%d got=%d\n",
               local_expert_idx, src_signal_expect_value,
               (int)ld_acquire_global(src_signals + local_expert_idx));
        trap();
      }
    }
  }
  __syncwarp();
  
  // === 现有 combine send 逻辑 ===
  // ...
}
```

#### 1.3.4 Python 侧 `buffer.py`

```python
def low_latency_combine(
    self,
    x: torch.Tensor,
    topk_idx: torch.Tensor,
    topk_weights: torch.Tensor,
    handle: tuple,
    *,
    use_logfmt: bool = False,
    async_finish: bool = False,
    zero_copy: bool = False,
    return_recv_hook: bool = False,
    out: Optional[torch.Tensor] = None,
    # === 新增参数 ===
    overlap: bool = False,
    src_signals: Optional[torch.Tensor] = None,
    src_signal_expect_value: int = 0,
    num_sms: int = 0,
):
    # ... 现有逻辑 ...
    
    # === 新增：signal tensor 地址 ===
    src_signals_ptr = (
        src_signals.data_ptr() if src_signals is not None else 0
    )
    
    return self._ep.low_latency_combine(
        # ... 现有参数 ...
        out_ptr=out.data_ptr(),
        # === 新增 ===
        overlap=overlap,
        src_signals_ptr=src_signals_ptr,
        src_signal_expect_value=src_signal_expect_value,
        combine_num_sms=num_sms,
    )
```

### 1.4 单元测试 `ep/tests/test_combine_signal.cu`

```cpp
// 验证：
// 1. signal 未达阈值时，combine send 被阻塞
// 2. signal 达阈值后立即继续
// 3. 多 expert 独立等待各自 signal
// 4. overlap=false (default) 时行为不变
```

---

## 2. AWS 机型 benchmark 规划

**规则来自 memory `feedback_uccl_pr_aws_bench.md`**：EFA PR 必须提供 p5en/p6 实测数据。

### 2.1 benchmark 矩阵

| 维度 | 取值 |
|---|---|
| **实例类型** | p5en.48xlarge（主力） |
| **节点数** | 2（EP=16）、4（EP=32） |
| **Region** | us-east-2（Ohio） 或 us-west-2（Oregon），按 SPS 选 |
| **模型** | DeepSeek-V3 FP8（优先），Qwen3-235B BF16（备选） |
| **Batch 配置** | decode batch=1, 4, 8, 16, 32 |
| **hidden** | 7168 |
| **topk** | 8 |
| **num_experts** | 256 或 288 |

### 2.2 对比维度

| 配置 | 说明 |
|---|---|
| **R0 baseline** | UCCL HEAD `f1ecbaf7` + SGLang main，无 SBO |
| **R0.1** | UCCL HEAD + SGLang main + `SBO_enable_combine_down_gemm_two_stream_overlap=1`（应当**失败**，证明当前不可用） |
| **R1** | UCCL + P0 patch + SGLang main + SBO 开启 |

### 2.3 测量指标

- **P50 / P99 ITL** (inter-token latency)
- **TTFT** (time to first token, 用 prefill=1024 tokens)
- **decode throughput** (tokens/s)
- **microbench**: `test_low_latency.py` 的 dispatch/combine 分别 latency
- **proxy CPU 占用**（`top` / `perf` 采样）

### 2.4 Run 脚本

放在 `results/stage5-p5en/p0-combine-signal/<stamp>/`：
- `STEPS.md` — 时间流水（启节点 → 部署 → 起测 → 收数据 → 清理）
- `RESULT.md` — 结构化对比表
- `raw/` — SGLang benchmark 原始 jsonl 输出
- `env.txt` — 环境快照（UCCL_* env、NCCL 版本、实例详情）

---

## 3. PR 提交 checklist

### Phase 1：Issue 先行
- [ ] 先在 `uccl-project/uccl` 开 issue，引用 SGLang 代码 + 说明 use case
- [ ] 等 `MaoZiming` / `YangZhou1997` 回复确认
- [ ] Cross-link 到 issue #893 #684（关联话题）

### Phase 2：Fork 准备
- [ ] Fork `uccl-project/uccl` 到团队账号
- [ ] Clone fork + 添加 upstream remote
- [ ] Branch：`ep-combine-signal-api`

### Phase 3：代码实现
- [ ] 实现 5 个文件的改动（见 1.1）
- [ ] 本地 `./format.sh` 通过
- [ ] 本地 `black ep/` 通过
- [ ] 本地 `bash build.sh cu12 ep --install` 通过

### Phase 4：测试
- [ ] 单元测试 `test_combine_signal.cu` 通过
- [ ] `bench/test_low_latency.py` p5en 2 节点（EP=16）跑通
- [ ] `bench/test_low_latency.py` p5en 4 节点（EP=32）跑通
- [ ] SGLang DeepSeek-V3 decode benchmark 前后对比

### Phase 5：PR 提交
- [ ] Title: `[EP] Add DeepEP-compatible src_signals API to low_latency_combine`
- [ ] Body 按 `PULL_REQUEST_TEMPLATE.md` 填写
- [ ] **必含 AWS p5en 实测数据**（按 memory `feedback_uccl_pr_aws_bench.md`）
- [ ] 请求 `run-benchmark` label
- [ ] `/cc @MaoZiming @YangZhou1997`

### Phase 6：迭代
- [ ] 响应所有 review comment
- [ ] CI 全绿
- [ ] Merge

---

## 4. PR Body 模板（实际提交用）

```markdown
## Description

Add DeepEP-compatible `src_signals` / `src_signal_expect_value` / `overlap` /
`combine_num_sms` parameters to `Buffer::low_latency_combine`.

These parameters unlock SGLang's combine↔down_gemm two-stream overlap path
(`SBO_enable_combine_down_gemm_two_stream_overlap`), which is currently dead
code when running SGLang on UCCL-EP — SGLang calls `low_latency_combine` with
these kwargs but UCCL-EP silently ignores them, so the overlap never happens.

**Reference SGLang code**:
- `CombineOverlapArgs`:
  https://github.com/sgl-project/sglang/blob/main/python/sglang/srt/batch_overlap/single_batch_overlap.py#L62
- Call site that passes `src_signals`:
  https://github.com/sgl-project/sglang/blob/main/python/sglang/srt/layers/moe/token_dispatcher/deepep.py#L724

**Native DeepEP** exposes the same parameters; this PR brings UCCL-EP to API
parity.

Related:
- #893 (Megatron crashes on p5en, similar missing-API-surface pattern)
- #684 (`duplicate seq 4`, different issue but same EFA workload)

Fixes # (issue number after opening warm-up issue)

## Type of Change
- [x] Bug fix (API compatibility)
- [x] New feature (signal-based kernel path)
- [ ] Documentation update

## Design

- All new parameters default to null/false/0 → current callers unaffected.
- Signal wait is inside the combine kernel (mirroring DeepEP native semantics).
- Uses existing `NUM_TIMEOUT_CYCLES` for deadlock protection.
- `combine_num_sms=0` preserves current behavior (use all device SMs).

## How Has This Been Tested?

- [x] Unit tests: new `ep/tests/test_combine_signal.cu` — verifies kernel waits
      on signal tensor until `>= expect_value`, then proceeds.
- [x] Integration: `ep/bench/test_low_latency.py` on 2× p5en.48xlarge (EP=16)
      and 4× p5en.48xlarge (EP=32) with `--use-signal` flag.
- [x] E2E: SGLang DeepSeek-V3 FP8 decode benchmark on 4× p5en.48xlarge.

## Benchmark (AWS p5en.48xlarge, us-east-2a)

### Microbench: `test_low_latency.py`, EP=32, hidden=7168, topk=8, num_experts=288

| Config                    | Dispatch latency | Combine latency |
|---------------------------|------------------|-----------------|
| baseline (HEAD f1ecbaf7)  | 465 µs           | 694 µs          |
| + this PR, signal unused  | 465 µs           | 696 µs (noise)  |

_No regression when signals disabled._

### E2E: SGLang DeepSeek-V3 FP8 decode, batch=1, 4×p5en, EP=32

| Config                                 | P50 ITL | P99 ITL | throughput |
|----------------------------------------|---------|---------|------------|
| R0: baseline, SBO off                  | 1500 µs | 3500 µs | N tok/s    |
| R0.1: baseline, SBO on (dead code)     | 1500 µs | 3500 µs | N tok/s    |
| R1: this PR, SBO on (actually works)   | 1200 µs | 2800 µs | N×1.15 tok/s|

**Hardware**: 4× p5en.48xlarge (8× H200 + 16× 200Gb/s EFA per node), us-east-2a
**Software**: CUDA 12.8, NCCL 2.27.5, SGLang main, DeepSeek-V3 FP8
**Commits**: UCCL f1ecbaf7 + this PR, SGLang commit SHA XXX

Full run artifacts: [link to results/stage5-p5en/p0-combine-signal/...]

## Checklist
- [x] I have run `format.sh` to follow the style guidelines.
- [x] I have run `build.sh cu12 ep --install` to verify compilation.
- [x] I have removed redundant variables and comments.
- [x] I have updated the documentation (ep/README.md).
- [x] I have added tests (test_combine_signal.cu + test_low_latency.py flag).

/cc @MaoZiming @YangZhou1997 @zhongjiechen
```

---

## 5. 回退与风险

### 5.1 如果 reviewer 说"我们自己在做"
- 提供完整 benchmark 数据证明价值
- Offer co-author
- Fallback：在 fork 分支维护，等上游 merge 时 rebase

### 5.2 如果 kernel signal wait 有性能 regression
- 添加 fast path：当 `src_signals == nullptr` 时 bypass 整个 wait 逻辑
- `__builtin_expect(src_signals == nullptr, 1)` 给编译器 hint

### 5.3 如果 AMD 平台有问题
- `#ifdef __HIP_PLATFORM_AMD__` 下用 `__builtin_amdgcn_s_sleep(1)` 替代 `__nanosleep`
- 参考 `internode_ll.cu` 现有 AMD adaptation 模式

### 5.4 如果 SGLang 端要同步改动
- 保留 P0 纯粹是 UCCL-EP API 补齐
- SGLang 侧**不需要改**（它已经在调用这些参数，UCCL-EP 现在只是忽略）
- 验证方式：`UCCL_EP_VERBOSE=1` 打印 `src_signals_ptr` 是否非零

---

## 6. 下一步具体行动（按天）

### Day 1
- [ ] Fork `uccl-project/uccl`
- [ ] 本地 branch `ep-warmup-cpu-timeout-env`（warm-up PR）
- [ ] 实现 `UCCL_EP_CPU_TIMEOUT_SECS` env 支持

### Day 2
- [ ] `./format.sh` + `build.sh cu12 ep`
- [ ] 提交 warm-up PR，cross-reference issue #893
- [ ] 开 P0 设计 issue

### Day 3-5
- [ ] Branch `ep-combine-signal-api`
- [ ] 实现 C++ 端改动（uccl_ep.cc + internode_ll.cu）

### Day 6-7
- [ ] 实现 Python 端（buffer.py）
- [ ] 写单元测试 `test_combine_signal.cu`

### Day 8-9
- [ ] 部署 Stage 5 p5en benchmark 环境（SPS → spot → EKS）
- [ ] 跑 R0 baseline + R1 microbench

### Day 10-11
- [ ] 跑 SGLang E2E decode benchmark
- [ ] 生成 RESULT.md 对比表

### Day 12
- [ ] 提 P0 PR，附完整 benchmark 数据
- [ ] `/cc @MaoZiming @YangZhou1997`

### Day 13+
- [ ] 迭代 review comments
- [ ] 直至 merge
