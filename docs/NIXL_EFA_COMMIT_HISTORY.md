# NIXL EFA Commit/PR 考古 — 可借鉴教训 (Agent N2)

**目标**：挖 NVIDIA NIXL 上游 commit log / PR / issue 里 EFA/AWS/libfabric 的"踩坑 → 修复"故事，以供 UCCL-EP 参考。
**取样仓库**：`https://github.com/ai-dynamo/nixl`（已 unshallow 到 895 个 commit）
**评估日期**：2026-04-26
**作者**：Agent N2（读 git log/PR body，N1 读代码）
**遵循纪律**：`feedback_claim_verification_discipline.md` / `feedback_commit_narrative_full_log.md` / `feedback_baseline_cross_hardware.md`

---

## 0. TL;DR

- **挖到 EFA 相关 PR**：~55 个（libfabric plugin 专属 PR）
- **挖到 EFA 相关 issue**：~10 个 open/closed（高价值的 5 个：#1157/#1158/#1159/#1162/#1163）
- **挖到 UCCL-EP 可能需要预警的**：9 条（其中 3 条高优先级，6 条低/监控）

**最大一条结论**：NIXL 的 libfabric 封装路径和 UCCL-EP 的**直接 ibv 路径**不同，大部分 NIXL 级 fix（provider 回退、FI_THREAD_COMPLETION、fi_setopt(FI_OPT_EFA_*)）**不直接套用**；但 EFA 物理层/驱动层/kernel 层的坑（RNR retry、dmabuf MR、CUDA context、32 rail 元数据、多 GPU 单进程）**完全共享**。UCCL-EP 已默默踩过 NIXL 同样的坑（如 dmabuf 降级、`rnr_retry=7`），但**还没踩过的有 3 个可预警的**：

1. **多 GPU 单进程的 `cudaSetDevice` 漂移**（NIXL PR #1506，2026-04-20 Blackwell 踩坑）
2. **32 rail 元数据交换 buffer 溢出**（NIXL issue #1158，p5.48xl 32-EFA）
3. **CUDA context on progress thread**（NIXL issue #1157，进度线程启动在 registerMem 之前）

---

## 1. EFA 相关 PR / commit 时间线

