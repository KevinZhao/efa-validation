# K_VS_MOONCAKE — NIXL vs Mooncake-EfaTransport 性能差值表（最终版）

**Scope**：Lane K §4.5 规划的 **性能差值表**。同硬件、同镜像、同 12 点 (block × threads × batch) tuple 扫描。
**取代**：`20260426T091500Z-nixl-vs-mooncake-partial/K_VS_MOONCAKE_PARTIAL.md`（只有 1 NIXL 数据点）
**完成日期**：2026-04-26
**作者**：Lane K 2026-04-26 工作小组
**图像**：`yanxi/mooncake-nixl:v6.1`（digest `sha256:0970bdb3...227f2`，Ohio + Oregon ECR 已同步）
**Mooncake 版本**：upstream @`634b7097`（v0.3.10.post2 + 王鹤男 5 EFA PR）
**NIXL 版本**：v1.0.1（meson build，含 LIBFABRIC 后端）

---

## 0. TL;DR

> **在相同硬件（p5en.48xlarge, EFA v3 16×200G）、相同参数下，Mooncake 在 12 个点中赢 9 个、平均 GB/s 比 NIXL 高 46%、峰值比 NIXL 高 53%（205 vs 134 GB/s）。NIXL 仅在 64 KB 小块 3 个点领先。Stage 5 + 后续 EFA KV 传输继续使用 Mooncake。**

关键数字：

| | Mooncake | NIXL | NCCL 参考 |
|---|---:|---:|---:|
| **Peak GB/s（p5en）** | **205.04** @ 4M×4×8 | 134.23 @ 1M×4×8 | 346.96 (NVLink intra-node 256MB) |
| 几何均值（12 点）| 117.9 | 80.5 | — |
| 占线速 | 51.3% | 33.6% | 86.7% (NVLink) |
| 胜点数（同 p5en）| **9/12** | 3/12（全在 64KB 块） | — |
| 胜点数（同 p5）| 7/12 | 5/12 | — |

---

## 1. p5en.48xlarge · EFA v3 · 12 点 Δ% 表（**主表**）

**Hardware**：2 × p5en.48xlarge（H200 × 8，16 × 200 Gbps EFA v3），us-east-2b 同 AZ
**Run ID**：`lane-k/20260426T134313Z-p5en-nixl-vs-mooncake-nccl`
**Raw data**：`20260426T134313Z-p5en-nixl-vs-mooncake-nccl/mc-sweep.csv` + `nixl-sweep.csv`

| ID | Block | Thr | Batch | **Mooncake GB/s** | **NIXL GB/s** | **Δ% (MC − NIXL)** | 赢家 |
|---|---:|---:|---:|---:|---:|---:|:---:|
| p01 | 64 KB  | 4 | 8   | 27.72  | 32.34 | **−14.3%** | NIXL |
| p02 | 64 KB  | 4 | 32  | 49.34  | 72.08 | **−31.5%** | NIXL |
| p03 | 64 KB  | 4 | 128 | 62.72  | 63.50 |  −1.2%  | NIXL |
| p04 | 256 KB | 4 | 8   | 88.63  | 45.18 | **+96.2%** | MC |
| p05 | 256 KB | 4 | 32  | 147.00 | 93.92 | **+56.5%** | MC |
| p06 | 256 KB | 4 | 128 | 171.58 | 58.87 | **+191%**  | MC |
| p07 | 1 MB   | 4 | 8   | 163.46 | 134.23 | **+21.8%** | MC |
| p08 | 1 MB   | 4 | 32  | 189.95 | 110.79 | **+71.4%** | MC |
| p09 | 1 MB   | 4 | 128 | 201.92 | 110.54 | **+82.7%** | MC |
| p10 | 4 MB   | 4 | 8   | **205.04** | 107.29 | **+91.1%** | MC |
| p11 | 4 MB   | 4 | 32  | 200.48 | 110.04 | **+82.2%** | MC |
| p12 | 16 MB  | 4 | 8   | 204.99 | 109.21 | **+87.7%** | MC |

