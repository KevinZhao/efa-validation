# P0 设计 Review 结果

**日期**：2026-04-25
**Review 对象**：`docs/P0_DETAILED_DESIGN.md`
**Review 模式**：自查 + 反向验证假设

---

## 🔴 严重问题（阻塞实施）

### 问题 1：`src_signals` / `comp_signal` API **不在 DeepEP 上游**

**假设（之前）**：SGLang 的 `low_latency_combine(..., src_signals=..., comp_signal=...)` 调用的是 DeepEP 原生 API。

**事实（验证）**：
- 官方 DeepSeek DeepEP（`github.com/deepseek-ai/DeepEP`）上游 `deep_ep/buffer.py:617` 的 `low_latency_combine` 签名**没有 `src_signals` / `comp_signal` / `overlap` 参数**
- UCCL vendored 的 `thirdparty/DeepEP/csrc/deep_ep.hpp:155` 也**没有这些参数**
- GitHub Code 全网搜 `src_signals` + C++/CUDA 代码 = 0 结果
- **整个公开 GitHub 只有 SGLang Python 端引用这些参数名**

**含义**：
- SGLang 当前走的是 `overlap_args is None` 分支（默认值），所以用户即使启用 `enable_single_batch_overlap` 也不会真正调用这些参数
- `SboFlags.enable_combine_down_gemm_two_stream_overlap()` 需要同时满足：
  1. `is_sbo_enabled()` — 用户 flag
  2. `get_moe_runner_backend().is_flashinfer_cutedsl() or (is_deep_gemm() and not is_blackwell())`
- 即使走到这里，目前 SGLang 调用的 DeepEP API 是"dead-code-by-design"：**这是 SGLang 给未来 DeepEP 版本留的 hook，当前版本不激活**

**结论**：
- 🔴 **我们的 PR body 里"解锁 SGLang SBO dead code"的叙事不成立**
- 🔴 **没有上游规范可以参考**：我们要自己定义这个 API 的语义
- 🔴 **SGLang 侧不一定能"零改动"受益**：需要验证 SGLang runtime 真的会传这些参数

**修正方向**：
两条路可选：

**Path A**：**跟 SGLang 团队先沟通**
- 在 `sgl-project/sglang` 开 issue 确认 `src_signals`/`comp_signal` 的 expected semantics
- 让他们指明这个 overlap API 是给哪个 DeepEP fork 准备的
- 如果他们有 spec，我们按 spec 实现

**Path B**：**降级为 dispatch 侧 per-expert early release（原 P1）**
- 这条路径 UCCL-EP 完全自主设计 API
- 对 SGLang 需要一起改（但改动可控）
- 不依赖任何未发布的 DeepEP spec

---

### 问题 2：Thirdparty DeepEP 是 vendored，不是 submodule

**事实**：UCCL `thirdparty/DeepEP/` 没有 `.git`，不是 submodule（`.gitmodules` 里没有 DeepEP 条目）。
- 这是 UCCL 自己从老版 DeepEP 手动拷贝来的 source
- 版本可能停留在 2025 年中的某个 commit
- 和 DeepSeek 上游完全脱钩

**含义**：
- UCCL-EP 的 `low_latency_combine` 和上游 DeepEP API 已经**不再同步**
- 我们加的参数既要兼容 UCCL-EP 现有调用方，又要参考 SGLang 的**未实现的** API
- "保持 DeepEP API 兼容" 不是 UCCL 的硬约束（他们早就偏离了）

**修正**：
- PR body 去掉"mirror DeepEP native semantics"措辞
- 改为"add SGLang-requested API parameters"

---

### 问题 3：Hopper 的 `comp_signal` 语义是我**推断的**，没有实际实现参考

**我之前的设计文档声称**：
> Signal layout: `[num_local_experts × num_blocks_per_expert]`
> `block_m=64`, threshold = `compute_num_sms`
> Down GEMM 每 block 完成后 atomic_add(compute_num_sms)
> Combine 按 per-block gate 发送