NIXL libfabric plugin 于 **2025-09 (commit 7f078cd, PR #784)** 首次落地，之后 7 个月里经过**大约 55 个 PR** 专门修 EFA 相关问题。分 6 个阶段：

### Phase 1: 2025-09–10 首次 landing + 基本可用
- **PR #784** 初始 libfabric 插件；hwloc 拓扑感知，要求 libfabric ≥ v2.3.0rc2；**要求 GDR**（mandatory）
- **PR #802**（9 月）换 EFA installer `-y --minimal`，自建 libfabric v2.3.0 + `--with-cuda --enable-cuda-dlopen --with-gdrcopy`
- **PR #809 / #817**：c5n.18xlarge 上 `efa-direct` 没 RMA，**退化到 `efa`**；AV 清理触发 msg_id 错乱，临时 disabled
- **PR #831**：binary notification `strncpy` 吃 null byte，改成 `memcpy + length`
- **PR #832**：aws_test.sh 加 `fi_info -p efa` 预检
- **PR #833**：TCP fallback（EFA 不在时用 sockets provider）
- **PR #835**：CI flaky workaround（临时关 UCX shm）
- **PR #839**：`fi_writedata` 在 EFA 上也要 retry（之前只有 TCP 走 retry），**双 free** 修复
- **PR #847**：删除 efa_installer 依赖（rdma-core 已经独立装）
- **PR #856**：`FI_EAGAIN` 必须 **先手工 progress CQ 再 retry**，否则永不解锁
- **PR #859**：retry indefinitely（`FI_EAGAIN` 后 exponential backoff）
- **PR #860**：hwloc topology load 失败后析构 double-free

### Phase 2: 2025-10–11 扩展 GPU 支持 + 鲁棒性
- **PR #883**：multi-desc 传输用 `remote[desc_idx].addr` 而不是 `remote_buf_addr_`（严重 correctness bug，iteration N 读的是 iteration 0 的 block）
- **PR #901**：`efa-direct` → `efa` fabric（FI_CONTEXT2 mode 去掉，为支持非-GDR 实例）
- **PR #908**：异构节点（p5en + p6）rails 不对称；**用户意图同时使用 p5en 和 p6**
- **PR #935**：wheel 里去除 libfabric 依赖
- **PR #960**：CUDA MR 用 `fi_mr_regattr`（之前是 `fi_mr_reg`）
- **PR #961**：最低 libfabric 版本 1.21.0
- **PR #978**：`pub_md` release 后仍被访问（DEBUG 级别才暴露）
- **PR #1007**：README 改语法
- **PR #1024**：拓扑代码假设 GPU 比 NIC 少；两 GPU 共享一 NIC 的情况 broken
- **PR #1028**（UCX 相关）：UCX 默认 2 个 RMA rails
- **PR #1044**：MR key `0` 被误当作 invalid（正确的应该是 `FI_KEY_NOTAVAIL`）
- **PR #1076**：enable shared memory provider（此前 `FI_OPT_SHARED_MEMORY_PERMITTED=false` 被硬禁）；同时修 `FI_REMOTE_CQ_DATA` 标志 routing
- **PR #1080**：**sockets provider** CM thread `fi_cq_sread` 1000ms timeout → deadlock（软件 progress 需要频繁 poll）；降到 10ms
- **PR #1084**：`FI_OPT_EFA_USE_UNSOLICITED_WRITE_RECV=false`（CQ overflow 防护；牺牲一点性能换稳定）

### Phase 3: 2025-12 功能完善
- **PR #1102**：码主 @amitrad-aws 加 codeowner
- **PR #1142**：notification 分片（P5 32 EFA，连接 metadata ~1792 字节，之前 1024 上限）
- **PR #1149**：**GPU→EFA 映射用 PCI bus ID 而不是 GPU ID**（`CUDA_VISIBLE_DEVICES` 导致 GPU 0 其实是物理 GPU 1 → 选错 EFA）
- **PR #1207**：**`FI_OPT_EFA_RNR_RETRY=7`（infinite retry at firmware）**；之前 libfabric 只 retry 3 次
- **PR #1242**：Slingshot/CXI provider + `FI_MR_ENDPOINT`
- **PR #1251**：删除 CM 线程（合并进 progress）

### Phase 4: 2026-01–02 线程 + 性能
- **PR #1272**：**`FI_THREAD_COMPLETION` + batch CQ 读（16 entries）+ 去锁 on CQ read**
- **PR #1287**：有 EFA 硬件但没选 libfabric backend 时 warn
- **PR #1302**：NUMA 感知 rail 选择 policy（DRAM_SEG 类型）
- **PR #1335**：post 失败 retry 路径去掉 `usleep()`（CQ 已在 progress，延迟是纯浪费）
- **PR #1348**：TCP provider 修多项（memory seg type、64-bit key、offset）
- **PR #1386**：**删除 control rail**（和 data rail 合并，通知走 rail 0）
- **PR #1394**：修 PR #1302 回归（NUMA 测试 XML license 注释错位）

### Phase 5: 2026-03 多机型 + 调试
- **PR #1433**：`postXfer()` 没读 `opt_args` 里的 notification 更新
- **PR #1451**：EPLayout signaling buffer 在 scale-up 时会踩 send-buffer
- **PR #1457**：`FI_THREAD_COMPLETION` 要求所有 EP bound 对象都要 locked access；扩 CQ mutex
- **PR #1461**：NUMA-aware 不支持 c5n.18xlarge（无 GPU 实例），加 fallback
- **PR #1462**：重整日志级别（ERROR/WARN/INFO/DEBUG/TRACE）

### Phase 6: 2026-04 Blackwell 支持 + 紧急 fix
- **PR #1506**：**Blackwell (B200) 多 GPU 踩坑**：PR #1258 (Neuron) 把两个独立 `if` 合并成 `if/else`，打掉 `cudaSetDevice()` fallthrough；导致 `cuMemGetAddressRange` 在 EFA dmabuf 路径失败 → `fi_mr_key` 返回 `FI_KEY_NOTAVAIL`
- **PR #1510**：rails active 状态 ref count 修复
- **PR #1514 (OPEN, issue)**：libfabric backend 单线程 descriptor posting 在 block 碎片化时 18880 个 desc → 46 ms CPU；UCX 有 threadpool，libfabric 没有
- **PR #1527**：UCX config 只在有 EFA 时应用

---

## 2. NIXL 在 EFA 上踩过的坑（按 6 类）

### 2.1 MR 注册 / fi_mr_reg / fi_mr_regattr

**NIXL 遇到的问题**：
1. **最早用 `fi_mr_reg`，CUDA 要用 `fi_mr_regattr`** — PR #960 f8ba9bc "libfabric: Add CUDA memory registration support with fi_mr_regattr"；`fi_mr_regattr` 支持 `fi_mr_attr` 结构体里传 `iface=FI_HMEM_CUDA` / `FI_HMEM_NEURON`。
2. **MR key `0` 被误当 invalid** — PR #1045 ea8ccb8。`derive_remote_selected_endpoints()` 过滤 `key==0` 的 endpoint，但 EFA provider 可以合法返回 0；应该用 `FI_KEY_NOTAVAIL` sentinel。
3. **B200/Blackwell dmabuf MR 在 device N>0 上拒绝** — PR #1506 ae5ae82。因 `if/else` 合并掉了 `cudaSetDevice()` fallthrough → `cuMemGetAddressRange` 找不到符号 → `fi_mr_key` = `FI_KEY_NOTAVAIL`。**仅 Blackwell 出现，Hopper H200 测试仍正常**（driver 级 dmabuf 行为差异）。
4. **FI_MR_ENDPOINT mode** — PR #1242 821f2b3。Slingshot/CXI provider 要求每个 MR 绑定到 endpoint；NIXL 原来没处理，AWS EFA 不需要但加了支持不影响。

**UCCL-EP 对应代码位置**：
- `uccl/ep/src/rdma.cpp:63 reg_mr_gpu_dmabuf()` — 先试 dmabuf FD，失败 fallback 到 `ibv_reg_mr_iova2` + peermem
- `uccl/ep/src/rdma.cpp:151 reg_mr_gpu_dmabuf_chunked()` — 按 chunk 分片注册（绕大 buffer 驱动限制）
- `uccl/ep/src/rdma.cpp:399, 687 cudaSetDevice(gpu_idx)` — **已经在 register 前设好 context**

**UCCL-EP 是否会踩**：
- **#960 (fi_mr_regattr)** — N/A，UCCL 走 `ibv_reg_dmabuf_mr` / `ibv_reg_mr_iova2` 直接 API，不经过 libfabric 抽象。
- **#1045 (MR key 0)** — N/A，UCCL 没用 libfabric MR key 语义。
- **#1506 (Blackwell 多 GPU cudaSetDevice)** — **高风险**！UCCL 同样用 `cudaSetDevice` 但只在 MR 注册路径设一次，**没有反复在 multi-GPU-per-process 里切 context**。如果 bench 代码或 sglang worker 用 `CUDA_VISIBLE_DEVICES` 限制可见 GPU，和主进程内开多 GPU 的场景，UCCL 很可能踩到**同样的 `cuMemGetAddressRange` fail**。建议：
  - 在 `rdma.cpp:619` `reg_mr_gpu_dmabuf()` 被调用之前 `CUDA_CHECK(cudaSetDevice(gpu_idx))`，且**每次 MR 注册前都做**。
  - 增加 Blackwell / B200 上的 bench smoke test（本仓库已有 p6-b300 manifest，可以开 2-GPU/node 覆盖）。

---

### 2.2 fi_inject / 小包 inline send

**NIXL 遇到的问题**：无！
- `git log --all --grep="inject" -i` 在 NIXL 只出一条 CI 相关 commit，**没有任何 `fi_inject` / `fi_inject_write` 功能代码被加过或被改过**。
- `grep fi_inject src/` 返回空。
- 说明 NIXL 根本没启 EFA 的 inline send 路径（EFA RDM provider 支持 `fi_inject` 但 payload 上限很小，8 字节左右）。

**UCCL-EP 对应代码位置**：
- `uccl/ep/src/rdma.cpp:899 qp_attr_ex.cap.max_inline_data = 0`  — UCCL **明确关掉 inline**。

**UCCL-EP 是否会踩**：
- **不会踩**（行为一致）。但这也说明 **`docs/SRD_PROTOCOL_PART2.md` 里的 "L1 inline" lever 在 NIXL 也没启** — NVIDIA 自己不碰它。间接佐证 L1 降到 Sprint D 的判断是合理的，上游经验没有收益证据。
- **注意场景差异**：NIXL 是点对点单请求 (KV push/pull)，UCCL-EP 是 all-to-all 稀疏 token dispatch。**即便 inline 有效，all-to-all 场景里 token size 远超 8B（FP16 hidden ~16KB/token），永远不满足 inline 上限**。所以对 UCCL-EP，inline 基本不可能有收益。

---

### 2.3 Endpoint 复用策略

**NIXL 遇到的问题**：
1. **最初 control rail + data rail 分开** — PR #1386 8ceee26 "libfabric: remove control rail" **删除 control rail，合并回 data rail 0**。理由：简化；notification 走 rail 0 with `fi_senddata`；实测 8-device nixlbench + vLLM 零 EAGAIN 零 perf regression。
2. **CM 线程单独存在** — PR #1251 9e91adc "remove cm thread"：和 progress thread 合并。
3. **FI_THREAD_COMPLETION 语义要求 locked EP access** — PR #1457 e0524ea。`FI_THREAD_COMPLETION` 要求所有 bound 到 CQ 的对象（尤其 endpoint）并发访问要加锁；扩展 CQ mutex 覆盖 endpoint post 操作。
4. **AV entry cleanup 导致 msg_id 错乱** — PR #817 a7851fd。disconnect 时 `fi_av_remove` 再重 insert 会搞坏 EFA 的 msg_id 序列；**暂时 disabled AV cleanup**（注释说 "TODO: EFA provider bug"）。

**UCCL-EP 对应代码位置**：
- `uccl/ep/src/rdma.cpp` QP 创建：`S.qp` (data), `S.ack_qp`, `S.recv_ack_qp`, `S.data_qps_by_channel[r]` — **UCCL 是多 QP，按 channel/功能切分**，和 NIXL 的 "data rail + control rail" 是同类问题。
- `ibv_create_cq` on line 875 + 另外一个 `ibv_create_cq_ex` — 多个 CQ。

**UCCL-EP 是否会踩**：
- **AV cleanup msg_id bug (#817)** — N/A（UCCL 用 RC QP，不用 UD/AV；EFA 在 libfabric 层暴露为 UD-like，在 ibv 层面 UCCL 走 SRD）。
- **FI_THREAD_COMPLETION locking (#1457)** — N/A，UCCL 没用这个 libfabric 语义。
- **control/data rail 合并 (#1386)** — 类比 **UCCL 有没有多余的 ack_qp/recv_ack_qp 可以合并**？值得 follow-up 评估，但不是紧急。

---

### 2.4 错误重建机制 / 重试

**NIXL 遇到的问题**：
1. **FI_EAGAIN retry 要先 progress CQ** — PR #856 4b3227b。EFA provider 是 manual progress，不先 drain CQ 再 retry 就永远 EAGAIN。
2. **Retry 从 "10 次就 fail" → "indefinitely with exp backoff"** — PR #859 edf1e54。理由："resource temporarily unavailable 在 10 次 retry 后仍存在"。
3. **EFA-level retry 路径也需要（不只 TCP）** — PR #839 e739b9f。最初 retry 逻辑只在 TCP 触发，EFA provider 的 `fi_writedata` 同样会 EAGAIN。
4. **Retry delay 是纯浪费** — PR #1335 c1e8d66。`usleep()` 1ms base 100ms cap 被删：CQ 已在 retry 前 progress，sleep 只延迟恢复，没有任何好处。
5. **`FI_OPT_EFA_RNR_RETRY=7` (infinite firmware retry)** — PR #1207 75a3026。**最核心的一条**：RNR 让 firmware 处理比 libfabric 软件层 retry 快且可靠。

**UCCL-EP 对应代码位置**：
- `uccl/ep/src/rdma.cpp:1287-1289`：
  ```cpp
  attr.timeout = 14;
  attr.retry_cnt = 7;
  attr.rnr_retry = 7;
  ```
- UCCL **已经是 rnr_retry=7**（`ibv_modify_qp` 的 RC attr），等价于 NIXL 的 `FI_OPT_EFA_RNR_RETRY=7`。

**UCCL-EP 是否会踩**：
- **RNR retry (#1207)** — 已覆盖 ✓。
- **Retry delay (#1335)** — N/A，UCCL 没有软件层 retry 循环（硬件做 RNR）。
- **Progress-then-retry (#856)** — N/A（SRD 硬件 progress）。

---

### 2.5 AV 管理 / fi_av_insert

**NIXL 遇到的问题**：
1. **AV `fi_av_remove` 触发 msg_id 序列错乱** — PR #817 提到 "EFA provider bug where removing AV entries and re-adding them causes msg_id sequence mismatches"；workaround 是 **完全不清理 AV** 直到 agent 关闭。**注意 PR body 原文是 "temporary nature of the fix"**，说明上游本来打算后续修，但搜后续 commit 没看到对 AV cleanup 的 re-enable —— 这符合 `feedback_commit_narrative_full_log.md` 的训练（别只看一个 PR，要还原后续）。我核验了：
   - `git log --all --oneline -- src/plugins/libfabric/ | grep -i "av\|address"` 只出 topology 相关 PR，**没有后续 AV cleanup re-enable**。
   - `grep -n "AV_REMOVE\|fi_av_remove" src/utils/libfabric/*.cpp` 找到 `fi_av_remove` 还在调用点（rail.cpp:1452），但可能外层 disconnect 路径不走了。没深入验证是否真的 disabled，**留做 UNKNOWN**。
2. **大规模 AV insert**：没找到 batch-vs-individual 讨论。`fi_av_insert(av, addr, 1, ...)` 单 addr 调用 — 没 batch。

**UCCL-EP 对应代码位置**：
- UCCL 用 RC QP 不用 AV（AV 是 UD endpoint 的 address vector 概念）；**N/A**。

**UCCL-EP 是否会踩**：**不会**（不用 AV）。

---

### 2.6 CQ 事件合并 / batching

**NIXL 遇到的问题**：
1. **Batch CQ read 16 entries** — PR #1272 8b16e5a "CQ batch reads and threading model"：从单条 `fi_cq_read` → batch 16 条；threading 从 `FI_THREAD_SAFE` → `FI_THREAD_COMPLETION`；去掉 non-blocking read 的锁。
2. **sockets provider `fi_cq_sread` timeout 1000ms → 10ms** — PR #1080 74cd6dd。sockets 软件 progress 需要频繁唤醒；EFA provider hardware completion 不受影响（所以 EFA 路径 1000ms 是 OK）。
3. **完成路径缺 `FI_REMOTE_CQ_DATA` flag 分支** — PR #1076 06b0675。`fi_writedata` 有 immediate data 时 SHM provider 设 `FI_REMOTE_CQ_DATA` 而不是 `FI_REMOTE_WRITE`；原来只 check 后者 → 漏 route。
4. **fi_cq_read race with EFA driver completion posting** — Issue #1162（CLOSED）。"sporadic CQ error + crash"，root cause 是 driver 还没写完 completion 就被 fi_cq_read 取走；issue 提 fix 是加 memory barrier + sched_yield + 1ms sleep。（**注意**：这是 issue reporter 的 proposed fix，不一定是上游最终 landing 的方案；`gh` 没返回引用 PR，**status 是 CLOSED 但不明确是 fixed 还是 wontfix**。留做 UNKNOWN。）
5. **CQ overflow under high load + unsolicited write recv** — PR #1084 d6c0f18。`FI_OPT_EFA_USE_UNSOLICITED_WRITE_RECV=false` 减少 CQ 条目数（trade 性能换稳定）。

**UCCL-EP 对应代码位置**：
- `uccl/ep/src/rdma.cpp:2130 poll_cq_once(ibv_cq* cq, ibv_wc* wc, int max_cqes)`
- `uccl/ep/include/common.hpp:79 #define kMaxOutstandingSends 2048`
- UCCL 每次 `ibv_poll_cq(cq, max_cqes, wc)` 可以一次取最多 `kMaxOutstandingSends=2048` 个 WC — **比 NIXL 16 大 128 倍**。

**UCCL-EP 是否会踩**：
- **Batch CQ (#1272)** — 已覆盖，UCCL 批更大。
- **CQ race with driver (Issue #1162)** — **可能踩**。UCCL 在高并发下也可能遇到；**但 issue 提议的 "1ms sleep" 不可以套用**，原因：
  - UCCL-EP decode ITL 预算 ~5ms，1ms sleep 是 20% 预算，不能盲加。
  - Issue reporter 的 fix 不是上游最终方案（CLOSED 但不确定），**不能当证据采纳**（遵守 `feedback_claim_verification_discipline.md` 第 4 条：声称必须 grep 上游 PR 才能采纳）。
  - 建议：若 UCCL-EP 在 32-rail p5.48xl 下出现类似 sporadic CQ error，**先写 reproducer**，再考虑 memory_order_seq_cst fence（不是 sleep）。
- **`FI_OPT_EFA_USE_UNSOLICITED_WRITE_RECV`（#1084）** — **值得 follow-up**。UCCL 用 RC QP 其实不涉及 "unsolicited write recv" 机制（那是 EFA RDM 语义层的），但如果 UCCL 路径走 SRD write-with-imm，CQ overflow 是否会是个问题？留做 UNKNOWN，需要 32-rail 长跑监控 CQ depth。

---

## 3. NIXL README / docs 里的 EFA 配置建议

**关键摘录 (`src/plugins/libfabric/README.md`)**：

1. **AWS EFA installer 最低 1.43.2**。
2. **libfabric 最低 v1.21.0**（起初是 v2.3.0rc2，后放宽）。
3. **hwloc ≥ 2.10.0**（拓扑发现）。
4. **libnuma ≥ 2.0.18**（DRAM_SEG NUMA-aware rail selection）。
5. **调试开关**：`FI_LOG_LEVEL=debug`，`FI_LOG_PROV=efa`，`NIXL_LOG_LEVEL=debug`。
6. **运行时环境变量**：`NIXL_LIBFABRIC_MAX_BW_PER_DRAM_SEG`（DRAM seg 单 NUMA 带宽上限，单位 Gbps，默认由 PCIe 拓扑自动算）。
7. **预检命令**：
   ```bash
   fi_info -l           # 列 provider
   fi_info -p efa       # 检查 EFA provider 可用
   ```
8. **SG 安全组要求**：PR #832 强调 AWS SG 必须允许 EFA traffic（否则 `fi_info -p efa` 失败）。这对 UCCL-EP 同样适用（已在 stage5 环境做）。

**UCCL-EP 可借鉴**：
- **把 `fi_info -p efa`（或 UCCL 版本的 `ibv_devices`/`ibv_devinfo`）加进启动预检** — UCCL 已有类似逻辑但建议参照 NIXL 的 "fail-fast + 明确 error message"。
- **日志级别规范** — 参考 PR #1462 的分级，尤其 "配置/连接 = INFO, per-xfer = DEBUG, 高频内部 = TRACE"。UCCL 当前日志偏粗，可借鉴。

---

## 4. 最有价值的 3-5 条借鉴

### 借鉴 #1：多 GPU 单进程 `cudaSetDevice` 必须在每次 MR 注册前
- **NIXL 教训**：PR #1506 ae5ae82（2026-04）Blackwell B200 上 `if/else` 合并打断了原来两个独立 `if` 的 fallthrough，导致 `cudaSetDevice` 不调用，`cuMemGetAddressRange` 在 EFA dmabuf 路径 fail，`fi_mr_key` 返回 `FI_KEY_NOTAVAIL`，整个注册挂掉。**Hopper H200 没挂，只 Blackwell 挂** — driver 级差异。
- **UCCL-EP 风险**：中-高。UCCL `rdma.cpp:399, 687` 有 `cudaSetDevice(gpu_idx)` 但只在 `rdma_setup()` / 初始化路径里，**不是每次 MR 注册前都设**。如果后续加 on-the-fly MR re-register（如 SGLang 动态 KV cache 扩张），很可能踩到 Blackwell 同样的坑。
- **建议改动**：
  - 位置：`uccl/ep/src/rdma.cpp reg_mr_gpu_dmabuf()` 入口
  - 方式：
    ```cpp
    ibv_mr* reg_mr_gpu_dmabuf(ibv_pd* pd, void* gpu_buf, size_t bytes, uint64_t iova, int access, int gpu_idx) {
      CUDA_CHECK(cudaSetDevice(gpu_idx));  // ADD THIS
      // ...existing code
    }
    ```
  - 在 Blackwell b300 节点加回归 test（manifests/stage5-p5en/r6a-glm46-1p1d-v5-b300-az2.yaml 场景）
- **诚实收益估算**：这不是性能收益，而是**避免 Blackwell run 直接挂**。零 run-time 开销（cudaSetDevice 是 ~1us）。**不按 NIXL 实测数字套**（`feedback_baseline_cross_hardware.md`）—这是 correctness，不是性能。

### 借鉴 #2：32-rail / P5 级元数据 buffer 足够大
- **NIXL 教训**：Issue #1158 `char message[8192]` 在 P5 32-EFA 下溢出（每 rail 56B endpoint × 32 = 1792B，再加 header 和其他状态 > 8KB）；PR #1142 专门加 notification 分片 256B 一片。
- **UCCL-EP 风险**：中。`uccl/ep/` 的 proxy 通信也有 metadata 交换路径（atomic buffer / ack_qp init）；没找到明确 buffer 上限；默认行为大概是按 batch size 2048 × WR size 算，**p5.48xl 32 EFA × 8 channel × 2048 WR** 规模下要验证。
- **建议改动**：
  - 位置：`uccl/ep/src/proxy.cpp` atomic buffer 和握手 metadata
  - 方式：grep `kAtomicBufferSize` 等常量，和 rails × channels 数对照；加 assertion 或动态 sizing
  - 预防性 action：在 32-rail p5.48xl 上跑一次全尺寸 warm-up，看 metadata exchange 是否 OK
- **诚实收益估算**：零性能收益，**避免 32-rail 场景直接 crash**。

### 借鉴 #3：`FI_OPT_EFA_USE_UNSOLICITED_WRITE_RECV` 语义在 UCCL-EP 下的潜在等价
- **NIXL 教训**：PR #1084 关 unsolicited write recv 减少 CQ 条目数，防 CQ overflow。**注意**：这是 libfabric EFA RDM 语义层特性，ibv 直接路径没有完全对应的开关。
- **UCCL-EP 风险**：低-中。UCCL 用 RC + SRD write，不涉及 unsolicited recv，但 **CQ overflow 问题在 32-rail 高并发下仍可能存在**。
- **建议改动**：
  - 位置：`uccl/ep/src/rdma.cpp:875 ibv_create_cq(cq_depth)` + `uccl/ep/include/common.hpp:79 kMaxOutstandingSends=2048`
  - 方式：32-rail 长跑监控 `ibv_poll_cq` 的 `wc_status`，如果出现 `IBV_WC_GENERAL_ERR` 且 vendor_err 指向 CQ overflow，考虑加大 CQ depth 到 4096。**不预先改**，等看到证据。
- **诚实收益估算**：不确定，不做预测。

### 借鉴 #4：日志级别规范 (PR #1462)
- **NIXL 教训**：原来 error=WARN / control plane=DEBUG / per-xfer=INFO，混乱；重整后：error=ERROR, 非致命意外=WARN, 连接/控制面=INFO, per-xfer=DEBUG, 高频内部=TRACE。客户凭 INFO log 就能诊断基础配置和连接问题。
- **UCCL-EP 风险**：低（纯运维）。UCCL 当前日志粒度不够规范，尤其 `proxy.cpp` 多用 fprintf(stderr) 而不是分级。
- **建议改动**：
  - 位置：全 UCCL-EP
  - 方式：建立 `NIXL_INFO/DEBUG/TRACE` 类似宏；把 per-dispatch/per-combine log 从 INFO 降到 TRACE
- **诚实收益估算**：对 debug/triage 效率提升明显（客户上传 INFO log 就能定位），性能无影响。**优先级低**。

### 借鉴 #5：不信任的 issue proposed fix 不直接采纳（方法论借鉴）
- **NIXL 的反例**：Issue #1162 提议加 `sched_yield + usleep(1000)` 修 CQ race；状态 CLOSED 但没有对应 merged PR body 证明最终上游采用。**如果我 2-年前看到这个 issue，会不会盲加 1ms sleep？可能会。但一旦加入 decode 热路径，就是 20% 预算被掉。**
- **对 UCCL-EP 的方法论借鉴**：严格遵循 `feedback_claim_verification_discipline.md` 第 4 条 + `feedback_commit_narrative_full_log.md`：
  1. Issue 提 fix ≠ 上游 fix。必须 grep 是否 merged。
  2. 即便 merged，也要看后续是否被 revert 或改写。
  3. Cross-hardware 数字永远要有物理证明（NIXL H100 的 1ms sleep 不适合 B200）。
- **行动**：在 `reference_final_execution_checklist.md` / `reference_lever_validation_summary.md` 加一条 entry：**"从 NIXL issue 借 fix 前先 grep commit log"**。

---

## 5. 警示：NIXL 做了但 UCCL-EP 不该做的

### 警示 #1：Control rail / data rail 合并 → UCCL 的 ack_qp 合并？
- **NIXL 做了什么**：PR #1386 删 control rail，通知走 data rail 0。
- **UCCL-EP 不能直接做**：UCCL-EP 的 `ack_qp` / `recv_ack_qp` 用途是 **SRD ACK 流量和 data 流量解耦**，目的是让 ACK 不被 data 挤。如果简单合并到 `S.qp`，ACK latency 会和 data 竞争 CQ。**不要直接抄 NIXL 的合并**。
- **评估标准**：合并前必须测 ACK RTT（`bench/` 下已有类似 test），合并后 RTT 不退化才行。

### 警示 #2：CQ batch 从 1 → 16 的 NIXL gain 不等于 UCCL-EP 的收益空间
- **NIXL 做了什么**：PR #1272 单条 → 16 条 batch CQ read。
- **UCCL-EP 已经做了更激进**：`poll_cq_once` 一次取 `kMaxOutstandingSends=2048`。**NIXL 的 "batch 16" 只是补 libfabric 抽象层本身的缺陷，不是 EFA 物理层 gain**。
- **教训**：UCCL-EP 在这个 lever 上已经 at ceiling，**不要把 NIXL 的 batch-read gain 数字等比套**（`feedback_baseline_cross_hardware.md`）。

### 警示 #3：NUMA-aware rail selection for DRAM_SEG
- **NIXL 做了什么**：PR #1302 限制 DRAM_SEG 只用 NUMA-node 内的 rail，避免跨 PCIe switch 饱和；PR #1461 为无 GPU 机型 fallback。
- **UCCL-EP 不适用原因**：UCCL-EP 的 payload 几乎全是 VRAM（GPU hidden state），走 VRAM + GDR 路径；DRAM_SEG 不是热路径。**不需要移植这个 lever**。
- **例外**：如果 UCCL-EP 的 control / metadata buffer 是 DRAM 类型（如 proxy 的 atomic buffer on host），那些路径可能相关——但流量极小，不值得调。

### 警示 #4：EFA RNR firmware retry 的"无限重试"
- **NIXL 做了什么**：`FI_OPT_EFA_RNR_RETRY=7` (infinite at firmware)；UCCL 已做等价 `rnr_retry=7`。
- **警示**：**"infinite retry" 掩盖 receiver not ready 问题 → 在 SGLang 场景下会把 "receiver busy on GPU compute" 变成长尾**。已在 `docs/COMBINE_RECV_DEEP_DIVE.md` 分析 combine recv 46.72 µs = 纯 GPU 计算时间；**硬件 RNR 无限 retry 会把这 46 µs 变成数 ms 长尾在 tail pct99**。
- **行动**：不要把 `rnr_retry=7` 当免费午餐；对 p99 ITL 敏感的 run 可能要考虑 `rnr_retry=3-4` 更快 bail out + 应用层重传。**留做 Sprint 后续实验**。

---

## 6. 残余 UNKNOWN

1. **AV cleanup re-enable (PR #817 的 TODO 后续)**：NIXL 是否最终修了 EFA msg_id 错乱？`fi_av_remove` 调用点仍在 `libfabric_rail.cpp:1452`，但外层 disconnect 是否绕开了，未深入 trace。**对 UCCL-EP 无影响**（不用 AV），但对理解 EFA provider 的行为有参考价值。

2. **Issue #1162 fi_cq_read race 最终是不是用 sched_yield+usleep 修的**：issue CLOSED 但未找到对应 PR。如果上游用的是 memory barrier 而不是 sleep，对 UCCL-EP 的工程建议就完全不同。需要进一步 `gh pr list --search "cq race"` 查 merged 版本。

3. **PR #1514 LIBFABRIC threadpool 后续是否合入**：截止 2026-04-26 issue 仍 OPEN，没有对应 PR。UCX 有 threadpool，libfabric 没有。**对 UCCL-EP 意义**：如果 decode 阶段 dispatch 的 descriptor 数极大（类似 NIXL 18880 desc），UCCL 同样单线程 `ibv_post_send` 是否瓶颈？需要对 p6-b300 GLM-4.6 大 batch 场景 profile 验证。

4. **NIXL 是否有 32-rail + Blackwell 的实测数**：PR #1142 只说"支持"，没给具体带宽数字；PR body 里说 "Validated on 8-device nixlbench with zero EAGAIN + no perf regression"，**没 32-device 实测**。**所以我不能直接说 "NIXL 32-rail 稳定因此 UCCL-EP 也稳定"**，这是 cross-hardware cross-workload 声称，违反 `feedback_baseline_cross_hardware.md`。

5. **`FI_OPT_EFA_USE_UNSOLICITED_WRITE_RECV` 背后物理机制**：PR #1084 body 说 "CQ pressure" 但没给 CQ depth 和观察数据；是否也影响 ibv RC write 路径的 CQE 生成？无法从 NIXL commit log 单独判断，需要看 EFA kernel driver 代码。

6. **PR #1506 Hopper 不踩 Blackwell 踩的底层原因**：body 只说 "Blackwell (B200) requires the correct CUDA context for cuMemGetAddressRange; Hopper (H200) seems still working"。**不解释为什么** — 是 Blackwell driver 更严还是 cuMemGetAddressRange 实现改了？影响我们能否预测 B300（比 B200 更新一代）的行为。

---

## 附录 A：本次调研 gh 查询命令（可复现）

```bash
cd /tmp/nixl && git fetch --unshallow  # 从 shallow 拉完整 895 commits
git log --all --oneline --grep="efa\|libfabric\|aws\|fi_" -i
gh pr view <N> --repo ai-dynamo/nixl --json title,state,body
gh issue list --repo ai-dynamo/nixl --state all --limit 100 --search "libfabric"
grep -rn "fi_mr_reg\|fi_cq_read\|fi_av_insert\|FI_OPT_EFA" src/
```

UCCL-EP 对照：`/home/ec2-user/workspace/uccl/ep/src/rdma.cpp`, `/home/ec2-user/workspace/uccl/ep/include/common.hpp`, `/home/ec2-user/workspace/uccl/ep/src/proxy.cpp`.

## 附录 B：最关键的 PR/issue 编号清单（按 UCCL-EP 相关度降序）

| PR/Issue | 主题 | UCCL-EP 相关度 | Action |
|---|---|---|---|
| #1506 | Blackwell multi-GPU cudaSetDevice | 高 | 参见借鉴 #1 |
| #1158 | 32-rail metadata overflow | 中-高 | 参见借鉴 #2 |
| #1157 | CUDA ctx on progress thread | 中 | UCCL 无独立 progress thread，但 proxy thread 类似 |
| #1162 | fi_cq_read race | 中 | **不直接采纳其 fix**；保持监控 |
| #1084 | FI_OPT_EFA_USE_UNSOLICITED_WRITE_RECV | 中 | 非 ibv 对等 API，借鉴 CQ overflow 意识 |
| #1142 | Notification fragmentation | 中 | UCCL metadata 交换路径可能类似 |
| #1207 | RNR retry = 7 | 低 (已覆盖) | UCCL 已 rnr_retry=7 ✓ |
| #1386 | Control rail 合并 | 低 (警示 #1) | 不要抄 |
| #1272 | CQ batch 16 | 低 | UCCL 已 batch 2048 |
| #1302 | NUMA-aware DRAM rail | N/A | UCCL 走 VRAM 为主 |
| #1514 | threadpool (OPEN) | 高-监控 | 32-rail p6-b300 profile 时注意 |
| #1462 | 日志分级 | 低-长期 | 运维优化 |
| #1045 | MR key 0 is valid | N/A | libfabric 特有 |
| #817 | AV cleanup disable | N/A | UCCL 不用 AV |
| #1080 | Sockets provider timeout | N/A | UCCL 不用 sockets |

---

*文档长度 ~4700 字。所有结论引用 PR/issue/commit 编号或 file:line；收益估算均标注诚实 / 不跨硬件套用。*
