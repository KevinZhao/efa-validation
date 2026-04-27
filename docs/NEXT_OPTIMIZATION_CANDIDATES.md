# UCCL-EP 下一批优化候选评估

**日期**：2026-04-25
**上游基线**：`uccl-project/uccl` HEAD `f1ecbaf7`（`Fix/bdf connect API and bug fixes (#899)`）
**已提交**：PR #904（CPU timeout env），等待 review
**本文目的**：按"端到端闭环 / 客户真实痛点 / AWS 可验证"三条原则筛出下一批候选，**设计与实现相对清晰后再提 PR**

---

## 0. 筛选原则（来自 P0 设计失败的教训）

P0（combine signal API）的原始设计依赖 DeepEP 上游一个"只存在于 SGLang Python 层"的 API（`src_signals` / `comp_signal`），C++/CUDA 端并无实现。检讨后定 3 条硬性准入：

1. **端到端闭环**：改动必须在 `uccl-project/uccl` 或 `uccl-project/uccl` + SGLang 之一的 repo 内闭环验证，不依赖未释出的第三方 stub。
2. **客户真实痛点**：必须命中一个 open issue、PR 讨论、或 benchmark 能直接量化的瓶颈，不做"理论上很漂亮但没人撞到"的优化。
3. **AWS EFA 可验证**：必须能在我们现有 p5en/p6 EKS 上跑出可测量的 before/after 数据，否则上游 reviewer 会挂起。

---

## 1. 候选全集（12 个）

| # | 来源 | 标题 | 方向 |
|---|---|---|---|
| A | Issue #893 后半段 | GPU-side `NUM_TIMEOUT_CYCLES` 运行时开关 | 训练稳定性（CPU-timeout follow-up）|
| B | Issue #895 | `ibv_fork_init` + `pthread_atfork` | 训练可用性（DataLoader fork）|
| C | Issue #901 + #893 | `internode_prepare` 硬编码 `previous_event=None` | **推理可用性（SGLang DP+DeepEP）**|
| D | Issue #684 | Reordering buffer 4-bit 溢出 → `duplicate seq 4` | 长稳测试（20h+ 触发）|
| E | 原 P1 roadmap | Dispatch per-expert early release | 推理性能（-10~20 % decode）|
| F | 设计讨论 | EFA SL-based QoS（dispatch vs combine 优先级）| 推理性能（低方差）|
| G | Issue #842 | Sleeping mode（on-demand MR）| 训练内存 |
| H | Issue #709 | QP UDP source port（RoCEv2）| 非 EFA 目标 |
| I | Issue #671 | EP=24 stuck | 诊断未清 |
| J | Issue #581 | P2P intra-node 带宽 | intra-node，非 EFA 路径 |
| K | Issue #575 | Faster scattered copy kernel | 计算 kernel 优化 |
| L | Issue #895 深挖 | Proxy pthread + `pthread_atfork` 清理 | 和 B 合并 |

---

## 2. 三原则打分

| # | 端到端闭环 | 客户痛点 | AWS 可验证 | 实现复杂度 | 综合 |
|---|---|---|---|---|---|
| **A** | ✅ UCCL 内 | ✅ #893 明确要求 | ✅ p5en Stage5 已配 | 低（GPU 端需由 host 传参）| **强** |
| **B** | ✅ 一行 + atfork | ✅ 用户给了完整根因 | ✅ fork 测试即可复现 | 低 | **强** |
| **C** | ✅ buffer.py + cc | ✅ SGLang 推理直接报错 | ✅ p5en + SGLang | 中（语义要厘清）| **强** |
| D | ✅ UCCL 内 | ⚠️ 20h 才触发 | ⚠️ 长稳成本高 | 高（改 wire imm 格式）| 弱 |
| E | ⚠️ 需 SGLang 协同 | ⚠️ 无 open issue | ✅ | 中-高 | 中（待 SGLang API）|
| F | ✅ UCCL 内 | ⚠️ 无 open issue | ✅ | 中 | 中 |
| G | ⚠️ 设计复杂 | ⚠️ 单个用户 | ⚠️ 内存压测需 Kimi-K2 | 高 | 弱 |
| H | ✅ | ❌ EFA 不走 UDP | ❌ | — | 丢弃 |
| I | ⚠️ 根因未清 | ✅ | ✅ 但要先复现 | 未知 | 观望 |
| J | ✅ | ⚠️ 非 EFA 路径 | ⚠️ | 中 | 弱（非 EFA）|
| K | ✅ | ⚠️ 无明确请求 | ✅ | 中 | 中 |
| L | 并入 B | 并入 B | 并入 B | — | 并入 B |

