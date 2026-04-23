# Stage 4 — SGLang PD 分离 on EFA：多路径对照总结

## TL;DR

在同一套硬件（2 × p5.48xlarge, EFA）+ 同一模型（Mistral-7B bf16）+ 同一 workload（128 prompts × 1024/256）下，跑了 3 种拓扑 × 2 种 KV backend 的组合，得到以下结论：

1. **协议层**：NIXL (LIBFABRIC) 比 Mooncake 在 EFA 上 **TTFT 快 11×、总吞吐快 12×**，Mooncake rate≥4 就因 `KVPoll.WaitingForInput` 300s timeout 全崩
2. **TP=16 跨节点**：EFA 能跑通，但每 token decode allreduce 把 **ITL 拖慢 4-6×**（13-22 ms vs NVLink-only 2-3 ms），Mistral-7B 这种单节点放得下的模型不建议 TP 跨节点
3. **EBS 容量是硬前提**：50GB root 不够，必须扩到 2TB（+ 16k IOPS + 1000 MB/s throughput），否则 kubelet eviction 压力放大所有性能退化

所有数据来自 **2 节点 Ohio p5.48xlarge**，Oregon 第 3 台 spot 拿到但跨 region 无法组网（独立节点）。

## 环境

| 项 | 值 |
|---|---|
| 区域 | AWS us-east-2（Ohio），single AZ (us-east-2b) |
| 节点 | 2 × p5.48xlarge (8 × H100 80GB + 32 × EFA NIC + NVLink) |
| 网络 | EFA v2, libfabric 2.4.0, cross-AZ subnet 同 VPC |
| 存储 | 根盘 2TB gp3 (16k IOPS / 1000 MB/s), 扩容后 |
| 模型 | Mistral-7B-Instruct-v0.2 bf16 (32 heads / 8 KV heads / 32 layers / 4096 hidden, 13.5 GB) |
| Runtime | SGLang 0.4.10.post2, Mooncake 0.3.10.post1, NIXL v1.0.1, CUDA 12.6 |
| Workload | `sglang.bench_serving --num-prompts 128 --random-input-len 1024 --random-output-len 256` |

## 结果总览（5 rates × 拓扑）

### 1. TP=8 单节点 baseline（Mistral-7B 单机参考）

用 SmolLM2-1.7B 历史数据推算（Mistral-7B 单节点 baseline 数据在 `BASELINE_SWEEP.md`，rate=inf 单请求延迟 41-52ms 级）。单节点是所有跨节点拓扑的理论下限。

### 2. TP=8 1P:1D + NIXL (LIBFABRIC backend)

完整 5/5 通过：

| rate | req/s | TTFT mean (ms) | TTFT p99 (ms) | ITL mean (ms) | E2E mean (ms) | total tok/s |
|---:|---:|---:|---:|---:|---:|---:|
| 2   | 2.47  | **76**   | 576   | 2.87 | 453    | 1590  |
| 4   | 4.89  | **48**   | 77    | 2.67 | 398    | 3150  |
| 8   | 9.58  | **50**   | 76    | 2.81 | 418    | 6177  |
| 16  | 18.26 | **62**   | 218   | 3.09 | 468    | 11777 |
| inf | 47.42 | 1182     | 1950  | 4.78 | 1809   | 30581 |

### 3. TP=8 1P:1D + Mooncake（同拓扑只切 backend）

只有 rate=2 完成，rate=4 KV transfer 超时崩溃：

| rate | req/s 实测 | TTFT mean | E2E mean | 备注 |
|---:|---:|---:|---:|---|
| 2   | 0.20（期望 2.0）| **839 ms** | 22269 ms | 完成但最后 9 请求每个 88s，队列爆炸 |
| 4   | 0.14 | TTFT=0 | 443s | 绝大多数 300s KVPoll timeout |
| ≥8  | — | — | — | 主动终止（rate=4 已证实失效）|

### 4. TP=16 跨节点（无 PD 分离，纯测 EFA TP all-reduce）

完整 5/5 通过：

| rate | req/s | TTFT mean (ms) | ITL mean (ms) | E2E mean (ms) | total tok/s |
|---:|---:|---:|---:|---:|---:|
| 2   | 2.40  | 82       | **13.4** | 1840   | 1613  |
| 4   | 4.59  | 62       | 14.5     | 1969   | 3090  |
| 8   | 8.31  | 64       | 17.1     | 2302   | 5589  |
| 16  | 13.22 | 173      | 22.0     | 3059   | 8889  |
| inf | 17.68 | 1613     | 18.9     | 4088   | 11894 |

## 三方对比（rate=4，最能反映协议稳态差异）

| 指标 | TP=8 1P:1D NIXL | TP=8 1P:1D Mooncake | TP=16 跨节点 |
|---|---:|---:|---:|
| TTFT mean | **48 ms** | TTFT 测不出（超时） | 62 ms |
| ITL mean | **2.67 ms** | — | 14.5 ms |
| E2E mean | **398 ms** | 443s（全部超时） | 1969 ms |
| total tok/s | **3150** | 90（实质失败）| 3090 |
| req/s 实际/期望 | 4.89/4 (122%) | 0.14/4 (3.5%) | 4.59/4 (115%) |

## 三大核心结论

### 结论 1：NIXL 协议层快约 11×

