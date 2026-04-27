# Henan Mooncake EFA vs NVIDIA NIXL 交叉比对

**编写日期**：2026-04-26
**目的**：判定王鹤男（whn09）的 5 个 Mooncake EFA PR 是否参考 / 抄袭了 NVIDIA NIXL 的 libfabric 实现
**比对代码基**：
- NIXL HEAD：`/tmp/nixl`（src/plugins/libfabric + src/utils/libfabric，共 8517 LOC）
- Mooncake HEAD `634b7097`：`/tmp/Mooncake/mooncake-transfer-engine/{src,include}/transport/efa_transport/`（共 2770 LOC）

---

## 0. TL;DR

| 项 | 结论 |
|---|---|
| **判定档** | **独立平行开发（Independent parallel development）**，含少量"事后追赶"痕迹 |
| **证据等级** | 高（多处强反证，0 处直接抄袭证据） |
| **NIXL 提及次数** | 整个 Mooncake 仓库、全部 5 个 PR 描述、所有 review comments 中 = **0** |
| **独家符号复用** | 0（NIXL_LIBFABRIC_* 常量、progressActiveRails、railManager 等命名在 Mooncake 无一出现） |
| **选型冲突** | 4 个关键轴上做了**相反**选择（threading / 默认 striping / CQ batch / 默认值） |
| **撞车（独立发现的共同最佳实践）** | 3 项：FI_EP_RDM、FI_MR_HMEM for GPU、shared endpoint |
| **明显遗漏（NIXL 有 Henan 没有）** | 2 项：FI_OPT_EFA_RNR_RETRY、FI_OPT_EFA_USE_UNSOLICITED_WRITE_RECV |

**最强证据支持什么结论**：
1. Mooncake #1509 (2026-02-08) 上线时用的是 per-peer `fid_ep` 架构，**两个半月后 #1944 (2026-04-23) 才重构为 shared endpoint**。如果 Henan 参考了 NIXL，绝不可能错过 NIXL 从 2025-09 起就有的 shared endpoint 设计，尤其当 EFA SRD 是 connectionless、NIXL 已经把 QP 爆炸问题解决这件事在 NIXL README 里点名提过。
2. Mooncake **完全没设** `FI_OPT_EFA_RNR_RETRY`、`FI_OPT_EFA_USE_UNSOLICITED_WRITE_RECV` 两个 EFA provider 独家 opt，NIXL 从 2025-11～12 就有。任何抄 NIXL 的人会把 `libfabric_rail.cpp:527-557` 这段原样搬走。
3. Mooncake 文档 `efa_transport.md`、所有 PR 描述、所有 review discussion 中**没有一次提到 NIXL / Dynamo / ai-dynamo**；同时没有任何 NIXL 独家命名出现在 Mooncake 代码里。

---

## 1. 时间线

| 日期 | NIXL 事件 | Mooncake 事件 | 时间差 |
|---|---|---|---|
| 2025-09-16 | PR #784 libfabric 插件首发（commit `7f078cd`） | — | — |
| 2025-09～10 | 密集补丁 #809/#817/#826/#831/#833/#839/#856/#859/#860 | — | — |
| 2025-11 | PR #1084 (unsolicited off)、#960 (fi_mr_regattr) | — | — |
| 2025-12 | PR #1142/#1149/#1207 RNR retry | — | — |
| 2026-01～02 | PR #1272/#1302 线程性能 | — | — |
| **2026-02-08** | — | **#1509 首个 EFA PR merge**（commit `4136d2b`） | **NIXL 早 4 个月 23 天** |
| 2026-03 | PR #1386/#1433/#1451/#1462 | — | — |
| 2026-04-17 | — | #1821 fi_read + LRU + striping | NIXL 早 7 个月 |
| 2026-04-20 | — | #1912 auto-split MR | — |
| 2026-04-23 | — | **#1944 shared-endpoint 重构** | NIXL 早 7 个月 7 天 |

**窗口判断**：NIXL 代码公开时间比 Mooncake 早 5 个月。窗口足够大，Henan **理论上**能抄，但是否抄了看下面 7 点证据。

