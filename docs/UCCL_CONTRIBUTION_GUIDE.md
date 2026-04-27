# UCCL 项目贡献指南（实操版）

**日期**：2026-04-25
**目标**：在向 `uccl-project/uccl` 上游提交 UCCL-EP EFA 性能优化 PR 前，明确 merge 路径

---

## 1. 官方规则（来自仓库）

### 1.1 Pull Request 模板（`.github/PULL_REQUEST_TEMPLATE.md`）

每个 PR 必须包含：

```markdown
## Description
Please include a summary of the changes and the related issue.
Fixes # (issue)

## Type of Change
- [ ] Bug fix
- [ ] New feature
- [ ] Documentation update

## How Has This Been Tested?
- [ ] Unit tests
- [ ] Integration tests
- [ ] Manual testing

## Checklist
- [ ] I have run `format.sh` to follow the style guidelines.
- [ ] I have run `build.sh` to verify compilation.
- [ ] I have removed redundant variables and comments.
- [ ] I have updated the documentation.
- [ ] I have added tests.
```

### 1.2 代码格式要求

**C++ / CUDA**：
- 工具：**clang-format 14**（CI 严格检查，`.github/workflows/clang-format-check.yml`）
- 配置：`.clang-format` 基于 Google Style + 定制
  - `DerivePointerAlignment: false`, `PointerAlignment: Left` → 写 `int& foo` 不是 `int &foo`
  - `QualifierAlignment: Right` → 写 `int const*` 不是 `const int*`
  - `IncludeBlocks: Merge`
- 检查目录：`collective/`, `ep/`, `experimental/`, `p2p/`, `include/`
- 排除：`collective/afxdp/lib`, `experimental/lite/thirdparty`
- 扩展名：`cpp, cxx, cc, h, hpp, cu, cuh`
- 运行方式：
  ```bash
  # 本地格式化
  ./format.sh
  
  # CI 会严格 dry-run：
  clang-format --dry-run --Werror <files>
  ```

**Python**：
- 工具：**black**
- 检查目录：`p2p/`, `ep/`
- 排除：`thirdparty|docs|build`
- 运行方式：`black ep/ --exclude "thirdparty|docs|build" --check`

### 1.3 构建验证

- 脚本：`build.sh`（顶层）
  ```bash
  bash build.sh [cu12|cu13|roc7|roc6|therock] [all|ccl_rdma|ccl_efa|p2p|ep] [py_version] --install
  ```
- 对 EP 的 EFA 改动：至少跑 `bash build.sh cu12 ep --install`

---

## 2. 真实 merge 流程（从近期 30 个 merged PR 归纳）

### 2.1 维护者结构

| 角色 | 代表人物 | 职能 |
|---|---|---|
| **Core maintainer / Primary merger** | `YangZhou1997` (Yang Zhou) | 70% PR 由他 merge；CI 最终 gatekeeper |
| **EP 模块 reviewer** | `MaoZiming` (Ziming Mao) | 几乎所有 EP PR 的 reviewer，EFA 专家 |
| **AMD / Collective** | `zhongjiechen` (Zhongjie Chen) | P2P + Collective 模块 |
| **P2P / ROCm** | `derekwin` | P2P 模块代码 |
| **AMD CI / Megatron** | `zhenhuang12` | AMD 集成，Megatron/Primus |
| **Intel RDMA** | `manojgop` | Intel RDMA NIC 相关 |

### 2.2 近期 merged PR 作者分布（最近 30 个）

- `YangZhou1997` × 10（内部）
- `derekwin` × 6（P2P 维护者）
- `zhongjiechen` × 4（内部）
- `DanielDanyang` × 3
- `MaoZiming` × 2
- **外部贡献者**：`whn09`, `Matt-Harvill`, `manojgop`, `praveingk`, `zhenhuang12` 各 1-3 个

**结论**：外部 PR 能进主线，但需要 reviewer 盯紧。

### 2.3 EP PR 的 review 流程样例

