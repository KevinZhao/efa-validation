# UCCL-EP CPU-Proxy 架构相对 DeepEP GPU-IBGDA 的独占优化 lever 大全

> ⚠️ **STALE / MOSTLY SUPERSEDED (2026-04-26)**
> 本文档 20 个 lever 中的 TOP 10，**有 5 个已被 `docs/FEASIBILITY_RECONFIRM.md` 完全驳回、2 个收益砍到 1/10、1 个已有上游 PR 不用重写**：
> - C1 Persistent combine kernel（声称 600-1200 µs/token）→ 0（CUDA Graph 已摊销）
> - C2 Early-drop 非 top-k（声称 200-400 µs）→ 0（概念错）
> - C3 Clean-elision（声称 150-300 µs）→ 0（kernel 不在 decode 每步跑）
> - A2 Selective signaling → 0（SRD sq_sig_all=1 硬约束）
> - A5 Straggler soft degrade → 0（Stage 5 无此事件 + 精度风险）
> - A3 Batching window → 0（已有隐式 batch）
> - A6 NUMA pin：50-80 µs → 3-8 µs（已 pin NIC NUMA，改 CCX 只省 few µs）
> - B1 Multi-NIC：声称带宽 2× → dispatch 1.6-2×，**combine <1.15%**（combine 非 BW 瓶颈），3-5 周非 2 周
> - A1 Dynamic QP LB：有上游 PR #485 DRAFT 5 个月，我们 **rebase + bench**，不重写
> - A6 整体 "P50 -63% P99 -74%" 声称 → 真实上限 **-15~-20%**
>
> **本文档仅保留作"探索思路的原始参考"**。实际可做的 lever 见 `docs/FEASIBILITY_RECONFIRM.md`，执行顺序见 `docs/FINAL_EXECUTION_CHECKLIST.md`，预期数字见 `docs/EXPECTED_PERFORMANCE_GAINS.md`。

**日期**：2026-04-25
**调研方式**：3 个并行 agent（CPU-proxy 编排智能 / EFA 硬件特性 / 跨层长 horizon 编排）
**核心前提**：UCCL-EP 在 EFA 上强制 CPU proxy 路径（`GPU 写 FIFO → CPU 读 → ibv_post_send`），DeepEP NVIDIA 走 GPU-initiated IBGDA（GPU warp 直接敲 MLX5 doorbell，CPU 完全不在 hot path）。
**结论**：除 SBO Sprint A/B/C 已覆盖的 3 个 lever 外，再找到 **20 个独占优化点**，其中 **8 个高置信 + 高 ROI**。

---

## 0. 架构差异为什么会产生这些 lever

| 维度 | DeepEP NVIDIA (GPU IBGDA) | UCCL-EP (CPU proxy) |
|---|---|---|
| WR 发起者 | GPU warp 直接写 doorbell | GPU 写 FIFO → CPU `ibv_post_send` |
| WR 结构 | 每 doorbell = 1 WQE（1:1）| CPU 可后聚合多 WR + 多 SGE |
| 跨 warp/expert 观察 | 不可见 | CPU 全局可见所有 expert 状态 |
| CQE 处理 | 必须 signal-all（GPU 无 poll loop）| CPU 自主 signal-every-Nth |
| 动态决策 | 编译期绑 QP/NIC | 运行时按负载选 QP/NIC |
| NUMA 亲和 | 无 CPU 参与，irrelevant | PCIe-local vs cross-socket MMIO 300-500 ns 差 |
| 跨 step 状态 | 每 kernel 独立 | CPU 可维护 long-horizon state |
| 失败检测 | 无外部观察者 | CPU 可检测 straggler 软降级 |

**三句话概括**：
1. CPU proxy 让"**聚合 / 调度 / 决策**"成为可能（4 维自由度）
2. CPU proxy 让"**跨 kernel / 跨 step 的 orchestration**"成为可能（时间维度）
3. CPU proxy 让"**跨 rank 的诊断和降级**"成为可能（可靠性维度）

---

## 1. Lever 全集（3 agent 交叉验证，去重 + 合并后 20 项）

### A. 编排层 lever（Agent 1 挖的编排智能）