---

## 2. 7 个技术点逐个对照

### 技术点 1：shared endpoint（per-NIC 而非 per-peer）

#### NIXL 实现
- `src/utils/libfabric/libfabric_rail.cpp:499-510`（2025-09-16）：一开始就 per-NIC 一个 `fi_endpoint`，peers 通过 `fi_av_insert` 落到 AV，由 `fi_addr_t` 寻址。
- README line 11: "Scalable Connection Management: Efficient multi-agent connectivity with robust state tracking" — 明确指 shared endpoint 能力。

#### Mooncake 实现
- **#1509 (2026-02-08) commit `4136d2b` `efa_endpoint.cpp:61-97`**：每个 `EfaEndPoint` 对象自己 `fi_endpoint(...) → fi_ep_bind(av) → fi_enable`，即 **per-(NIC, peer)**。16 NIC × 48 peer = 768 QP 就是架构上线。
- **#1944 (2026-04-23) commit `634b709`** 才重构成 shared：
  - `efa_context.h:64`: "Key design point (SRD shared-endpoint model): there is exactly ONE fid_ep..."
  - `efa_context.cpp:184-253`: `shared_ep_` 单一 ep，所有 peer 走 AV lookup。

#### 相似度判定
- **结论：独立平行开发，Henan 事后追赶**
- **证据等级：高**。如果 Henan 2026-02 就在读 NIXL，不可能漏掉 NIXL 2025-09 首版就实现的 shared endpoint 设计。两个半月后自己撞痛才重构，说明当时没看。
- **反证方向**：#1944 作者 PR body 原文："Under SRD the previous model created one `fid_ep` per `(local NIC, peer)` pair... Since SRD is connectionless, a single shared endpoint can serve every peer via `fi_av_insert`" — 这是自己踩坑后总结的洞察，措辞从"发现"出发，不是"借鉴"出发。

---

### 技术点 2：`FI_MR_HMEM` / CUDA memory registration

#### NIXL 实现
- `libfabric_rail.cpp:426`（PR #784，2025-09-16 首发就有）：`FI_MR_LOCAL | FI_MR_HMEM | FI_MR_VIRT_ADDR | FI_MR_ALLOCATED | FI_MR_PROV_KEY`
- PR #960 (2025-11) 进一步切到 `fi_mr_regattr`（走 attr struct 传 iface + device）。

#### Mooncake 实现
- **#1509 (2026-02-08) 首发时没有 HMEM**，只有 `fi_mr_reg(domain_, addr, length, fi_access, 0, 0, 0, &mrMeta.mr, NULL)`（`efa_context.cpp:277`）—— iface 默认 `FI_HMEM_SYSTEM`，GPU memory 注册会失败或走 staging。
- **#1821 (2026-04-17)** 才补齐 `FI_MR_HMEM` 到 `mr_mode`（`efa_context.cpp:87`）+ `fi_mr_regattr` with explicit iface（line 357-368）。

#### 相似度判定
- **结论：独立平行开发，Henan 滞后 7 个月追赶**
- **证据等级：高**。如果抄了 NIXL，#1509 首发就该有 HMEM；反而是到 #1821 才补齐说明 Henan 在 #1509 完全不知道 HMEM 这条路。
- 特别注意：Mooncake 注释 `efa_context.cpp:333-335`："The EFA provider's fi_mr_reg() hardcodes iface=FI_HMEM_SYSTEM, so GPU memory must go through fi_mr_regattr() with explicit..." —— 这个经验性陈述是作者自己总结的，不是 NIXL 里能复制的。

---

### 技术点 3：`fi_read` 支持（双向 RMA）

#### NIXL 实现
- PR #784 (2025-09) 首版就有双向 `fi_read / fi_write`，`libfabric_rail.cpp` 的 `postWrite/postRead` 对称。

#### Mooncake 实现
- #1509 首发只支持 `fi_write`（单向 PUT）。
- #1821 (2026-04-17) 才加 `fi_read`。`efa_context.cpp:807`: `fi_read(shared_ep_, ...)` 是后补进去的。