| PR | 作者 | Reviewer | 流程 |
|---|---|---|---|
| #898 (EP zero-token) | 外部 `Matt-Harvill` | `zhenhuang12` APPROVED | `zhenhuang12` 反复 comment → 作者多轮迭代 → approved → `YangZhou1997` merge |
| #766 (off13 overflow) | 外部 `whn09` | `MaoZiming` APPROVED | 6 个 commit 迭代，`MaoZiming` 审核 15 字 approval |
| #848 (NUMA-aware NIC) | 外部 `manojgop` | `MaoZiming` × 3 comments | 来回讨论后合入 |
| #737 (shared RDMA MR) | 外部 `manojgop` | `MaoZiming` approved | Intel 贡献路径，评审比较顺 |
| #892 (async event fix) | 内部 `zhenhuang12` | `YangZhou1997` approved | 内部 PR 流程快 |

**规律**：
1. **EP/EFA 相关 PR 必须过 `MaoZiming`**
2. Approval 可以很短（15 字）但必须有
3. 外部 PR 通常 1-3 轮迭代
4. Merge 动作几乎总是 `YangZhou1997`

### 2.4 Label 机制

| Label | 作用 | 是否必需 |
|---|---|---|
| `run-benchmark` | **触发 CI 跑 L4 / AMD / GB10 build+test** | **EP 改动必须加**，否则 CI 不会跑 |
| `bug` | 标注为 bug fix | 可选 |
| `enhancement` | 新功能 | 可选 |
| `documentation` | 仅文档 | 可选 |
| `WIP` | Work in progress | 作者自己加 |
| `wont-merge` | 标注不会合入（debug/experiment） | 维护者加 |
| `good first issue` | 新手友好 | 维护者加 |

**关键**：**对 EP 性能改动必须 request `run-benchmark` label**，否则 CI 不会在 L4 GPU 上跑 build+test，reviewer 也不会 merge。

### 2.5 CI 检查

PR 会触发以下检查（`.github/workflows/`）：

1. **`clang-format-check.yml`** — 每个 PR 必过（push + pull_request on main）
2. **`uccl-build-l4.yml`** — 只在带 `run-benchmark` 标签时跑
3. **`uccl-build-test-amd.yml`** — AMD GPU 测试，带 `run-benchmark` 触发
4. **`uccl-build-test-gb10.yml`** — GB10 NVIDIA Grace Hopper 测试
5. **`build-docker-images.yml`** — Docker 镜像构建
6. **`release.yml`** — 发布流程

**无 EFA CI**：项目没有 AWS p5en EFA 的 CI（UCCL 团队明确说"没有 AWS 机器"，见 issue #893 回复）。这对我们是利好，也是挑战：
- **利好**：我们在 EFA 上的实测数据会被 reviewer 视为权威
- **挑战**：我们需要自己提供完整 benchmark 数据

---

## 3. 我们的 PR 被 merge 的风险评估

### 3.1 P0（combine signal API）

**风险等级**：🟢 低

**merge 难度**：
- ✅ 完全是 API 补齐（DeepEP 原生已有，UCCL-EP 缺），reviewer 很难拒绝
- ✅ 新增参数，默认值保持现有行为，零 API 破坏
- ✅ 可引 SGLang `deepep.py:722-732` 作为客观证据
- ⚠️ 但 UCCL 团队没有 SGLang 测试，需要我们提供完整 decode latency 数据

**策略**：
1. 标题：`[EP] Add DeepEP-compatible src_signals API to low_latency_combine`
2. Body 明确引用：**Required by SGLang's CombineOverlapArgs integration**，SGLang 代码链接
3. 必测：`test_low_latency.py` 在 p5en 上跑 + signal 路径的单元测试
4. Label: `run-benchmark` + `enhancement`
5. 预期 reviewer: `MaoZiming` → `YangZhou1997` merge

### 3.2 P1（dispatch per-expert early release）

**风险等级**：🟡 中

