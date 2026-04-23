# Stage 4 — Baseline TP=8 Sweep (SmolLM2-1.7B-Instruct, 128 prompts × 1024/256)

## Config

- Model: SmolLM2-1.7B-Instruct (Llama, 32 heads / 24 layers / hidden=2048)
- Deployment: 1× p5.48xlarge, TP=8 (single replica, `baseline-tp8.yaml`)
- Workload: `sglang.bench_serving`, dataset=random, 128 prompts, input=1024, output=256
- Node: ip-10-1-12-160 (us-east-2b)

## Results

| request-rate | TTFT mean (ms) | TTFT p99 (ms) | ITL mean (ms) | ITL p99 (ms) | E2E mean (ms) | output tok/s | request/s |
|---:|---:|---:|---:|---:|---:|---:|---:|
| **inf** | 484.06 | 550.07 | 3.76 | 11.80 | 976.91 | 12995.42 | 98.35 |
| 2 | **28.33** | 42.44 | 1.69 | 3.19 | 249.59 | 326.93 | 2.47 |
| 4 | 29.87 | 47.44 | 1.78 | 5.25 | 262.66 | 649.64 | 4.92 |
| 8 | 30.58 | 46.06 | 1.93 | 16.37 | 284.30 | 1282.67 | 9.71 |
| 16 | 32.13 | 55.77 | 2.50 | 19.06 | 359.84 | 2494.41 | 18.88 |

## Observations

- TTFT 在 rate ≤ 16 下几乎常数 (~30 ms)，说明 prefill 资源还没饱和。
- rate=inf 是并发洪峰（128 req 瞬发），TTFT 飙到 484 ms，ITL 影响小（3.76 ms）。
- `sglang.bench_serving` 本版**没有 `Mean TPOT` 行**，以 `Mean ITL` 作 per-token 代理指标。
- 单机 output throughput 峰值 ~13k tok/s (rate=inf)，rate=16 下稳定 2.5k tok/s。

## 后续

跑对应 1P:1D 版本（`bench-serving-disagg.yaml` 加 `--request-rate` sweep）得到对照数字，
判断 PD 分离是否在 rate ≤ 1.3× 倍率内达到 TTFT 持平 baseline。