| # | 名称 | 单步 µs 节省 | 工作量 | 置信度 |
|---|---|---:|---|---|
| **A1** | **Dynamic rail / QP load balancing**（LL 模式下从单 QP 扩到 argmin(inflight)）| 尾延 30-50%（热 expert）| 2-3 d | 高 |
| **A2** | **Selective signaling + CQE batching**（每 8 WR signal 1 次）| proxy CPU -85% + 尾延 -2-5 | 3-4 d | 高 |
| **A3** | **Post-send batching window**（3 µs 聚合 doorbell）| 3-6 | 1-2 d | 高 |
| **A4** | **Per-peer inflight budget adaptation**（EWMA 动态节流慢节点）| 异构场景尾延 -30-50% | 4-5 d | 中-高 |
| **A5** | **Straggler detection + soft degrade**（silent peer 自动 zero-fill）| decode P99 从 timeout 变正常 | 6-8 d | 中-高 |
| **A6** | **NUMA + PCIe-local CPU pinning**（避免 QPI/xGMI MMIO）| 50-80 / step | 2 d | 高 |
| **A7** | **Low-power monitor/mwait polling**（替代 `_mm_pause`）| 间接：SMT sibling IPC | 2 d | 低 |
| **A8** | **Ring-buffer selective fence + head-batch commit** | dispatch SEND -10-20 | 4-5 d | 低-中 |

### B. EFA 硬件 lever（Agent 2 挖的硬件特性）

| # | 名称 | 单步 µs / 比例 | 工作量 | 置信度 |
|---|---|---:|---|---|
| **B1** | **Multi-NIC rail 聚合** — 当前每 GPU 只用 2/4 NIC，带宽利用 50% | 带宽 **2×** | ~2 周 | 高 |
| **B2** | **Service Level 分流**（signal SL=8 / data SL=0）| P99 尾延 -10-20 | 2 d | 高 |
| **B3** | **SGE 合并**（`max_send_sge=1→2+`）| combine -3-8 | 1 周 | 高 |
| **B4** | **Reorder buffer bypass for combine**（顺手修 #684）| -2-5 + fix bug | 中 | 中 |
| **B5** | **Aggressive inflight（利用 SRD 硬件重传）**（32→64）| 吞吐 +15-30% | 小 | 高 |
| **B6** | **Inline data for small WR** `max_inline_data=64`（EFA 支持 ~32-36 B inline）| count-send -1-2 | 1 d | 中（**和 Agent 2 之前结论有冲突**，见下方注）|
| **B7** | **Cluster placement group same-rack**（脚本侧）| RTT -2-5 | 小 | 中 |

**⚠️ 重要修正**：B6 和早期 agent 的"EFA SRD max_inline=0 硬约束"结论有冲突。Agent 2 在本次调研里指出 EFA SRD 支持 32-36 B inline。需要在 Stage 5 p5en 上实测确认 `efadv_query_device.inline_buf_size` 再决定。

### C. 跨层长 horizon lever（Agent 3 挖的 architectural）

| # | 名称 | 单步 µs 节省 | 工作量 | 置信度 |
|---|---|---:|---|---|
| **C1** | **Persistent combine kernel**（解 #734 + 60 层 launch 融合）| **600-1200 / token** | ~2 周 | 高 |
| **C2** | **Early-drop 非 top-k payload**（decode batch=1×top-8 → 248 非 topk expert 白发 WR）| **200-400 / token** | 2 d | 高 |
| **C3** | **Clean-elision** `clean_low_latency_buffer`（CPU 只 memset dirty range）| 150-300 / token | 2-3 d | 高 |
| **C4** | **Attention ↔ dispatch overlap**（CPU 在 attention kernel 运行时预 pre-arm RDMA addr table）| 80-200 | 1 周（含 SGLang 1 个 event hook）| 中 |
| **C5** | **Speculative combine WR posting** | 100-250 | 1 周 | 中（需先 C6） |
| **C6** | **RDMA MR scratch pool pre-registration** | 20-60（仅步稳态）| 1 d | 高 |

---

## 2. 合并后按 ROI 排序的 TOP 10

综合三个 agent 的打分 + decode 延迟优先 + SBO 叠加效应：