**merge 难度**：
- ⚠️ 架构级改动，影响 `LowLatencyLayout`
- ⚠️ 新增 API，需要设计讨论
- ✅ 和 combine 侧已有机制对称，逻辑上好理解
- ⚠️ 需要展示下游（SGLang）消费这个 API 的完整链路

**策略**：
1. 先开 issue 讨论设计（参考 issue #842 的写法）
2. 拆成 **两个 PR**：
   - PR A: UCCL-EP 侧暴露 per-expert ready signal（纯 additive API）
   - PR B: 性能验证 + benchmark 数据
3. 先不改 SGLang 侧，保留 opt-in flag
4. 预期 reviewer: `MaoZiming` + `YangZhou1997`

### 3.3 P2（single-token fast path）

**风险等级**：🟢 低

**merge 难度**：
- ✅ 新增 kernel 路径，不改现有逻辑
- ✅ 明确的 use case：decode batch ≤ 8
- ✅ 上游有类似模式（PR #728 rank-batch coalescing）

**策略**：类似 P0，直接提交 + benchmark。

### 3.4 P4（Ctrl/Data QP 分离）

**风险等级**：🟡 中

**merge 难度**：
- ⚠️ 动 `ProxyCtx` 和 `rdma.cpp` 核心逻辑
- ⚠️ 对 RoCE / CX7 用户可能有影响
- ✅ 设计上清晰（模仿 ack_qp 分离）
- ✅ 解决已知痛点（inline data 被关、CQE poll 慢）

**策略**：
1. 必须覆盖非 EFA 路径（CX7）测试
2. 先在 `#ifdef EFA` 下开启，其他平台保持现状
3. 预期要 `manojgop` 或 `zhongjiechen` 一起看

### 3.5 P3（LL TBO 启用）

**风险等级**：🔴 高

**merge 难度**：
- ⚠️ 改 `Buffer` 状态机
- ⚠️ SGLang 侧也要改（跨仓库协调）
- ⚠️ 可能和 PR #728/#601 冲突
- ⚠️ UCCL 团队有自己的 TBO 计划

**策略**：**不优先做**。等 P0-P2 merge 后再评估。

---

## 4. 推荐 PR 提交顺序（优化 merge 概率）

### Phase 1：建立信任（第 1-2 周）

**先提小 bug fix / doc 改进，和维护者建立沟通**：
1. 若发现 bug（例如 issue #893 的 false timeout），提一个 4-5 行改动的 PR
2. 让 `MaoZiming` 熟悉我们的风格

### Phase 2：P0 正式投递（第 3-4 周）

**动作**：
1. 先在 `uccl-project/uccl` 开 **issue**：
   - 标题：`[EP] low_latency_combine missing src_signals API (needed by SGLang SBO)`
   - 内容：引用 SGLang 代码 + 说明 use case
2. 等 `MaoZiming` / `YangZhou1997` 回复确认 use case 合理
3. 提 PR：
   - 新增参数 default = 0/null，保持向后兼容
   - 完整 `test_low_latency.py` 扩展测试
   - p5en EP=32 benchmark：前后对比
4. 加 `run-benchmark` label 请求 + 附上 `clang-format --dry-run` 日志 + `build.sh cu12 ep` 通过日志

### Phase 3：P2 single-token fastpath（第 5-6 周）

独立 PR，类似流程。和 P0 无依赖。

### Phase 4：P1 per-expert early release（第 7-10 周）

拆成两个 PR：
- **PR A**（UCCL-EP）：暴露 API，opt-in，ehavior 默认不变
- **PR B**（SGLang）：消费 API，在 SGLang 侧单独 review

PR A 必须先过，PR B 才有意义。

### Phase 5：P4（第 11-14 周）

等前面有 merge 基础后再推进。

---

## 5. 被拒或返工的典型原因

从 GitHub 历史观察：

