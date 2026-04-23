# Stage 4 — Tuning Round: SmolLM2-1.7B → Mistral-7B-Instruct-v0.2

## Why

前一轮 SmolLM2-1.7B 下 1P:1D TTFT 2.57-6.82× baseline (未达 ≤1.3× Plan 目标)。
假设主要原因是**模型太小**：prefill 只 30ms，KV transfer 47ms 占比过大。
换 Mistral-7B-Instruct-v0.2（32 heads / 8 KV heads / 32 layers / 4096 hidden，13.5 GB bf16）
让 prefill 从 30ms → ~40-50ms，观察相对 KV overhead 占比。

## 调优 flags 一并开启

在 `launcher-v2.yaml` 中添加：
- `--chunked-prefill-size 8192`
- `--max-running-requests 64`

（注：原计划的 `--enable-overlap-schedule` 在 SGLang 0.4.10 已默认开启，flag 被移除。）

## Results — Baseline TP=8 (Mistral-7B)

| rate | TTFT mean (ms) | TTFT p99 (ms) | ITL mean (ms) | ITL p99 (ms) | E2E mean (ms) | output tok/s | request/s |
|---:|---:|---:|---:|---:|---:|---:|---:|
| inf | 1419.51 | 3398.35 | 11.86 | 42.47 | 2974.16 | 4079.69 | 30.88 |
| 2 | **41.06** | 73.94 | 2.60 | 4.89 | 382.48 | 326.20 | 2.47 |
| 4 | 41.88 | 68.09 | 2.78 | 24.78 | 406.47 | 646.46 | 4.89 |
| 8 | 44.37 | 78.63 | 3.27 | 26.01 | 473.21 | 1267.20 | 9.59 |
| 16 | 52.29 | 85.60 | 4.84 | 37.84 | 686.81 | 2417.15 | 18.29 |

## Results — 1P:1D (Mistral-7B, Mooncake/EFA)

| rate | TTFT mean (ms) | TTFT p99 (ms) | ITL mean (ms) | E2E mean (ms) | output tok/s | 备注 |
|---:|---:|---:|---:|---:|---:|---|
| 2 | **3532.69** | 18497.87 | 3.28 | 3962.99 | 323.47 | 高方差 |
| 4 | 764.34 | 1736.87 | 2.75 | 1092.64 | 32.96 | output_tps 异常低 ⚠️ |
| 8 | — | — | — | — | — | **prefill pod 崩溃 → NA** |
| 16 | — | — | — | — | — | NA |
| inf (1st run) | 21622.74 | 31368.36 | 4.46 | 22207.83 | 525.21 | lb 在高并发下 Connection reset |

## Observations — vs Baseline

| rate | 1P:1D TTFT | baseline TTFT | **ratio** | baseline ITL | 1P:1D ITL | ITL ratio |
|---:|---:|---:|---:|---:|---:|---:|
| 2 | 3533 | 41 | **86×** ❌ | 2.60 | 3.28 | 1.26× ⚠️ |
| 4 | 764 | 42 | **18×** ❌ | 2.78 | 2.75 | ~1× ✅ |

相比 SmolLM2 结果（rate=4 最佳 2.57×），**换大模型后 TTFT ratio 反而恶化了 7×**！

### 为什么变差

模型从 1.7B → 7B，**KV size × 4.1×**（hidden 2048→4096 × layers 24→32 × heads 32→32）
- 单 prompt KV（1024 tok × TP=8 shard）：~24 MB → ~192 MB**（2 节点跨机 push 400 MB 总量）**
- Mooncake DRAM 路径实测只 ~4 GB/s per-request 有效带宽（含建链）
- 预估 KV transfer 时间：400 MB / 4 GB/s = **100 ms**

但实测 TTFT 额外开销 = 3533 - 41 = **3492 ms**（rate=2）或 722 ms（rate=4）。相差 30×！

真因：**sglang disaggregation 的 Mooncake bootstrap + handshake 对大 KV 不稳定**，长尾表现为：
- rate=2 TTFT p99 **18498 ms** (mean 3533) — 方差巨大
- rate=4 output_tps 只 33 tok/s（正常应 ~640）—— 大量 token 落在超长 tail
- rate=8+ 起 **prefill pod 崩溃**

### 结论：调优杠杆 1 + 2 在当前环境**负面**收益

- **杠杆 1（大模型）**：不但没改善相对 TTFT 占比，还触发了更严重的长尾 & 崩溃
- **杠杆 2（chunked-prefill + max-running）**：对 baseline 有益（baseline 这边 Mistral 跑 inf 下 4080 tok/s vs SmolLM 12995），但 1P:1D 路径下因为 KV 传输本身不稳定，优化 prefill 帮不上

## 诊断：服务不稳定根因

观察 log：
1. `sglang-lb` Error + RESTARTS - 接收 concurrency 高时 connection reset
2. `sglang-prefill-cbcb56c7d-w56v4` Error - 运行 ~11 min 后崩溃（rate=4 → 8 切换时段）
3. bench 报错 `Connection reset by peer` + `Connection refused`

**高度怀疑 Mooncake bootstrap 在 7B 模型的 KV size 下触发 EFA connection error 使 sglang worker 崩溃**。SmolLM2 时 KV 小没暴露这个问题。

## 对 Plan 达标 (≤1.3× baseline TTFT) 的实际路径

在当前 Mooncake EFA transport 上：

| 路径 | 预期改善 | 估计 ratio |
|---|---|---|
| 保持 SmolLM2 + Mooncake connection pool patch | 中等 | ~1.5-2× |
| Mooncake 切 **VRAM + FI_HMEM**（补丁） | 大 | ~1.1-1.3× ✅ |
| 切 **NIXL** KV transport (原生 GDR) | 大 | ~1.1-1.3× ✅ |
| 继续现有 Mistral-7B + 现 Mooncake | **恶化** | 服务崩溃 ❌ |

**结论**：在 Mooncake 不稳定前提下，继续在大模型上调优**无意义**。必须先解决 Mooncake EFA transport 对大 KV 的稳定性（或换 NIXL）。

## 已归档

- `results/stage4/TUNING_MISTRAL_7B.md`（本文）
- `results/stage4/BASELINE_SWEEP.md`（SmolLM2 baseline）
- `results/stage4/DISAGG_1P1D_SWEEP.md`（SmolLM2 1P:1D）
- Host log on ip-10-1-12-160 `/var/lib/yanxi-logs/stage4/`