**实际证据**：
- SGLang `single_batch_overlap.py:123-129` 确实按 `[num_local_experts * num_blocks]` int32 分配 signal
- SGLang **没有下游 GEMM kernel 对 `comp_signal` 的写入实现**（只有 Blackwell 路径的 `down_signals` 被 `flashinfer_cutedsl_moe.py` 消费）
- Hopper 路径的 down GEMM 应该由 DeepGEMM 写 signal，但 DeepGEMM 中**同样没有这个接口**

**含义**：
- **Hopper 路径的 `comp_signal` 是 SGLang 预留 stub**，下游 kernel 都没写入
- 实现 UCCL-EP 侧 combine kernel 等 signal 也没用，因为 **signal 永远不会被写**
- 如果 PR 合了这个 kernel 改动，end-to-end 会 spin 到 timeout

---

## 🟡 次严重问题

### 问题 4：测试数据全是推断值，未实测

设计文档的 benchmark 表格：
```
| R0: baseline, SBO off                  | 1500 µs | 3500 µs |
| R1: this PR, SBO on (actually works)   | 1200 µs | 2800 µs |
```

这些都是**我编的数字**，不是实测。PR body 里用这些数字会被立刻发现是 fabricated。

### 问题 5：模板参数化 `kEnableOverlap` 会显著增加编译时间

- 现 8 个模板 instance → 变 16 个
- 每个 instance 带 TMA + 1024 launch bounds，编译耗时 30-60 秒
- CI 编译时间翻倍

### 问题 6：per-block signal wait 需要额外的 block 分配逻辑

现有 combine kernel 按 `layout` 里的 `offset + num_tokens_to_send` 连续发送。加 per-block gate 后：
- 需要根据 `offset` 计算起始 block
- 需要跨 block 的同步（确保 block N-1 发完再看 block N 的 signal？还是独立？）
- `packed_recv_count[expert]` 的含义 vs `block_start` 的 relation 需要精确定义

当前设计文档 section 3.1 的伪代码**没处理这些边界**，真写出来会有 bug。

---

## 🟢 设计中正确的部分

1. ✅ 区分 Hopper / Blackwell 走不同 API
2. ✅ 保持 overlap=false 默认值，向后兼容
3. ✅ 同时暴露两组参数（forward-compat）
4. ✅ Warm-up PR 策略正确
5. ✅ `NUM_TIMEOUT_CYCLES` 做死锁保护
6. ✅ 使用现有 env helper pattern

---

## 🔧 修正后的 P0 设计建议

**核心改变**：**抛弃"对齐 SGLang 现有 SBO" 这条路径**，改为**独立设计 UCCL-EP 的 early-release API**。

### 修正 Path A：**定义 UCCL-EP 自己的 combine overlap API**

```python
# UCCL-EP 自家 API
combined_x, event, hook = buffer.low_latency_combine(
    x, topk_idx, topk_weights, handle,
    # 现有参数保持不变
    async_finish=False, return_recv_hook=False, out=None,
    # === UCCL 独有的 overlap API ===
    uccl_per_expert_ready_signal=signal_tensor,  # [num_local_experts] int32
    uccl_signal_ready_value=threshold,           # 到达即发送
    uccl_combine_num_sms=3,                      # 用几个 SM 做 combine send
)
```

**优点**：
- 完全自主可控的语义
- 不伪装兼容不存在的 API
- 设计上更简单（per-expert 而不是 per-block）
- 可以直接给 SGLang 提 "请改 dispatcher 调用" 的 PR

**缺点**：
- SGLang 需要改一处调用（不是零改动）
- 但改动极小（10 行 Python）

### 修正 Path B：**先只做 P0 API 骨架**

把 P0 拆成两步：
1. **P0a**: 增加参数签名 + Python 端，kernel **只转发不使用**（no-op）
2. **P0b**: 实现 kernel signal wait（等我们有下游 signal writer 的实现）