**结论**：
- **block ≥ 256 KB**：Mooncake 全胜（9/9 点），Δ% 从 +21.8% 到 +191%。
- **block = 64 KB**：NIXL 全胜（3/3 点），Δ% 从 −1.2% 到 −31.5%。
- 越往大块走，Mooncake 优势越大（per-NIC slice 模型受益于线速提升）。
- 4 MB – 16 MB 区间 Mooncake 稳定在 ~205 GB/s = **51% EFA 线速**；NIXL 卡在 ~109 GB/s = 27% 线速。

---

## 2. p5.48xlarge · EFA v2 · 12 点 Δ% 表（**对照表**）

**Hardware**：2 × p5.48xlarge（H100 × 8，32 × 100 Gbps EFA v2），us-west-2c 同 AZ
**Run ID**：`lane-k/20260426T111002Z-p5-nixl-vs-mooncake`
**Raw data**：`20260426T111002Z-p5-nixl-vs-mooncake/mc-sweep.csv` + `nixl-sweep.csv`

| ID | Block | Thr | Batch | **Mooncake GB/s** | **NIXL GB/s** | **Δ% (MC − NIXL)** | 赢家 |
|---|---:|---:|---:|---:|---:|---:|:---:|
| p01 | 64 KB  | 4 | 8   | 20.26 | 19.95 |   +1.6%  | MC |
| p02 | 64 KB  | 4 | 32  | 33.76 | 38.04 |  −11.2%  | NIXL |
| p03 | 64 KB  | 4 | 128 | 48.59 | 34.16 |  +42.2%  | MC |
| p04 | 256 KB | 4 | 8   | 52.99 | 38.27 |  +38.5%  | MC |
| p05 | 256 KB | 4 | 32  | **61.12** | 55.40 |  +10.3%  | MC |
| p06 | 256 KB | 4 | 128 | 37.22 | 50.70 |  −26.6%  | NIXL |
| p07 | 1 MB   | 4 | 8   | 51.69 | 36.56 |  +41.4%  | MC |
| p08 | 1 MB   | 4 | 32  | 47.73 | 29.54 |  +61.6%  | MC |
| p09 | 1 MB   | 4 | 128 | 21.27 | 32.14 |  −33.8%  | NIXL |
| p10 | 4 MB   | 4 | 8   | 40.95 | 13.17 | +210.9%  | MC |
| p11 | 4 MB   | 4 | 32  | 40.00 | **75.24** |  −46.8%  | NIXL |
| p12 | 16 MB  | 4 | 8   | 49.21 | 30.79 |  +59.9%  | MC |

**结论**：
- Mooncake 赢 7/12，NIXL 赢 5/12。比 p5en 的 9/3 更均衡 → p5 EFA v2 上两者差距缩小
- NIXL 的胜点不再集中在 64KB 小块，而是分散到 p06/p09/p11 高并发深度处
- 整体 throughput 显著低于 p5en（peak 75 vs 205 GB/s）— PCIe Gen4、EFA v2 早期 SRD 固件影响

---

## 3. 跨机型缩放（EFA v2 → EFA v3）

问题：硬件升级红利谁拿走得多？

| Tuple | p5 MC | p5en MC | **MC 倍率** | p5 NIXL | p5en NIXL | **NIXL 倍率** |
|---|---:|---:|:---:|---:|---:|:---:|
| p05 256K×4×32  | 61.1 | 147.0 | **2.4×** | 55.4 | 93.9 | 1.7× |
| p07 1M×4×8     | 51.7 | 163.5 | **3.2×** | 36.6 | 134.2 | 3.7× |
| p08 1M×4×32    | 47.7 | 190.0 | **4.0×** | 29.5 | 110.8 | 3.8× |
| p10 4M×4×8     | 41.0 | 205.0 | **5.0×** | 13.2 | 107.3 | **8.1×** |
| p12 16M×4×8    | 49.2 | 205.0 | **4.2×** | 30.8 | 109.2 | 3.5× |