| 原因 | 示例 | 如何避免 |
|---|---|---|
| **格式不过** | 多个 PR 第一次 push CI fail | 本地先跑 `./format.sh` 和 `black ep/` |
| **没加 `run-benchmark` label** | PR 没有 L4/AMD 测试记录 | 提交时请求加 label |
| **性能 regression** | PR #741 导致 #752 regression | 必须附前后 benchmark 数据 |
| **破坏 API** | 多个 draft PR 未合 | 所有新参数 default 保持现有行为 |
| **无测试** | Matt-Harvill 的第一版 #898 | 先写单元测试再提 PR |
| **描述太简** | DRAFT PR 很多只有模板 | Body 必须详细：动机、设计、测试、benchmark |
| **跨模块改动** | PR #592 (大 refactor) 长期未合 | 拆小 PR，一次只改一个模块 |

---

## 6. 关键 reviewer 画像和沟通习惯

### 6.1 `MaoZiming`（EP/EFA 主审）
- **邮箱**：`ziming.mao@berkeley.edu`（issue #893 公开）
- **沟通**：直接在 PR 评论，approval 常常很短（15 字）
- **关注点**：EFA 特有的 seq / reordering buffer / inflight 正确性
- **偏好**：代码简洁，愿意接受新功能但要求清晰动机
- **痛点**：没有 AWS 测试环境 → 我们提供 benchmark 有价值

### 6.2 `YangZhou1997`（maintainer）
- **身份**：UC Berkeley Sky Lab，UCCL 创始人之一（OSDI 2026 paper 第一作者）
- **沟通**：接 review 后几小时内 merge
- **关注点**：整体架构一致性、breaking change、测试覆盖
- **偏好**：明确的 use case，实测数据说话

### 6.3 `zhongjiechen`（collective/p2p）
- **关注点**：RDMA 细节，协议正确性
- **偏好**：细致讨论设计

---

## 7. 沟通模板

### 7.1 Issue 开场（在提 PR 前）

```markdown
**Title**: [EP] low_latency_combine missing src_signals API (needed by SGLang SBO integration)

**Context**:
SGLang's `CombineOverlapArgs` (https://github.com/sgl-project/sglang/blob/main/python/sglang/srt/batch_overlap/single_batch_overlap.py#L62)
passes `src_signals` and `src_signal_expect_value` to `buffer.low_latency_combine(...)`
(https://github.com/sgl-project/sglang/blob/main/python/sglang/srt/layers/moe/token_dispatcher/deepep.py#L724).

Native DeepEP exposes these parameters, but UCCL-EP's `low_latency_combine` (uccl_ep.cc:1287)
does not — causing SGLang's combine↔down_gemm two-stream overlap path to be dead code
when running on AWS EFA.

**Proposed**:
Add `src_signals`, `src_signal_expect_value`, `overlap`, `num_sms` parameters to
`Buffer::low_latency_combine` mirroring DeepEP's native signature. Default values
preserve current behavior; SGLang enables the overlap path via `overlap=True`.

**Impact**:
- Unblocks SGLang SBO on EFA (decode latency -15-25% expected)
- Zero changes to existing UCCL-EP callers

Happy to submit PR. @MaoZiming @YangZhou1997 thoughts?
```

### 7.2 PR Body（在 Description 里填）