P0a 的价值：
- Warm-up 后的第二个小 PR
- 解决"API 不存在"的兼容问题
- 给未来的 down GEMM writer 留接口
- 风险极低（纯 API 扩展，无 kernel 改动）

PR body 不用编数字：
> "API stub for future overlap path. When caller passes non-null signal,
> currently raises `NotImplementedError`. Kernel wait path will land in
> follow-up PR once downstream signal writer (DeepGEMM PR XXX) is ready."

### 修正 Path C：**调整优先级，P1 先做**

跳过 P0 直接做 P1（dispatch per-expert early release）。
- 这条路 UCCL-EP 完全主导
- SGLang 侧改动我们自己设计
- 没有 Hopper/Blackwell 分叉问题

---

## 🎯 推荐最终决策

**不做原 P0**。改为：

### 新 P0：**UCCL-EP 原生 per-expert signal API**（Path A 变体）

- 放弃"兼容 SGLang 现有 dead-code API"的幻觉
- 设计 **UCCL 自己的** per-expert signal API（per-expert 粒度，不是 per-block）
- 同时提交两个 PR：
  - UCCL-EP: 添加 `uccl_*_signal` 参数 + kernel wait
  - SGLang: 增加一个"native UCCL overlap" backend 选项

**为什么不做 per-block**：
- per-block 需要下游 GEMM kernel 配合（SGLang 那边都没实现）
- per-expert 够用，实现复杂度低 2×
- 收益估计 60-70% 的 per-block 收益

**改名 API**：从 `src_signals`/`comp_signal` 改为 **`uccl_expert_ready_signal`** 更清楚是 UCCL 自己的扩展。

**benchmark 真实数据来源**：
- 现实我们只有 `test_low_latency.py` 的 micro 数据
- E2E 需要改 SGLang + UCCL 再跑，工作量大
- **先提 API PR，benchmark 数据部分写 TODO**，说明 AWS 测试在 Stage 5 进行中

---

## ⚠️ 对 PR #904 (warm-up) 的影响

Warm-up PR 本身**不受影响**（只是加 env var，独立价值）。但我们提 warm-up PR 的 message 里暗示后续会做 combine signal API — 那个叙事要在后续 PR 里转调。

**不需要修改 PR #904**。

---

## 🗂 下一步行动

1. ☐ 在 `sgl-project/sglang` 开 issue 澄清 `src_signals`/`comp_signal` 的预期语义和下游 writer
2. ☐ 等 SGLang maintainer 回复（2-5 天）
3. ☐ 根据回复决定：
   - 如果 SGLang 说"马上有 DeepGEMM patch 支持" → 回到原 P0 路径
   - 如果 SGLang 说"这是 future stub" → 改做 Path A（UCCL 自家 API）
   - 如果 SGLang 说"已 deprecated" → 直接做 P1
4. ☐ 平行：继续 AWS p5en 环境准备（SPS 扫描，Stage 5 R0 baseline benchmark）
5. ☐ 平行：跟进 PR #904 review

---

## 📝 对设计文档本体的修改

原 `docs/P0_DETAILED_DESIGN.md` 需要：

| 章节 | 修改 |
|---|---|
| 0.1 | 删除"mirror DeepEP Hopper semantics"，改为"SGLang-requested future API" |
| 0.2 | 去掉"per-block is 1.5-2× harder but necessary"，因为其实 per-expert 就够 |
| 3.1 | per-block kernel 代码移除，改为 per-expert |
| 9 | benchmark 表格标 `TBD (not yet measured)` |
| 10 | 路线图调整：先开 SGLang issue 再决定 PR 路径 |

**建议**：不修改 `P0_DETAILED_DESIGN.md`，新建 `P0_DETAILED_DESIGN_v2.md`，保留 v1 作为"设计偏差案例"的教训。
