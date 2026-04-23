# Stage 4 — 1P:1D Disaggregated Serving Sweep (SmolLM2-1.7B, 128 prompts × 1024/256)

## Config

- Model: SmolLM2-1.7B-Instruct (Llama, 32 heads / 24 layers / hidden=2048)
- Deployment: 1× Prefill TP=8 on ip-10-1-12-160 + 1× Decode TP=8 on ip-10-1-12-221 + mini_lb
- KV Transfer Backend: **Mooncake over EFA** (`--disaggregation-transfer-backend mooncake`)
- Workload: `sglang.bench_serving --pd-separated`, dataset=random, 128 prompts, input=1024, output=256
- Bench target: LB @ `sglang-lb.yanxi-validation.svc:8000`

## Results — 1P:1D（本轮）

| rate | TTFT mean (ms) | TTFT p99 (ms) | ITL mean (ms) | ITL p99 (ms) | E2E mean (ms) | output tok/s | request/s |
|---:|---:|---:|---:|---:|---:|---:|---:|
| **inf** | **3299.43** | 5236.12 | 3.68 | 8.89 | 3781.90 | 3013.39 | 22.81 |
| 2 | 160.19 | 604.84 | 1.78 | 4.16 | 393.25 | 326.47 | 2.47 |
| 4 | **77.39** | 160.28 | 1.80 | 4.44 | 313.96 | 647.91 | 4.90 |
| 8 | 1532.49 | 4597.20 | 2.40 | 5.38 | 1847.09 | 955.32 | 7.23 |
| 16 | 330.78 | 2094.85 | 2.47 | 6.04 | 655.19 | 1886.29 | 14.28 |

## vs Baseline TP=8 对比

| rate | baseline TTFT | 1P:1D TTFT | **ratio** | baseline ITL | 1P:1D ITL | ratio |
|---:|---:|---:|---:|---:|---:|---:|
| inf | 484 | 3299 | **6.82×** ❌ | 3.76 | 3.68 | 0.98× ✅ |
| 2 | 28 | 160 | **5.71×** ❌ | 1.69 | 1.78 | 1.05× ✅ |
| 4 | 30 | **77** | **2.57×** ⚠️ | 1.78 | 1.80 | 1.01× ✅ |
| 8 | 31 | 1532 | 49.4× ❌ | 1.93 | 2.40 | 1.24× ✅ |
| 16 | 32 | 331 | 10.3× ❌ | 2.50 | 2.47 | 0.99× ✅ |

**红色判据**：Plan 目标是 1P:1D TTFT ≤ 1.3× baseline。**全部 rate 均不达标**（最好的 rate=4 也 2.57×）。

**绿色判据**：ITL 全部 ≤ 1.3× baseline ✅ — Decode 端的 token-level 延迟与单机一致，说明 Mooncake KV 传输没影响解码速度。

## 解读

### 为什么 1P:1D TTFT 比 baseline 高

1. **rate=2/4**：TTFT 被 KV 传输延迟主导。每 prompt 要：prefill → KV dump → Mooncake EFA transfer → decode load → first token。
   - rate=2 下 160ms TTFT 扣除 28ms baseline prefill 时间，**KV 跨节点传输占约 130ms**（input=1024 token × hidden=2048 × 24 layer × 2 (K+V) × 2 bytes ≈ 200 MB），对应 ~1.5 GB/s Mooncake 实际有效带宽 —— 严重低于 stage 3 smoke 19 GB/s，**加上建链和 handshake 吞占大头**。
2. **rate=8 反常** (1532ms)：mini_lb 简单 round-robin 调度 + decode 队列瞬间积压，几次 prompt 被 backpressure 拉长尾（p99 4597ms）。下次换 `random` 或其他 LB 策略可能好转。
3. **rate=inf**：并发洪峰，prefill 与 decode 分别在自己节点批量调度，但 KV 传输排队爆炸（22.81 req/s × ~200 MB/req = ~4.5 GB/s 持续吞吐需求，Mooncake DRAM 路径还供得上但建链开销放大）。
4. **rate=16 比 rate=8 好**：可能是因为更高 rate 下 batching 大，建链摊销变小。

### ITL 持平甚至略低

1P:1D 的 ITL 都在 1.7-2.5ms 之间，和 baseline 基本一致。说明 **decode 节点的 TP=8 解码速度不受 KV 传输影响**，KV 只是 prompt 开始时 push 一次，之后 decode 纯本地。

## 结论

- **1P:1D over Mooncake/EFA 在当前配置下 TTFT 全线不达 Plan 目标**（最好 2.57×，远未达 ≤1.3×）
- **ITL / per-token latency ✅ 持平**，说明 Mooncake KV 传输不影响 decode 吞吐
- 主要瓶颈在 **KV 跨节点传输延迟**（单次 ~130ms@200MB，实际吞吐只有 ~1.5 GB/s 远低于 Mooncake smoke 19 GB/s）
- 要达标需：
  1. **Mooncake 连接池预建 / persistent channel**（减少 per-request 建链）
  2. **VRAM→VRAM GDR**（Mooncake 源码补丁 + FI_HMEM）
  3. **更大模型**：SmolLM2 prefill 只 ~28ms 太快，KV transfer 占比显得过大；换 7B/14B 级模型 prefill 本身到 200-500ms，KV transfer 的相对开销会从 80% 降到 20%
  4. **更合理 LB**：mini_lb 简单 RR 很可能造成 rate=8 那样的局部 backlog

## 建议下一步

在当前 SmolLM2 上继续调 Mooncake 参数性价比低。更应该：
- 换 **Qwen2.5-7B-Instruct**（28 heads % 8 ≠ 0，需 TP=4 或先解决 head 约束）
- 或做 **Mooncake connection pooling patch** 再重测
- 或走 **NIXL + GDR** 路线（需要重建 nixlbench）

## 运行记录

- 1P:1D apply → Ready：~3 min
- Sweep duration：~5 min（5 组 × ~60 s/组）
- 全部 raw log 持久化在 `ip-10-1-12-160:/var/lib/yanxi-logs/stage4/`（job 把 /results/* 复制过来）
- Bench pod sleep 1200 保活，可手动 exec 查原始 log