#### 相似度判定
- **结论：独立平行开发**
- **证据等级：中**。`fi_read` 是 libfabric RDM 标准 API，"加上 fi_read 支持"是任何 transport 自然演进的方向；NIXL 先做 + Mooncake 滞后做并不构成借鉴证据。
- 真正的借鉴证据得在**参数/错误处理/batching 细节**上重合，下面点 7 详查。

---

### 技术点 4：Striping threshold（multi-NIC split）

#### NIXL 实现
- `src/utils/libfabric/libfabric_common.h:42`:
  ```cpp
  #define NIXL_LIBFABRIC_DEFAULT_STRIPING_THRESHOLD (128 * 1024) // 128KB
  ```
- PR #784 首版常量。

#### Mooncake 实现
- **#1821 默认值 = 2 MB**（commit `a6cbc1a` diff 第 947 行）：
  ```cpp
  size_t efa_striping_threshold = 2 * 1024 * 1024;  // 2MB default
  ```
- #1944 (2026-04-23) 实测 >2 MB 时 striping 是 20× **负优化**（16 GB/s vs 366 GB/s），**直接 revert 这个 knob**。

#### 相似度判定
- **结论：独立平行开发，且判定不同**
- **证据等级：高**。默认值差了 **16 倍**（128 KB vs 2 MB），如果抄 NIXL 应该直接用 128 KB。而且 Henan 用 `GlobalConfig` 存配置 + `MC_EFA_STRIPING_THRESHOLD` env 前缀，NIXL 用 `NIXL_LIBFABRIC_*`；两者命名/存储完全独立。
- **补充反证**：Henan 在 #1944 把 striping 完全 **revert**（"1.2× 在设计场景，20× 负优化在真实场景"），NIXL 的 striping 仍然是核心 feature；如果 Henan 抄 NIXL 不会做得相反。

---

### 技术点 5：`FI_OPT_EFA_RNR_RETRY=7`（重要的 EFA 特殊 opt）

#### NIXL 实现
- `libfabric_rail.cpp:546-557`：
  ```cpp
  size_t rnr_retry = 7; // EFA_RNR_INFINITE_RETRY
  ret = fi_setopt(&endpoint->fid, FI_OPT_ENDPOINT,
                  FI_OPT_EFA_RNR_RETRY, &rnr_retry, sizeof(rnr_retry));
  ```
- 来自 PR #1207 (2025-12)。

#### Mooncake 实现
- **全 EFA transport 代码 + tests + docs：0 次出现** `FI_OPT_EFA_RNR_RETRY`、`rnr_retry`、`RNR` 任何字样。
- ```grep -rn "FI_OPT_EFA_RNR_RETRY\|rnr_retry\|RNR" /tmp/Mooncake/mooncake-transfer-engine/``` 空。

#### 相似度判定
- **结论：Henan 完全没用这个 NIXL lever —— 反证独立开发**
- **证据等级：很高**。这是 EFA 专有 opt，NIXL 代码公开 5 个月，任何读过 NIXL 的人都会复制这段（就 12 行）。Henan 完全没有，说明没读过 / 没抄过。
- **实操含义**：在高压力长尾场景下 EFA 默认 RNR 重试次数有限，Mooncake 仍然会被 `FI_ENORX` 打出 EAGAIN 然后走软件层 retry_slices —— 这是 Mooncake 可补的一个 NIXL 采纳了但它没有的 lever（建议加入 HENAN_PR_QUALITY_REVIEW 的 follow-up P2 清单）。

---

### 技术点 6：`FI_OPT_EFA_USE_UNSOLICITED_WRITE_RECV`（CQ overflow 防护）

#### NIXL 实现
- `src/utils/libfabric/meson.build:53-60`：build 时检测 libfabric 是否支持这个 opt，定义 `-DHAVE_FI_OPT_EFA_USE_UNSOLICITED_WRITE_RECV`。
- `libfabric_rail.cpp:527-544`：运行时条件编译设 false（PR #1084, 2025-11）。