---

## 3. Shortlist（按优先级）

### P1-a：Issue #901 — `internode_prepare` `previous_event=None` 硬编码（**首选**）

**为什么排第一**：
- 直接命中"SGLang + UCCL-EP + AWS EFA"目标三元组
- 两个独立用户在两个独立场景（#893 训练 / #901 推理）都被它炸
- #893 作者已把 patch 写出来并 offer 分享，我们只要把它规整进主线
- 根因+修复定位都清晰，不需要 reverse-engineer

**根因定位**（已验证）：
- `ep/deep_ep_wrapper/deep_ep/buffer.py:1495` `internode_prepare` 调用里 `previous_event` 参数位硬编码为 `False`（第 1519 行）
- `ep/src/uccl_ep.cc` 里 `intranode_dispatch`、`internode_dispatch` 等函数 `if (previous_event.has_value()) stream_wait(...) else stream_wait(comm, compute)`——C++ 层逻辑其实是正确的 fallback
- 但 Python 端的 wrapper 有一个 assert（buffer.py:766）`assert previous_event is not None and async_finish`——当调用者（Megatron `MoEFlexTokenDispatcher`、SGLang DP attention 路径）传 `allocate_on_comm_stream=True` 但 `previous_event=None` 时就炸
- 这是 DeepEP 原上游留下的前置条件，UCCL-EP 没有放宽

**设计草案**（待和维护者对齐）：
1. 放宽 Python 端 assert：`allocate_on_comm_stream=True` 时如果 `previous_event=None`，自动创建一个 `EventOverlap`（对应 compute stream 的 event）而不是要求调用者提供
2. 或者改为 warn + 自动 fallback 到 non-comm-stream 分配
3. 同步加回归测试：`pytest ep/tests/test_dispatch_comm_stream.py` 两条路径都跑

**风险**：
- 需要理解 DeepEP 原上游做该断言的动机，避免引入竞态
- 要在 p5en 上跑 `test_internode.py --num-tokens=4096` 确认没性能回归

**AWS 验证**：
- 正例：SGLang `launch_server --moe-a2a-backend deepep --enable-dp-attention` Qwen3-30B 能起来
- 回归：`test_internode.py` BW 和当前一致
- 性能：dispatch/combine BW 在 p5en 实测，和 PR body 一并贴出

**预估工作量**：2 天（1 天读懂 allocate_on_comm_stream 语义 + 1 天写测试+跑 AWS benchmark）

---

### P1-b：Issue #895 — `ibv_fork_init` + `pthread_atfork`

**为什么排第二**：
- 用户 `zhenhuang12` 写了一个非常详尽的根因分析（4 个 fork 危险源，每个都指向具体代码路径）
- 用户明确表示愿意提 PR，但建议"先和上游对齐方向"——正好是我们可以快速 align 并推进的机会
- 仓库全局 `ibv_fork_init` 匹配为 **0**——一行 API 调用就能治掉第一个危险源

**根因定位**：
1. `ep/src/uccl_proxy.cpp` / `ep/src/uccl_ep.cc` 启动 CPU proxy pthread 后 fork 会丢线程
2. `ibv_reg_mr*` 用了 `MADV_DONTFORK`（libibverbs 默认）——无 `ibv_fork_init()` 就在 child 触发 UB
3. CUDA IPC 不 fork-safe（UCCL 不能修，文档即可）
4. `/dev/shm/uccl_barrier_*` 会被 child race（要么 `pthread_atfork` 重置，要么 `O_EXCL + getpid`）

**设计草案**：
1. `ep/src/uccl_proxy.cpp::Proxy::start_dual()` 入口第一行加 `ibv_fork_init()` 调用（幂等+线程安全）
2. `ep/src/uccl_ep.cc::Buffer::Buffer()` 注册 `pthread_atfork` hook，在 child 侧 `throw_after_fork()`（清楚的错误信息而不是 SIGSEGV）
3. `README.md` 加一段 "Fork warning: set `DataLoader(multiprocessing_context='forkserver')`"——和代码修复一起提交
4. 加测试：`ep/tests/test_fork_safety.py`，`os.fork()` child 里 try 访问 buffer，预期 `RuntimeError`

**风险**：低。`ibv_fork_init()` 是 10 年前就存在的 API，没有已知副作用。

**AWS 验证**：
- 反例：现在 Megatron `num_workers=4` 随机 SIGSEGV → 修后报清楚错（或正常起来）
- 回归：pytest 全跑