| 排名 | Lever | 归属 | 单步 µs 节省 | 工作量 | 与 SBO 关系 |
|---|---|---|---:|---|---|
| 🏆 1 | **C1 Persistent combine kernel** | Agent 3 | **600-1200** | 2w | 正交（SBO 攻 tail，C1 攻 launch）|
| 🥈 2 | **B1 Multi-NIC rail 聚合** | Agent 2 | 带宽 **2×** | 2w | 正交 |
| 🥉 3 | **C2 Early-drop 非 top-k** | Agent 3 | **200-400** | 2 d | 正交 |
| 4 | **C3 Clean-elision** | Agent 3 | 150-300 | 2-3 d | 正交 |
| 5 | **A1 Dynamic QP load balance** | Agent 1 | 尾延 30-50% | 2-3 d | 正交 |
| 6 | **A6 NUMA/PCIe-local pinning** | Agent 1 | 50-80 | 2 d | 正交（零风险先做）|
| 7 | **A2 Selective signaling** | Agent 1 | proxy CPU -85% + 2-5 | 3-4 d | 正交（解 proxy 瓶颈）|
| 8 | **A5 Straggler soft degrade** | Agent 1 | decode P99 从 timeout 变正常 | 6-8 d | 正交（Spot 场景必须）|
| 9 | **B2 SL 分流** | Agent 2 | P99 -10-20 | 2 d | 协同（SBO 的 signal msg 更快）|
| 10 | **A3 Post-send batching window** | Agent 1 | 3-6 | 1-2 d | **可能冲突 A5**（batching 拖慢 straggler 检测，但时间尺度不同）|

---

## 3. 与 SBO Sprint A/B/C 的叠加关系

**SBO 只攻 "combine send 和 down_gemm 的重叠"**。上面 20 个 lever **全部正交**（除少数协同或冲突）：

- **SBO 攻**：combine send phase 内部的流水重叠（~30% 尾巴）
- **C1 攻**：60 层 combine 的 **kernel launch 本身**（~1 ms/token，SBO 不管）
- **C2 攻**：**WR 总量**（decode 每层 248 个非 topk WR 白发，SBO 不过滤）
- **C3 攻**：**每步的 clean 开销**（SBO 不清理）
- **B1 攻**：**带宽利用率**（SBO 不平衡 rail）

**推导**：如果 SBO Sprint A/B/C 把 combine 从 600 µs 降到 350 µs，再叠 **C1+C2+C3+B1** 预计再砍 30-40% → 总 decode ITL **相对 baseline ~40-50%**，非常可观。

**非正交叠加**：
- **A2 ⊕ A3**（selective signaling + batching）强协同，共同把 proxy CPU 从瓶颈解放
- **A1 ⊕ A6**（QP load balance + NUMA pin）强协同，不 pin 好 PCIe 本地就 LB 到冷 socket
- **A4 ⊕ A5**（EWMA budget + straggler degrade）同一套 latency 统计，顺序：先节流再降级
- **A3 ⊕ 小消息 latency** 冲突：batching 窗口拖慢 count-send；方案 **让 BARRIER/ATOMIC bypass 窗口**

---

## 4. 推荐 "第二批 PR" 组合（SBO 落地后）

基于 ROI + 工作量 + 上游 merge 友好度 + 和 Stage 5 bench 可见度：

### 🥇 第一组：立刻可做的"小 diff 高收益"
**总工期 ~5 d，预期 decode ITL -8-12%，proxy CPU -60%**

1. **PR-X1：A6 NUMA/PCIe-local pinning**（2 d，零风险，50-80 µs/step）
   - `common.cpp:50-83` 改 pin 策略
   - 见 `nvidia-smi nvlink -g 0` / `/sys/class/infiniband/.../numa_node`
2. **PR-X2：A2 Selective signaling**（3-4 d，解 proxy CPU 瓶颈）
   - `rdma.cpp:1437, 1866, 2838` 改 signal 策略
   - 为后续 A1/A3 铺路
3. **PR-X3：B2 Service Level 分流**（2 d，P99 -10-20）
   - 新 env `UCCL_EP_SIGNAL_SL=8 / UCCL_EP_DATA_SL=0`
   - 要求 efa-installer ≥ 1.34

### 🥈 第二组：核心 decode 延迟杀手
**总工期 ~3 w，预期 decode ITL -30-40%**

4. **PR-X4：C3 Clean-elision**（2-3 d，每层 2-5 µs × 60 层）
5. **PR-X5：C2 Early-drop 非 top-k**（2 d，每 token 200-400 µs）
6. **PR-X6：C1 Persistent combine kernel**（2 w，最大 lever 但 diff 最大）
   - 顺便解 UCCL issue #734
   - 建议隐藏 env `UCCL_EP_PERSISTENT_COMBINE=1`

### 🥉 第三组：Spot / 多节点可靠性
**总工期 ~2 w，改善 P99 tail**