#### Mooncake 实现
- **全代码库 0 次出现** `FI_OPT_EFA_USE_UNSOLICITED_WRITE_RECV`、`unsolicited`。

#### 相似度判定
- **结论：Henan 没用 —— 反证独立开发**
- **证据等级：很高**。和技术点 5 同理。NIXL 甚至做了 meson feature detect，Henan 完全缺这套。
- **实操含义**：Mooncake CQ 在极端 batch 场景下可能踩到 unsolicited recv overflow，但 Henan 的 `kPollBatchSize=64` + worker thread-per-context 模型可能把风险摊平。需要 p5en 压测验证。

---

### 技术点 7：进度线程 + batch CQ read 模式

#### NIXL 实现
- `libfabric_rail.cpp:435`：
  ```cpp
  hints->domain_attr->threading = FI_THREAD_COMPLETION;
  ```
  每个 CQ 独立线程可读，avoid 全局锁。
- `libfabric_common.h:93`：`NIXL_LIBFABRIC_CQ_BATCH_SIZE 16`
- `libfabric_rail.cpp:717-726`：`fi_cq_read(cq, completions, NIXL_LIBFABRIC_CQ_BATCH_SIZE)` 一次读 16。
- 有可选的 background progress thread (`progress_thread_enabled_`)。

#### Mooncake 实现
- `efa_context.cpp:90`：
  ```cpp
  hints_->domain_attr->threading = FI_THREAD_SAFE;
  ```
  全 domain 锁（保守）。
- `efa_transport.cpp:131`：`const int kPollBatchSize = 64;`（硬编码，不可配）
- `efa_context.cpp:865-868`：
  ```cpp
  struct fi_cq_data_entry entries[64];
  int to_poll = std::min(max_entries, 64);
  ssize_t ret = fi_cq_read(cq, entries, to_poll);
  ```
- `efa_transport.cpp:108-113`：一个 context 一个 worker thread 持续 pollCq，类似 NIXL 的 progress thread 但实现更简单。

#### 相似度判定
- **结论：独立平行开发，判定相反**
- **证据等级：高**。
  - threading 选择**完全相反**：NIXL 用 COMPLETION（per-CQ, 性能优先），Mooncake 用 SAFE（全 domain 锁, 简单优先）。
  - CQ batch size：NIXL **16**，Mooncake **64**，没撞数字，没有任何共享常量名。
  - 任何抄 NIXL 的人会直接把 `FI_THREAD_COMPLETION` 搬走，因为"per-CQ 线程"是多 rail 场景的标准做法。Henan 选 SAFE 明显是自己根据简化目标做的决定。

---

## 3. 代码 / 注释 / 文档相似度证据

### 3.1 明显相似的地方（0 处直接抄袭）

| 维度 | 是否相似 | 备注 |
|---|---|---|
| 独家常量名（NIXL_LIBFABRIC_*） | ❌ 无一出现 | grep `/tmp/Mooncake` 整库 0 命中 |
| 独家类名（railManager / progressActiveRails / prepareAndSubmitTransfer） | ❌ 无一出现 | grep 0 命中 |
| NIXL 独家注释措辞（"EFA_RNR_INFINITE_RETRY" 等 inline comment） | ❌ 无一复用 | |
| README 表格结构 | ❌ 完全不同 | Mooncake 用 `docs/source/design/transfer-engine/efa_transport.md`，结构/示例 AWS-centric，NIXL 用 meson + `NIXL_LIBFABRIC_MAX_BW_PER_DRAM_SEG` 体系 |
| PR 描述提到 NIXL / Dynamo | ❌ 0 次 | 5 个 PR body + 所有 review comments 零提及 |

### 3.2 "撞车"的地方（两者独立想出了共同最佳实践）

| 共识点 | 为什么会撞车 | 是否能反推抄袭 |
|---|---|---|
| `FI_EP_RDM` endpoint type | EFA 不支持 `FI_EP_MSG` QP API，这是 libfabric 文档级强制 | 不能 |
| `FI_MR_HMEM` for GPU | GPUDirect on EFA 的标配 flag，libfabric 文档明写 | 不能 |
| shared endpoint 架构 | SRD connectionless 属性下的正确设计；Mooncake 用了 2.5 个月才想到，反而证明不是抄的 | 不能 |