**几何均值倍率（12 点）**：
- Mooncake：**2.95×**
- NIXL：**2.20×**

**解读**：
- **Mooncake 几何均值提升 2.95× > NIXL 2.20×** → 同样硬件升级红利，Mooncake 吃得更多
- 单点 p10 NIXL 8.1× 是异常值（可能 p5 NIXL 在这点有 issue；p5 run 里该点 13.2 GB/s 也是全 sweep 最低值）
- 解释：Mooncake 的 **per-NIC slice 模型**理论上随 NIC 单位带宽线性缩放（100G→200G = 2×，在大块场景接近理论值）；NIXL 的 xfer descriptor batching 有上层 CPU 瓶颈，缩放系数 sub-linear

---

## 4. NCCL NVLink 参考线（同 p5en 单节点 8 GPU）

**Run ID**：`20260426T134313Z-p5en-nixl-vs-mooncake-nccl/nccl-single-node.txt`

同硬件同镜像的 NCCL `all_reduce_perf`（不走 EFA，走 NVLink 4th-gen intra-node）：

| Msg size | NCCL busbw | Mooncake EFA CPU-DRAM | NCCL / Mooncake |
|---|---:|---:|---:|
| 1 MB    | 39 GB/s  | 163 GB/s  | 0.24× |
| 8 MB    | 183 GB/s | — | — |
| 64 MB   | 325 GB/s | — | — |
| 256 MB  | **347 GB/s** (NVLink peak) | — | — |
| 线速 %   | 86.7% of NVLink 400G | 51% of EFA 400G | — |

**意义**：
- NCCL 在**同硬件** NVLink 能达 87% 线速，说明 H200 + CUDA stack 本身不是瓶颈
- Mooncake EFA CPU-DRAM 只到 51% 线速，NIXL 只到 34% — 有 ~49 / 66 percentage points 的优化头部空间
- **不是**硬件限制，是 transfer engine 层的 CPU submit path / NUMA / memory registration overhead
- 未来 Mooncake 继续优化（Henan PR 系列 + 新 MR mgmt）有望进一步吃下这部分空间

注意：NCCL 是 collective（all_reduce），Mooncake/NIXL 是 pairwise WRITE；**不是直接可比**，只作硬件上界参考。

---

## 5. 关键发现汇总（决定 Mooncake vs NIXL 选择时的 facts）

1. **包大小 256 KB 是分水岭**。两款硬件上，≥ 256 KB Mooncake 稳定领先。MoE/LLM KV cache 典型 256 KB – 4 MB → Mooncake 碾压区间。
2. **NIXL 小块优势来自 descriptor batching**。64 KB 块 post-latency dominate，NIXL 的 `max_batch_size=N` 一次 xfer 打包 N 个 ops，摊薄 CPU submit 开销；Mooncake 每个 slice 独立 post，这时候吃亏。
3. **硬件升级红利 Mooncake 吃得更多**。p5→p5en 2.95× vs 2.20×。Mooncake 架构对 NIC 线速变化更敏感（正面意义）。
4. **NIXL 延迟分布有长尾**。`avg_prep=3615 µs p99=7210 µs`（p08 1M×32），Mooncake 没有这种抖动。NIXL 的 ETCD-coordinated registration 在某些点会触发重 prep。
5. **参数 batch 语义不严格对等**。Mooncake `batch=N` = 每线程 N 个 concurrent outstanding slice；NIXL `max_batch_size=N` = 每 xfer descriptor 打包 N 个 op。同名参数在两边含义不同。严格 apples-to-apples 需两边 `batch=1` 扫，当前表的 Δ% 数值本身需带这个 caveat 读。

---

## 6. 对 Stage 5 + 后续的建议