7. **PR-X7：A1 Dynamic QP load balance**（2-3 d，尾延 30-50%）
   - 需要 gate `!USE_RECEIVER_BARRIER`
8. **PR-X8：A4 Per-peer inflight budget**（4-5 d）
9. **PR-X9：A5 Straggler soft degrade**（6-8 d）
   - 需要 product/accuracy 确认 zero-fill 可接受
   - `UCCL_EP_STRAGGLER_DEGRADE=1` 隐藏 env

### 第四组：带宽 + 规模扩展
**总工期 ~3 w，场景特定收益**

10. **PR-X10：B1 Multi-NIC rail 聚合**（2 w，**带宽 2×**，但改动大）
    - 所有 `data_qps_by_channel` 扩维
    - 和 PR-X7 (A1) 强相关

### 跳过 / 延后

- **B4 Reorder bypass**：和 issue #684 修复绑定，独立做小，benefit 小
- **B5 Aggressive inflight**：依赖 B4 扩 seq 位，顺序 B4 → B5
- **B6 Inline data**：先验证 EFA SRD inline 实际能力再定
- **B7 Placement group**：脚本侧改，不走 UCCL PR，加到 Stage 5 launch 流程
- **A7 monitor/mwait**：收益边际
- **A8 Selective fence**：ABI break，风险高，放后期
- **C4 Attention overlap**：需 SGLang 改动，延到 SGLang 做 P2/P3 时
- **C5 Speculative combine**：依赖 C6 + C1 完成才能做

---

## 5. 对 Stage 5 benchmark 的影响

**Run 变体建议**（在 SBO Run 矩阵基础上扩展）：

| Run | 配置 | 预期 P50 ITL | 预期 P99 ITL |
|---|---|---|---|
| R0 | baseline UCCL-EP HEAD | 1500 µs | 3500 µs |
| R1 | + SBO Sprint A（Scheme A GPU spin）| 1200 | 3000 |
| R2 | + SBO Sprint B（Scheme B CPU spin）| 1150 | 2850 |
| **R3** | + PR-X1 (A6 NUMA) + PR-X3 (B2 SL) | 1080 | 2700 |
| **R4** | + PR-X4 (C3 clean-elision) + PR-X5 (C2 early-drop) | 880 | 2200 |
| **R5** | + PR-X6 (C1 persistent kernel) | **620** | **1600** |
| R6 | + PR-X7 (A1 QP LB) + PR-X10 (B1 multi-NIC) | 560 | 1400 |
| R7 | + PR-X9 (A5 straggler degrade)，Spot 场景 | 580 | **900**（Spot 抖动消失）|

**相对 R0 全链路提升：P50 -63%，P99 -74%**。

---

## 6. 致命陷阱（实施前必须核对）

1. **A1 dynamic QP + receiver barrier 冲突**：`USE_RECEIVER_BARRIER` 假设 per-expert FIFO 顺序。gate `!USE_RECEIVER_BARRIER` 或把 ordering 编码到 wr_id 高位。
2. **A5 soft degrade 的正确性风险**：zero-fill 一个 rank 相当于丢一部分 token 贡献，精度下降。Decode 可接受（用户看到一个 token 的 logits 略偏），训练不可接受。gate `UCCL_EP_STRAGGLER_DEGRADE=1` 默认关。
3. **A2 selective signaling 和 `MEASURE_PER_VERB_LATENCY` 冲突**：debug 宏假设每 CQE 都能看到。自动禁用 debug 宏。
4. **B1 multi-NIC 的对称性**：两端必须同步扩 `dst_data_qpn_by_ring`，rendezvous 协议要升版本。
5. **B3 max_send_sge=2 和 `efa-direct`**：`efa-direct` RMA 只支持 1 IOV；UCCL 直接走 libibverbs 绕过 libfabric，以 `efadv_query_device.max_sq_sge` 为准。先 query 再 assert。
6. **C1 persistent kernel 和 EFA 非 coherent flag-bit**：Hopper 和 Grace 不同。需要 `cudaHostAllocMapped` + `__threadfence_system()` 配合。写 memory model 证明。
7. **C2 early-drop 对 combine recv 侧副作用**：如果 proxy 不发某 dst_rank 的某 expert 数据，对端 combine 的 `rdma_recv_flag` 永远不到 → 死等。必须让对端也知道 "这个 slot 不会来"——可能复用现有 `atomic_clean_flag`。
8. **C3 clean-elision 竞态**：`low_latency_buffer_idx` ping-pong 时，GPU 读新 idx 和 CPU 写 dirty set 的 ordering 要 fence 一致。
9. **B6 inline 和 B2 SL 叠加**：SL 切换可能影响 inline 生效范围。需要分 QP 测试。