### 3.3 明显不同的地方（技术选型/默认值冲突）

| 维度 | NIXL | Mooncake | 冲突级别 |
|---|---|---|---|
| domain threading | `FI_THREAD_COMPLETION` | `FI_THREAD_SAFE` | 哲学相反 |
| CQ batch size | 16 | 64 | 4 倍 |
| Striping threshold 默认 | 128 KB | 2 MB（已 revert） | 16 倍 + 方向相反 |
| `FI_OPT_EFA_RNR_RETRY` | 7（infinite） | 未设置 | 缺失 |
| `FI_OPT_EFA_USE_UNSOLICITED_WRITE_RECV` | 显式设 false | 未设置 | 缺失 |
| 初版 endpoint 模型 | shared from day 1 | per-peer 首版，2.5 个月后 refactor | 代际差距 |
| Env var 前缀 | `NIXL_LIBFABRIC_*` | `MC_EFA_*` | 独立体系 |
| MR 结构 | `unordered_map` | `std::map + upper_bound`（#1821 特意换的） | 独立决策 |

---

## 4. Henan PR discussion 里对 NIXL 的提及

用 `gh pr view {1509, 1523, 1821, 1912, 1944} --repo kvcache-ai/Mooncake --comments` 逐个扫，grep `nixl | nvidia | dynamo | ai-dynamo`：
- **全部 0 命中**
- 同样扫 5 个 PR body：**0 命中**
- 同样扫 Mooncake 整库（tests / docs / source）：**0 命中**（只有 `--runtime=nvidia --gpus all` 这种 docker 命令的 "nvidia" 字样）

---

## 5. 最终判定

### 档位：**独立平行开发（Independent parallel development）**

### 理由（按证据权重排序）
1. **反证权重最高**：Mooncake 缺 `FI_OPT_EFA_RNR_RETRY` + `FI_OPT_EFA_USE_UNSOLICITED_WRITE_RECV`（技术点 5、6）。这是 NIXL 2025-11~12 就做的 EFA 专有 opt，代码总共 ~20 行，任何参考 NIXL 的人会直接搬；Henan 完全没有。
2. **架构代际差反证**：Mooncake #1509 首发 per-peer endpoint，2.5 个月后 #1944 才自己撞痛重构；NIXL 2025-09 首版就 shared endpoint。如果 Henan 参考 NIXL，没有任何理由选错路径 2.5 个月。
3. **默认值/选型方向相反**：threading COMPLETION vs SAFE、striping 128 KB vs 2 MB、CQ batch 16 vs 64 —— 4 个关键轴上的独立决策。
4. **零命名/注释复用**：NIXL 独家符号（`NIXL_LIBFABRIC_*` / `progressActiveRails` / `railManager`）在 Mooncake 没有一次出现。
5. **零社交信号**：5 个 PR 合计 ~7k+ 行的 diff，全部 PR body + review + docs 0 次提 NIXL/Dynamo。

### 不确定部分
- Henan 可能在**设计阶段**粗扫过 NIXL README（这是工程师常见行为），但从代码上看没有留下任何直接痕迹。
- 无法完全排除"看过但故意不用 NIXL 的 lever"的可能，但结合 #1821/#1944 展示的"自己踩坑自己总结"的行为 pattern，这种可能性很低。

---

## 6. 对我们的意义

### 6.1 如果 Henan 没抄 NIXL，那 Henan 独立想出的共识点是可靠的
- `FI_EP_RDM` ✓
- `FI_MR_HMEM` + `fi_mr_regattr` for GPU ✓
- shared endpoint for SRD ✓
- `fi_read + fi_write` 对称 ✓
- multi-rail striping（虽然阈值选型不同）✓

**这些是 UCCL-EP on EFA 设计时应当照搬的共识**（无需再独立验证）。

### 6.2 Henan **没采纳**的 NIXL lever，我们可以考虑的