**预估工作量**：1.5 天

---

### P1-c：Issue #893 后半段 — GPU `NUM_TIMEOUT_CYCLES` 运行时开关（PR #904 的自然 follow-up）

**为什么排第三**：
- PR #904 刚 open，follow-up 逻辑连续，维护者已进入这个知识域
- **前提**：PR #904 被 merge 或明确方向（否则两个 PR 审起来互相干扰）
- GPU 端比 CPU 端棘手：`NUM_TIMEOUT_CYCLES` 不能在 kernel 里读 env，必须 host 侧读好通过 kernel launch 参数传进去

**根因定位**：
- `ep/include/ep_configs.cuh` 定义 `NUM_TIMEOUT_CYCLES`（基于 `kDefaultGPUClock` + `NUM_CPU_TIMEOUT_SECS`）
- 使用点在 `ep/src/internode_ll.cu`、`ep/src/internode.cu` kernel 内
- 需要：host 端读 env → kernel 新参数 `uint64_t timeout_cycles` → 替换硬编码

**设计草案**：
1. 在 `common.hpp` 里扩展 `get_cpu_timeout_secs()`（PR #904 新增的）或新增 `get_gpu_timeout_cycles()`
2. 修改 `uccl_ep.cc` 里两个 dispatch kernel launcher，把 timeout 作为 `extra` arg 传入
3. kernel signature 加 `uint64_t timeout_cycles_arg`，替换 `NUM_TIMEOUT_CYCLES` 使用点
4. 同一个 env `UCCL_EP_CPU_TIMEOUT_SECS` 控制 GPU 侧（保持单一 knob）或新增 `UCCL_EP_GPU_TIMEOUT_SECS`——维护者决定

**风险**：中。改动触及 kernel 参数表，需要谨慎做 ABI 检查。

**AWS 验证**：
- 复现 #893 的训练步 100+ 触发 `dispatch CPU timeout`
- 设置 `UCCL_EP_CPU_TIMEOUT_SECS=600`（复用 PR #904 knob）后看 GPU 端也跟着放宽

**预估工作量**：2.5 天（含 CI 多配置验证）

---

## 4. 不推荐的候选（理由）

- **D（#684 duplicate seq 4）**：4-bit → 6-bit 扩展涉及 `kReorderingBufferSize=16` 和 imm 位分配，wire-protocol 改动；风险/收益比不合适，且长稳 20h 我们成本太高。
- **E（P1 dispatch per-expert release）**：必须 SGLang 那边也接受同一 API；在 SGLang 维护者未明确接口前不适合"设计清晰即可提交"标准。
- **G（#842 sleeping mode）**：单个用户请求，且与我们推理目标无关。
- **H（#709 UDP source port）**：EFA SRD 不走 UDP，对我们零收益。
- **I（#671 EP=24 stuck）**：根因未清，需要先复现再判断，现在不能给出设计草案。
- **J（#581 intra-node P2P）**：非 EFA 路径。
- **K（#575 scattered copy）**：需要 profile 才知道是不是 bottleneck，先不投。

---

## 5. 建议执行顺序

```
[Now]           开 P1-a (#901 previous_event hardcoded)          2 d
                └─ 等 PR #904 review 期间，并行推进

[PR #904 feedback] 追加 README 更新作为单独 commit        0.5 d
                └─ 维护者明确 API 后

[PR #904 merged]   开 P1-b (#895 ibv_fork_init)                  1.5 d
                └─ 和 #895 reporter 协调：我们做 C 语言端，他做 Primus 端

[P1-a merged]     开 P1-c (#893 GPU timeout follow-up)           2.5 d
                └─ 利用同一路径（uccl_ep.cc timeout helper）
```

---

## 6. 等待用户决策的问题

1. **先做 P1-a（SGLang/推理场景）还是 P1-b（fork/训练场景）？**
   我倾向 P1-a：更贴我们"SGLang+EFA decode 延迟"目标；但 P1-b 更小、更快出结果、对 #895 作者是正反馈。

2. **要不要在开下一个 PR 前先等 PR #904 review？**
   倾向等 1-2 天。如果 MaoZiming/YangZhou1997 给出 feedback（比如 env 命名、warning 策略），这些都能平移到 P1-c。

3. **P1-a 的 "放宽 assert 自动 fallback" vs "要求调用者提供 event" 路线选哪个？**
   需要读一遍 DeepEP upstream PR 历史看当初为什么加 assert（是为了抓某个具体 bug 还是 API 洁癖）再定。