---

## 7. 和现有工作的叠加 / 接续关系

**现在已完成 / 在做**：
- PR #904（CPU timeout env）—— 和本文档所有 lever 正交
- PR #903（__threadfence + __nanosleep）—— A8 的前置，先合 #903 再做 A8
- Sprint A/B/C（SBO）—— 本文档 lever 全部在 SBO **之上** 再加收益

**第二批 PR 建议顺序**（复述）：
```
Sprint A (SBO 兼容底座) ──┬── PR-X1 (A6 NUMA)           ── 最先 ship，零风险
                          ├── PR-X2 (A2 selective sig)
                          ├── PR-X3 (B2 SL 分流)
Sprint B (SBO EFA 独占) ──┤
                          ├── PR-X4 (C3 clean-elision)
                          ├── PR-X5 (C2 early-drop)
                          ├── PR-X6 (C1 persistent kernel) ── 最大 lever
Sprint C (Blackwell) ─────┤
                          ├── PR-X7 (A1 QP load balance)
                          ├── PR-X8 (A4 per-peer budget)
                          ├── PR-X9 (A5 straggler degrade)
                          └── PR-X10 (B1 multi-NIC 聚合)
```

---

## 8. 关键代码位置索引

**CPU proxy 核心路径**：
- `ep/src/proxy.cpp:469` `run_sender` 主循环
- `ep/src/proxy.cpp:603-754` `post_gpu_command` / `post_gpu_commands_mixed`
- `ep/src/proxy.cpp:545-601` `notify_gpu_completion`（CQE poll）
- `ep/src/proxy.cpp:119-138` `pin_thread_unique`
- `ep/src/uccl_proxy.cpp:59-87` host-mapped atomic buffer

**RDMA / EFA 配置**：
- `ep/src/rdma.cpp:884-952` `create_srd_qp_ex`（SL / inline / SGE）
- `ep/src/rdma.cpp:487-495` NIC 分配
- `ep/src/rdma.cpp:1411-1418` normal mode post
- `ep/src/rdma.cpp:1834` **fast mode 单 QP 瓶颈**
- `ep/src/rdma.cpp:1437, 1866, 2838` SIGNALED 调用点

**常量 / 编译选项**：
- `ep/include/common.hpp:30` `EFA_QP_LOW_LATENCY_SERVICE_LEVEL`
- `ep/include/common.hpp:66` `kMaxInflightLowLatency=32`
- `ep/include/common.hpp:85` `kReorderingBufferSize=16` (4 bit)
- `ep/include/common.hpp:68-69` `kChannelPerProxy=8`, `kNumProxyThs=4`
- `ep/include/uccl_ibgda.cuh:108` inflight 流控检查点

**Kernel 核心**：
- `ep/src/internode_ll.cu:40-47` `clean_low_latency_buffer`
- `ep/src/internode_ll.cu:735-1300` combine kernel
- `ep/src/internode_ll.cu:1095-1112` combine recv rdma_recv_flag spin
- `ep/include/ring_buffer.cuh:431-483` `atomic_set_and_commit`
- `ep/include/ring_buffer.cuh:57-90` `TransferCmd` 结构

**基线数据**：
- `results/stage2-p5en-2026-04-23/SUMMARY.md` combine 297-322 µs

---

## 9. 等用户决策的 3 个问题

1. **Sprint A/B/C 后直接接 PR-X1-X3（小 diff 高收益组）还是先做 C1 持久 kernel（最大单点）？**
   - 倾向 X1-X3 先做——ship fast 拿收益，C1 diff 大需要更多 review 时间
2. **A5 straggler soft degrade 要做吗？**
   - 倾向做但 default off——Spot 场景明显价值，训练场景风险
   - 需要先在 decode 评估精度影响（1 rank 零贡献 ≈ top-8 实际变 top-7，精度损失 < 1% if expert 分布均匀）
3. **B1 multi-NIC 聚合（单 GPU 带宽 2×）的优先级？**
   - 2 周工作量大，但是决定 p5en 天花板的关键
   - 对 Stage 5 bench 数字最显眼
   - 倾向在 Sprint C（Blackwell）完成后、SGLang P2 开始前做
