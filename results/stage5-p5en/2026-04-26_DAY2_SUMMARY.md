# Stage 5 Day 2 — 2026-04-26 执行总结

> **核心收获**：完整的 Kimi-K2 PD scaling 画像 — 1P:1D → 1P:3D 吞吐 +75% (rate=4)；推高 rate=6 后 1P:3D 实际达 3532 tok/s（+150% vs R1a）；ISL=4096 时 total 10k tok/s 级。**2P:2D 否决假说**：对 Kimi-K2 decode 永远是瓶颈，加 prefill 纯浪费。

## 今日战绩

| Run | 拓扑 | 配置 | Total tok/s | Median TPOT | 状态 |
|---|---|---|---|---|---|
| **R1c baseline** | 4×p5en 1P:3D | rate=4, ISL=1024, OSL=512, 128 prompts | **2474** | 21 ms | ✅ **PASS**（完成 PD 曲线三点） |
| **R1c rate sweep** | 同上 | rate=6 | **3532** | 17 ms | ✅ **真实工作点** |
| R1c rate sweep | 同上 | rate=8 | 2929 | 25 ms | decode 饱和起步 |
| R1c rate sweep | 同上 | rate=12 | 2646 | 47 ms | 全面饱和 |
| R1c rate sweep | 同上 | rate=16 | 3055 | 44 ms | queue 稳态 plateau |
| **R1c ISL sweep** | 同上 | ISL=2048 rate=6 | **5309** (input 4322 + output 987) | 18 ms | prefill 仍有富余 |
| **R1c ISL sweep** | 同上 | ISL=4096 rate=6 | **10005** (input 8958 + output 1047) | 15 ms | 🏆 最高 mixed throughput |
| R1c ISL sweep | 同上 | ISL=8192 rate=4 128 prompts | 11064 (input 10378 + output 686) | 14 ms | chunked-prefill 2 chunks |
| **R2 2P:2D** | 4×p5en 2P:2D | rate=4 | 1900 | 17 ms | ❌ 劣于 R1c 23% |
| **R2 2P:2D** | 同上 | rate=6 | 1918 | 40 ms | ❌ 劣于 R1c 46% |

## 完整 Kimi-K2 PD scaling 曲线（确定版）

| 拓扑 | # GPU | 最优工作点 | Total tok/s | Median TPOT | 备注 |
|---|---|---|---|---|---|
| 1P:1D (R1a) | 16 | rate=4 | 1412 | 46 ms | Day 1 baseline |
| 1P:2D (R1b) | 24 | rate=4 | 1799 | 30 ms | Day 1 |
| **1P:3D (R1c)** | **32** | **rate=6** | **3532** | **17 ms** | Day 2，+150% vs R1a |
| **1P:3D ISL-heavy** | **32** | **rate=6 ISL=4096** | **10005** | **15 ms** | Day 2，长 prompt 场景甜点 |
| 2P:2D (R2) | 32 | rate=6 | 1918 | 40 ms | Day 2 NEGATIVE — 等价 R1b |

## 核心认知修正（Day 2 逆转 Day 1 的误判）

### 1. Rate=4 严重低估 R1c 能力

- Day 1 写 DAY1_SUMMARY 时用 rate=4 横向比 R1a/R1b/R1c，R1c 只看到 2474 tok/s (+75%)
- 实际 rate=6 下 R1c 有 3532 tok/s（+150%）— Day 1 rate=4 低估了 1P:3D 40% 的真实能力
- **结论**：PD scaling 对比必须在**每个拓扑的最优工作点**做，不能固定 rate

### 2. R1b TTFT 回归之谜其实是 decode back-pressure

- R1b 报告说"1P:2D 下 Median TTFT 8.7 s 比 R1a 3.3 s 还差"，当时归因 prefill 堵塞
- R1c 1P:3D 下 Median TTFT 回到 1.66 s — 明显不是 prefill 问题
- **真相**：decode 槽位紧张时 scheduler 不放新 prefill 上 GPU，请求等 decode 腾位 → TTFT 虚高
- **评估 PD 拓扑时 TTFT 其实反映的是 binding queue，不是 prefill 瓶颈本身**

### 3. 2P:2D 实验直接推翻 "1P 是下一瓶颈" 假说

从 R1c rate=12 看到 P99 TTFT 36 s，当时以为 prefill 不够用。R2 用同样 4-node budget 做 2P:2D 测：
- Total throughput **反而跌到 1918 tok/s**（R1c 1P:3D 是 3532）
- Prefill pods token usage **全程 0.01-0.20**，95% 闲置
- Decode 数减到 2 就重演了 R1b 的饱和态

**根因**：Kimi-K2 (ISL=1024, OSL=512) 的 prefill vs decode compute 比约 **1:22**。加 prefill 前 prefill 已经远远没饱和；加 decode 才是真正的产能杠杆。

### 4. 长 ISL 是 R1c 1P:3D 的隐藏甜点

- ISL=4096 rate=6 产出 **10005 total tok/s**（8958 input + 1047 output）
- 比 ISL=1024 同工作点的 3532 tok/s **高 2.8×**
- 原因：长 prompt 摊分 chunked-prefill setup 开销；decode 路径几乎不受 ISL 影响
- **对长 ctx RAG / 超长 prompt 客户，R1c 1P:3D 可卖 10 GB-class token throughput**