| NIXL lever | Mooncake 无 | 我们 UCCL-EP 要不要? |
|---|---|---|
| `FI_OPT_EFA_RNR_RETRY=7` | ✓ 无 | **强烈建议用**：对 SGLang / vLLM 长尾 tail request 有用；代码 10 行 |
| `FI_OPT_EFA_USE_UNSOLICITED_WRITE_RECV=false` | ✓ 无 | **建议用**：高 batch 下防 CQ overflow，有条件编译保护 |
| `FI_THREAD_COMPLETION`（而非 SAFE） | ✓ Mooncake 用 SAFE | **建议用**：多 rail 场景性能会好，代价是 domain-level invariant 要自己守 |
| CQ batch 16（而非 64） | ✓ Mooncake 用 64 | 不明显。Mooncake 64 在 64 深 WR 场景可能更好；值得实测 |

### 6.3 反过来 Henan 做了 NIXL 没做的

| Henan lever | NIXL 无 | 说明 |
|---|---|---|
| PTE-aware auto-split MR（#1912） | ✓ NIXL 无 | EFA NIC PTE 24M 限制下的大 MR 切分，NIXL 没处理到 1500 GB 级别 buffer |
| `efa_first_submit_probe.cpp` 冷启动 bench 工具 | ✓ NIXL 无 | 测试基础设施做得比 NIXL 还细 |

**说明 Henan 在特定 use case（超大 KV pool）上领先 NIXL**。UCCL-EP 如果要做 inference 场景，PTE-aware MR 是 Mooncake 独家原创的 pattern，可以借鉴 Mooncake 而非 NIXL。

### 6.4 最终执行建议

1. **不要假设 Mooncake ≈ NIXL 的 EFA 子集**。两者是独立实现，且选型在 4+ 个关键维度上相反。
2. **UCCL-EP 要做 EFA 时应两边都参考**：
   - NIXL：threading model、RNR / unsolicited opts、striping 早期判定（128 KB）
   - Mooncake：PTE-aware MR、冷启动诊断工具、shared endpoint 的后端简化（teardown / AV 管理）
3. **Mooncake 可补的 P2 follow-up 明确增加一项**：引入 `FI_OPT_EFA_RNR_RETRY=7` + `FI_OPT_EFA_USE_UNSOLICITED_WRITE_RECV=false`（条件编译）。这两个小 lever 我们可以替 Henan 发 PR（10 行代码 + p5en 压测数据）。

---

## 附录 A：核查命令（可复现）

```bash
# 时间线
git -C /tmp/nixl log --reverse --oneline -- "**/libfabric*" | head
git -C /tmp/Mooncake log --oneline -- mooncake-transfer-engine/src/transport/efa_transport/

# NIXL 独家符号在 Mooncake 是否存在
grep -rn "NIXL_LIBFABRIC\|progressActiveRails\|railManager\|prepareAndSubmitTransfer" /tmp/Mooncake/

# EFA 专有 opt
grep -rn "FI_OPT_EFA_RNR_RETRY\|FI_OPT_EFA_USE_UNSOLICITED_WRITE_RECV" /tmp/Mooncake/mooncake-transfer-engine/
grep -rn "FI_OPT_EFA_RNR_RETRY\|FI_OPT_EFA_USE_UNSOLICITED_WRITE_RECV" /tmp/nixl/src/

# threading 模型
grep -n "FI_THREAD" /tmp/nixl/src/utils/libfabric/libfabric_rail.cpp
grep -n "FI_THREAD" /tmp/Mooncake/mooncake-transfer-engine/src/transport/efa_transport/efa_context.cpp

# CQ batch
grep "CQ_BATCH_SIZE\|kPollBatchSize" /tmp/nixl/src/utils/libfabric/libfabric_common.h /tmp/Mooncake/mooncake-transfer-engine/src/transport/efa_transport/efa_transport.cpp

# PR discussion
gh pr view 1509 --repo kvcache-ai/Mooncake --comments | grep -i "nixl\|dynamo"
gh pr view 1944 --repo kvcache-ai/Mooncake --comments | grep -i "nixl\|dynamo"
```