```markdown
## Description
Adds DeepEP-compatible `src_signals` / `src_signal_expect_value` / `overlap` / `num_sms`
parameters to `Buffer::low_latency_combine`, enabling SGLang's SBO combine↔down_gemm
two-stream overlap on AWS EFA.

Fixes # (issue number from Phase 2 step 1)

## Type of Change
- [x] Bug fix  (compat with SGLang)
- [x] New feature  (signal-based kernel path)
- [ ] Documentation update

## How Has This Been Tested?
- [x] Unit tests: new case in `ep/tests/test_combine_signal.cu` — verifies kernel waits
      on signal tensor before posting
- [x] Integration tests: `test_low_latency.py` on 4× p5en (32 GPUs) with `--use-signal`
- [x] Manual testing: SGLang DeepSeek-V3 decode benchmark, mean ITL -5~-8%, P99 ITL -6~-10%
      (anchored to SGLang PR #9660 H20 measurement + p5en post-PR #745 baseline; see
      `docs/EXPECTED_PERFORMANCE_GAINS.md`)

### Benchmark (to be filled with actual numbers; illustrative only)

| Config                             | Dispatch both p50 | Combine both p50 | Mean ITL |
|------------------------------------|-------------------|------------------|----------|
| baseline (post-PR #745, overlap=0) | 174.9 µs          | 326.7 µs         | X ms     |
| + this PR (overlap=1, num_sms=3)   | (expect ~same)    | ~300-305 µs      | X−5~8% ms|

Setup: 2× p5en.48xlarge (16 GPU, same AZ), DeepSeek-V3 FP8 or Kimi-K2, hidden=7168,
topk=8, num-experts=288, num-tokens=128, PER_EXPERT_BATCHING=1

## Checklist
- [x] I have run `format.sh` to follow the style guidelines.
- [x] I have run `build.sh cu12 ep --install` to verify compilation.
- [x] I have removed redundant variables and comments.
- [x] I have updated the documentation (ep/README.md section on low-latency API).
- [x] I have added tests.

/cc @MaoZiming @YangZhou1997
```

---

## 8. 最小可执行清单（这周就做）

### 本周内
1. ☐ 在 GitHub 上 fork `uccl-project/uccl` 到个人 / 团队账号
2. ☐ 本地 clone fork，添加 upstream remote
3. ☐ 在 `uccl-project/uccl` 开一个 low-stakes issue（例如 issue #893 的 timeout env var 建议）
4. ☐ 提一个 3-5 行的小 PR 作为首次贡献（例如给 issue #893 加 `UCCL_EP_TIMEOUT_SEC` env var）

### 下周内
5. ☐ 开 P0 issue，内容按上面模板写
6. ☐ 在 fork 上写 P0 实现，通过 `format.sh` + `build.sh cu12 ep`
7. ☐ Stage 5 R1 run 拿到 P0 的 benchmark 数据

### 两周内
8. ☐ 提 P0 PR，请求 `run-benchmark` label
9. ☐ 根据 MaoZiming review 迭代
10. ☐ Merged 后继续 P2 / P1

---

## 9. 如果 PR 被拒怎么办

### 9.1 风险场景

**场景 A：`MaoZiming` 说 "我们自己要做"**
- 处理：提供 benchmark 数据 + offer co-author
- Fallback：在 fork 上维护，等他们做完合回主线时 rebase

**场景 B：架构设计被要求重写**
- 处理：遵循 reviewer 意见，拆 PR
- 不要 push back 整体设计

**场景 C：长期没人 review（>2 周）**
- 温柔 ping：`@MaoZiming @YangZhou1997 friendly bump, any concerns on this PR?`
- 极端情况：在 issue tracker 开 meta-issue 说明 blocked

**场景 D：CI 失败**
- 不要强推 merge
- 必须修到绿，包括 format check

### 9.2 永远不做

- ❌ 不要 `git push --force` 到别人能看到的分支（除非自己的 fork branch）
- ❌ 不要跳过 `format.sh` 直接提
- ❌ 不要提混合了多个 concern 的大 PR（参考 draft PR #592 长期未合）
- ❌ 不要破坏 DeepEP API 兼容（上游明确这是核心承诺）

---

## 10. 相关资源

- **仓库**：https://github.com/uccl-project/uccl
- **PR template**：`.github/PULL_REQUEST_TEMPLATE.md`
- **Format**：`.clang-format`, `format.sh`, `pyproject.toml`
- **CI**：`.github/workflows/*.yml`
- **Build**：`build.sh`, `build_inner.sh`
- **论文**：
  - UCCL-Tran (OSDI 2026) — arxiv 2504.17307
  - UCCL-EP (OSDI 2026) — 见 README
- **Slack / Discord**：未公开，仅 GitHub Issues 交流

---

**文档维护**：每个 merged / rejected PR 后更新 Section 2 和 Section 5 的案例库。