## 沉淀的新记忆 / 更新

（`~/.claude/projects/-home-ec2-user-workspace-efa-validation/memory/`）

- `reference_hf_token.md` **新增** — HF_TOKEN 必须走 Secret 注入，解决单节点 HF 匿名限流
- 跨 session 可召回：`feedback_sps_skip_deprecated_instances.md` 今日验证有效（只扫 p5en/p5/p6-b200/p6-b300）

## 关键技术/工程收获

1. **HF_TOKEN 解决单节点限流** — Day 1 R1c 单节点 prefetch 卡在 300/959 GB；Day 2 带 token 4 节点并行 27 min 完成 3.8 TB 总量，**470-670 MB/s 稳定单节点速率**
2. **SSM StandardOutputContent 有 ~24 KB 截断** — rate sweep 4-in-1 在 rate=12 被切断；必须每个点独立 SSM 调用
3. **SSM heredoc bash 转义易坏** — 改用 file://.json 参数 + inline single-line command 替代多行 heredoc
4. **Kimi-K2 从 cold NG 到 PASS 56 min 总时长** —（NG launch 1 min + kubelet join 3 min + NVMe setup 1.5 min + prefetch 27 min + cold start 17 min + bench 40 s + docs 6 min）
5. **4 × p5en 同 AZ (use2-az2) 全天稳定，零 Spot 回收** — 2026-04-26 03:00-04:00 UTC 区间

## 资源状态（Day 2 收尾）

- Ohio `gpu-p5en-spot-useast2b`：R2 workload 删除，NG desired=0（4 台 shutting-down）
- Oregon 所有 NG：desired=0，空
- HF_TOKEN k8s Secret `hf-token`：保留在 cluster 里（下次 prefetch 复用）
- 预取权重 `/mnt/nvme/models/Kimi-K2-Instruct-0905` **已丢失**（Spot 节点 terminate 即擦除）
- Day 2 Spot 用量：4 × p5en × ~2.5h = **10 node-hour**

## Commit 汇总（Day 2）

| SHA | Subject |
|---|---|
| `80ac27c` | R1c Kimi-K2 1P:3D PASS — completes PD scaling curve |
| `8baca30` | R1c rate sweep — Kimi-K2 1P:3D ceiling ≈ 3500 tok/s |
| `3a08fee` | R1c ISL sweep — prefill ceiling ≈ 10k input tok/s at ISL=4096 |
| `9841da0` | R2 Kimi-K2 2P:2D negative result — 1P:3D > 2P:2D for same 4-node budget |

## 文件索引（Day 2 新增）

```
results/stage5-p5en/
├── r1c-kimi-k2-1p3d/
│   ├── 20260426T021500Z/RESULT.md                        # R1c 1P:3D baseline @rate=4 PASS
│   ├── 20260426T024500Z-rate-sweep/RATE_SWEEP.md        # rate 4/6/8/12/16 扫描
│   └── 20260426T031000Z-isl-sweep/ISL_SWEEP.md          # ISL 1024/2048/4096/8192 扫描
├── r2-kimi-k2-2p2d/
│   └── 20260426T033500Z/RESULT.md                        # 2P:2D NEGATIVE（假说被推翻）
└── 2026-04-26_DAY2_SUMMARY.md                            # 本文件

manifests/stage5-p5en/
├── _prefetch-hf-kimi-ohio-az2-4x.yaml                    # 带 HF_TOKEN 的 4x 并行 prefetch
├── r1c-kimi-k2-1p3d-v5-hostpath-ohio-az2.yaml            # R1c deploy
└── r2-kimi-k2-2p2d-v5-hostpath-ohio-az2.yaml             # R2 deploy

results/sps/20260426T012522Z/                             # 今日 SPS 快照（tc=4/3/2 白名单）
```

## Day 3+ 重排后优先级

原计划 Day 3 R2 (DSv3.1 TP=16) + Day 4 R4/R5。**基于今日 R2 假说被推翻，重新排优先**：

**Day 3（2026-04-27）**：
- **R1d Kimi-K2 1P:4D 或 1P:5D**（需要 5-6 台 p5en 同 AZ） — 继续推 decode scaling；用 R1c rate=6 真实工作点做对比基准
- **R1c 长 ISL + 高 rate 组合扫描**（ISL=4096 rate=8/12） — 验证长 prompt 客户场景
- **R3 GLM-4.6 rate/ISL sweep** —（GLM-4.6 不是 Kimi-K2，prefill/decode 比可能不同，需要独立验证）

**Day 4**：
- R5 GLM-5.1 FP16 准备
- Lane K microbench（Mooncake KV 跨 AZ 问题 — 用 `transfer_engine_bench` 两节点点对点）

**Day 5**：
- Lane E UCCL-EP microbench
- R4 Qwen3-235B 等 sglang upstream 修（park）

## 一句话总结

**R1c 1P:3D @rate=6 ISL=1024 = 3532 tok/s / @rate=6 ISL=4096 = 10k tok/s 是 Kimi-K2 在 p5en 上的权威数字；PD scaling 对 Kimi-K2 decode-bound，加 prefill 无意义。**