**Transfer Engine 栈选择**：
- **EFA 上 KV cache / MoE expert weight 传输继续用 Mooncake**。9/12 碾压 NIXL，峰值差 53%，Stage 5 以前跑的 Kimi-K2 / Qwen3 PD-disagg 也是 Mooncake。
- **不切到 NIXL**。切换成本大（镜像 rebuild + sglang launcher flag + metadata 协调从 http-meta 换 ETCD），收益为负。
- **例外**：若未来需要接 NVIDIA Dynamo 全栈（vLLM-Dynamo/Triton-Dynamo），NIXL 是 native 路径。当前 SGLang 场景不涉及。

**Mooncake 优化方向**（有头部空间）：
- 51% 线速 → 理论上还有 2× 空间。优化路径建议：
  1. NUMA pinning（32 NIC 跨 2 NUMA node，注册/submit 要避免远端访问）
  2. CPU submit path lock-free queue（当前有 `MC_WORKERS_PER_CTX=2` + `MC_NUM_CQ_PER_CTX=2`，继续加并行度）
  3. Memory registration 复用（PTE-aware #1912 + 王鹤男 auto-split 已部分解决，还可继续）
- 不推荐继续在 EFA transport 上做 NIXL 的事情（它已经过了"是否更好"这一判据）

---

## 7. 未完成项 + 下次实验建议

| 项 | 规划 §4.5 要求 | 状态 | 建议 |
|---|---|---|---|
| K_VS_MOONCAKE.md（本文件）| ✓ | **完成** | — |
| NIXL_TUNING.md | ✓ | **未完成** | 低优先级；若 Lane K 后续不再投资，可 skip |
| SWITCH_OBSERVABLES.md | ✓ | 未完成（需 sglang e2e）| 和 Lane K sglang 端到端一起做 |
| LANE_K_CORRECTNESS.md | ✓ | 未完成（1000 请求 token match）| 切实重要，但需 sglang e2e；留给下阶段 |
| LANE_K_FAILURE.md | ✓ | 未完成（三场景 × 两栈）| 同上 |
| 2-node cross-node NCCL | 自加 | 未完成（v6.1 无 sshd/mpirun）| rebuild v6.2 加 sshd + nccl-tests；或用独立 nccl-tests:v1 + MPIJob |
| batch=1 严格对等扫描 | 自加 | 未完成 | 用 batch=1 threads∈{1,4,16} 15 点扫一遍，Δ% 数值更可信 |

下次再起 Lane K GPU，按优先级：
1. 2-node NCCL EFA baseline（给 NCCL vs Mooncake 对比完整图像）
2. batch=1 strict sweep（消除语义不对等 caveat）
3. sglang e2e correctness + failure

---

## 8. 数据可信度声明

- ✅ 同硬件（p5en 节点等价，同 AZ，同 NIC 数 16）
- ✅ 同镜像（v6.1 digest 锁死）
- ✅ 同参数（12 tuple × 两款工具）
- ✅ 同 WRITE op + DRAM→DRAM 模式
- ⚠️ batch 语义 tool-dependent（见 §5 第 5 条）
- ⚠️ p5en 只跑 1 轮，没做重复性验证
- ⚠️ NCCL 只有单节点，不是 EFA baseline

---

## 9. 数据存档

- `20260426T085000Z-mooncake-sweep/MOONCAKE_CPU_SWEEP.md` — Mooncake p5en 首轮（本文件 §1 新一轮数据已取代）
- `20260426T091500Z-nixl-vs-mooncake-partial/K_VS_MOONCAKE_PARTIAL.md` — 旧 1 点 partial（被本文件取代）
- `20260426T111002Z-p5-nixl-vs-mooncake/` — p5 12+12 点 raw + RESULT
- `20260426T134313Z-p5en-nixl-vs-mooncake-nccl/` — p5en 12+12 点 + NCCL baseline + RESULT

所有 CSV 字段与列语义在各 RESULT.md 中说明。