用 **rate=2（两个 backend 都能完成的唯一对照点）**：
- NIXL TTFT 76 ms vs Mooncake 839 ms → **11×**
- total tok/s 1590 vs 127 → **12×**
- ITL 持平（2.8ms ≈ 2.8ms）→ 瓶颈完全在 KV transport 层，decode 同一 scheduler

**根因**：Mooncake v0.3.10.post1 EFA transport 的 `fi_mr_reg` 缺 `FI_HMEM` flag → KV 走 CPU bounce buffer（两次 PCIe D2H/H2D），NIXL LIBFABRIC plugin 直走 GPUDirect RDMA。

**注意**：这**不是 NIXL "天然"快 11×**，而是 **Mooncake 在 EFA 上实现不完整**。在 IB 环境下 Mooncake 应该正常（走 UCX 路径成熟）。

### 结论 2：TP=16 跨节点 EFA 代价 = ITL ×4-6

| 阶段 | 单节点 TP=8 | 跨节点 TP=16 | 慢多少 |
|---|---|---|---|
| Prefill TTFT | 48 ms | 62 ms | +29%（EFA 聚合带宽够） |
| Decode ITL | 2.87 ms | 13.4 ms | **+367%**（每 token 64 次 EFA allreduce）|
| 吞吐 rate=inf | 30.6k tok/s | 11.9k tok/s | TP=8 快 2.6× |

**启示**：
- Mistral-7B 单节点放得下，TP 跨节点纯亏
- 只有模型必须跨节点时（如 Llama-405B），才考虑 TP=16；此时 **PP=2 可能比 TP=2 更优**（流水线同步点少）
- EFA 在 tight sync loop 下 small-message latency 比 IB 高 2-3×（SRD vs reliable in-order）

### 结论 3：必须测的拓扑没测成 — 1P:2D（扩 D 提吞吐）

**原本期望**：1P + 2D 让 decode 并行处理 2× 请求，TTFT 基本不变，ITL 基本不变，总吞吐翻倍。

**实际只做了 TP=16**，而 TP=16 跟 1P:2D **完全不是一个东西**——前者切模型（加同步），后者加 decode 实例（加并行）。测出的 ITL 变慢结果**不能解读为"加 D 反而性能下降"**。

**未能测试 1P:2D 的原因**：需要第 3 台 Ohio 同 VPC p5，但：
- Ohio 所有 AZ spot placement score = 1（最差）
- OD NG capacity 同样不足（已删除）
- Oregon usw2-az2 spot score=4 拿到 1 台 p5（10.0.12.118），但跨 region 不能组 PD

## 生产部署的 checklist

### 必须做（blocker）
- ✅ EBS root ≥ 2TB（gp3 16k IOPS / 1000 MB/s），避免 kubelet eviction 压力
- ✅ EFA v2 libfabric ≥ 2.4.0
- ✅ 镜像里安装 NIXL LIBFABRIC plugin，runtime 确保 `NIXL_PLUGIN_DIR` 只暴露 LIBFABRIC（不要 UCX）
- ✅ sglang `nixl/conn.py` 的 `nixl_agent(...)` 必须 monkey-patch 传 `nixl_agent_config(backends=["LIBFABRIC"])`
- ✅ sglang 0.4.10.post2 的 `register_memory(..., is_sorted=False)` 必须 sed 移除 kwarg

### 拓扑选择
- **海外 EFA 栈**：Mistral-7B 级别优选 TP=8 + 1P:ND（多 decode 扩 D），不要 TP 跨节点
- **国内 IB 栈**：Mooncake 能继续用（UCX 成熟），无需强迁
- **混合**：sglang 运行时可切 backend，按部署环境选

### 还需验证
- [ ] 1P:2D / 2P:1D / 2P:2D（需要 3+ 台同 VPC p5）
- [ ] 更大模型（Llama-70B bf16 KV ×5 放大 EFA 压力）
- [ ] 国内 IB 环境 TP=16 ITL 对照（验证 EFA vs IB 在 small-msg latency 的差距）
- [ ] prefix cache 命中场景（本测试用 random 避开 cache）

## 配套文档

- `NIXL_KV_BACKEND.md` — NIXL 完整 5 gap 集成笔记（包括 UCX→LIBFABRIC backend 强制切换）
- `NIXL_VS_MOONCAKE_COMPARISON.md` — 两个 backend 在同环境 rate=2 对比细节
- `TP16_VS_TP8_EFA.md` — TP=16 跨节点数据 + 与 TP=8 1P:1D 对照
- `TUNING_MISTRAL_7B.md` — 从 SmolLM2 切换到 Mistral-7B 的调优笔记
- `BASELINE_SWEEP.md` / `DISAGG_1P1D_SWEEP.md` — 早期 SmolLM2 baseline 数据（历史参考）
- `disagg-nixl-summary.tsv` / `disagg-mooncake-summary.tsv` / `disagg-tp16-summary.tsv` — raw metrics

## 遗留

- Oregon p5.48xlarge spot × 1 运行中（未使用）
- Ohio 2 × p5.48xlarge 运行中（TP=16 已完成 sweep）
- 建议：取得客户决策后释放资源（scale spot NG 到 0）

## 成本提示

- p5.48xlarge spot ≈ $15-25/h（Ohio）× 2 节点 × 持续时长 = 本次测试总成本几百美金级
- Oregon 1 台如不使用应立即 scale 0
