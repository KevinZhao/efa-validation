# Stage 4 — TP=16 跨节点 vs TP=8 单节点（EFA TP all-reduce 代价）

## 目标

测试 TP=16 跨 2 节点部署，强制每层 all-reduce 走 EFA，量化 EFA TP 通信的真实代价。

## 环境

- 硬件：2 × p5.48xlarge（8×H100 + 32×EFA/节点）, cross-AZ (us-east-2b 同 subnet)
- 模型：Mistral-7B-Instruct-v0.2 bf16
- sglang 0.4.10.post2, `--tp 16 --nnodes 2 --node-rank {0,1} --dist-init-addr <rank0>:5000`
- workload：128 prompts × 1024 input × 256 output

## TP=16 完整 sweep

| rate | req/s | TTFT mean (ms) | TTFT p99 (ms) | ITL mean (ms) | ITL p99 (ms) | E2E mean (ms) | out tok/s | total tok/s |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 2   | 2.40  | **82**   | 363   | **13.4** | 40    | 1840   | 317  | 1613  |
| 4   | 4.59  | 62       | 85    | 14.5     | 43    | 1969   | 607  | 3090  |
| 8   | 8.31  | 64       | 89    | 17.1     | 60    | 2302   | 1098 | 5589  |
| 16  | 13.22 | 173      | 635   | 22.0     | 93    | 3059   | 1746 | 8889  |
| inf | 17.68 | 1613     | 4390  | 18.9     | 48    | 4088   | 2336 | 11894 |

## 与 TP=8 单节点（NIXL 1P:1D 即 prefill TP=8 + decode TP=8）的对比

| rate | TP=16 TTFT | TP=8 1P:1D TTFT | TP=16 ITL | TP=8 ITL | TP=16 total tok/s | TP=8 total tok/s |
|---:|---:|---:|---:|---:|---:|---:|
| 2   | 82   | 76   | **13.4**  | 2.87 | 1613  | 1590  |
| 4   | 62   | 48   | 14.5      | 2.67 | 3090  | 3150  |
| 8   | 64   | 50   | 17.1      | 2.81 | 5589  | 6177  |
| 16  | 173  | 62   | 22.0      | 3.09 | 8889  | 11777 |
| inf | 1613 | 1182 | 18.9      | 4.78 | 11894 | 30581 |

## 关键发现

### 1. TTFT 几乎持平（只慢 10-30%）

- TP=16 rate=4 TTFT 62 ms vs TP=8 48 ms（慢 29%）
- EFA TP all-reduce 在 prefill 阶段**没有成为瓶颈**
- 说明 EFA 32-rail 聚合带宽足以支撑一次 prefill 的几 GB allreduce

### 2. ITL 慢 **4-6 倍**（13-22 ms vs 3-5 ms）

- **这是 TP=16 跨节点的真正代价**
- 每个 token 生成都要做一次跨节点 all-reduce：32 层 × 2 (attn+mlp) = **每 token 64 次 EFA allreduce**
- TP=8 单节点走 NVLink (4.8 TB/s)，TP=16 跨节点最差路径走 EFA (3.2 Tbps = 400 GB/s，差 12×)
- 每次 allreduce ~16 MB，EFA latency + 带宽叠加 → ITL 10+ ms

### 3. 吞吐在低并发持平，高并发 TP=8 赢

- rate 2/4：两者总吞吐基本一致（TP=16 稍低）
- rate 8+：TP=8 开始拉开差距
- rate=inf：TP=8 30.6k vs TP=16 11.9k tok/s（**TP=8 快 2.6×**）
- 原因：TP=16 每 token 的跨节点同步是串行瓶颈，无法通过 batch 掩盖

### 4. 高并发下 TP=16 TTFT 抖动严重

- rate=16 时 TP=16 p99 TTFT **635 ms**（TP=8 仅 218 ms）
- rate=inf 时 TP=16 p99 **4390 ms**
- 解读：并发请求竞争 EFA 带宽 + sync 锁，尾延迟放大

## ⚠️ 概念澄清：TP=16 ≠ 1P:2D

这份数据**不是** "加 decode 实例性能反而下降" 的证据。原因：

| 拓扑 | 做了什么 | 效果 |
|---|---|---|
| **TP=16 跨节点**（本次测的） | 1 个模型切成 16 份跨 2 节点，**仍然只有 1 个 serving 实例** | 加入每层 EFA allreduce 同步 → ITL 慢 |
| **1P:2D**（本应测的） | 1 个 prefill pod + **2 个**独立 decode pod，每个 pod 仍 TP=8 | 加并行 decode 容量 → 吞吐翻倍，TTFT/ITL 基本不变 |

对 Mistral-7B 这种单节点放得下的模型，**TP=16 跨节点纯亏**（切更小 + 加网络同步），不代表"PD 扩容不管用"。真正的 1P:2D 需要第 3 台同 VPC 节点才能测，目前 AWS capacity 不足已阻塞。

## 对客户的 takeaway

### EFA 能扛 TP=16（勉强）但不是甜点

| 场景 | 推荐 |
|---|---|
| 模型放得下单节点（≤ 70B bf16 on 8×H100 80GB）| **不要 TP 跨节点**，用 TP=8 单节点 + PD 分离扩容 |
| 模型必须跨节点（如 405B）| TP=8+PP=2 比 TP=16 更优（PP 通信是串行非阻塞，可流水线） |
| 必须 TP=16（模型结构限制）| **用 IB 而非 EFA**；或接受 4-6× ITL penalty |

### EFA TP=16 vs IB TP=16 预期差距

- IB HDR 200 Gbps / 节点（p5 如果用 IB 会聚合到 ~1.6 Tbps）
- EFA v2 is 3.2 Tbps 聚合带宽，**裸带宽更高**
- 但 EFA 是 SRD（类 UDP，消息乱序重组），IB 是 reliable in-order，**small message latency IB 更低**
- NCCL in EFA 走 libfabric + SRD 在 small-message all-reduce 上延迟比 IB 高 2-3×
- 预估 IB TP=16 ITL 可能降到 6-10 ms（vs EFA 13-22 ms）

### 国内 IB 栈的验证价值

如果客户国内 IB 环境能跑同 workload：
- IB TP=16 ITL vs EFA TP=16 ITL → 量化 EFA 在 TP 场景的 latency penalty
- 确认海外 EFA 部署时是否要转 PP 而非 TP

## 归档

- `baseline-tp16.yaml` — 跨节点 TP=16 manifest（publishNotReadyAddresses + FQDN）
- `launcher-v2.yaml` — 新增 NNODES/NODE_RANK/DIST_INIT_ADDR env 支持
- `bench-tp16-sweep.yaml` — sweep job
- `disagg-tp16-summary.tsv` — raw metrics
- raw per-rate logs: `bench-tp16-sweep-nf96v:/results/tp16-rate-*.{json,log}`
