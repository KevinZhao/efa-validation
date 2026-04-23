# Stage 4 p5en — Kimi-K2-Instruct-0905 (1T MoE) ✅

**Date**: 2026-04-23
**Model**: `moonshotai/Kimi-K2-Instruct-0905`
  - Architecture: DeepseekV3 (MLA) / `kimi_k2` model_type
  - 1T total params, **384 experts top-8** (32B active per token)
  - 61 layers, 64 attention heads, `kv_lora_rank=512` (MLA)
  - Native context: 256k tokens
  - Quantization: **FP8 block (weight_block_size=[128, 128])**
  - Total on-disk: **959 GB** (62 shards)

**Cluster**: 3 × p5en.48xlarge (H200 141GB × 8, EFA v3 16 × 200 Gb/s)
**Image**: `yanxi/sglang-mooncake:v2` (SGLang 0.5.10 + Mooncake post2 + Henan EFA PRs)

## Topology

| Role | Pod | Node | IP |
|---|---|---|---|
| Prefill | `sglang-prefill` TP=8 | ip-10-1-11-197 | 10.1.11.90 |
| Decode-0 | `sglang-decode-0` TP=8 | ip-10-1-11-108 | 10.1.11.229 |
| Decode-1 | `sglang-decode-1` TP=8 | ip-10-1-11-93 | 10.1.11.125 |
| LB | `sglang-lb` sglang-router 0.3.2 | ip-10-1-11-108 | — |

## 关键配置（与 Llama-3.1-8B 的增量）

| Flag | 值 | 原因 |
|---|---|---|
| `--trust-remote-code` | ✅ | Kimi K2 `auto_map` 指向 `configuration_deepseek.py` |
| `--tp` | 8 | 959GB / 8 = **~120 GB/GPU**（单节点 NVLink 合并 fp8 MoE expert shards） |
| `--context-length` | 131072 | 128k（模型声明 262144 但 sglang 需显式设置以启用 piecewise graph） |
| `--mem-fraction-static` | **0.92** | fp8 权重吃掉 ~120GB/141GB，仅 ~15GB 给 KV cache，必须压得很紧 |
| `--chunked-prefill-size` | 4096 | 对比 Llama 8192 减半以避免 prefill OOM（Kimi K2 中间激活更大） |
| `--fp8-gemm-backend` | **cutlass** | 关键：默认 `deep_gemm` JIT 预编译 6-7 个 GEMM shape × 16384 变量 × 60+ 层 ≈ **3+ 小时冷启动**。`cutlass` 走预编译 kernel 直接起 |
| `--skip-server-warmup` | ✅ | 缩短启动（PD disaggregation warmup 已经被触发） |
| `--disaggregation-transfer-backend` | mooncake | 同 Llama 栈 |
| `--disaggregation-ib-device` | 16 × rdmap*s0 | 自动 libfabric discovery |

### 启动时间（冷启动）

| 阶段 | 时长 |
|---|---|
| 镜像 pull（已在 node） | 0 |
| 959GB 权重从 NVMe RAID0 加载 | ~2 min |
| `Loaded fp8 weights` → `EfaTransport: Initialized 16 EFA devices` | ~1 min |
| `Chunk registered on 16 NICs` + PTE auto-split + `server is fired up` | 30s |
| **Total prefill pod ready** | **~3 min** |
| Decode-0 ready | **~5 min** |
| Decode-1 ready | **~7 min**（DeepGEMM 残留 + 磁盘 contention） |

> 对比：`deep_gemm` 默认 backend 下首次启动预估 **30-60 min**（我们之前跑过 22 min 也没启完，第 7 个 session @ 33%）。切 `cutlass` 后 7 min 到 Ready。

## Smoke Test

```bash
curl -X POST http://sglang-lb:8000/v1/chat/completions \
  -d '{"model":"/models/current","messages":[{"role":"user","content":"What is 2+2?"}],"max_tokens":30}'

# Response: {"content":"2 + 2 = 4","finish_reason":"stop","completion_tokens":8}  ✅
```

**1T 模型首个真实 cross-node KV over EFA token 返回。**

## Kimi K2 Benchmark Sweep (16 prompts × 512in / 128out × 3 rates)

| rate | Success | Duration | req/s | **Mean TTFT** | Median TTFT | P99 TTFT | **Mean TPOT** | **Mean ITL** | Out tok/s | Total tok/s |
|---|---|---|---|---|---|---|---|---|---|---|
| **1** | 16/16 | 16.44 s | 0.97 | **689 ms** | 479 ms | 1951 ms | **18.95 ms** | **15.78 ms** | 53 | 301 |
| **2** | 16/16 | 8.87 s | 1.80 | **562 ms** | 387 ms | 1569 ms | **12.55 ms** | **12.49 ms** | 99 | 558 |
| **4** | 16/16 | 5.12 s | 3.13 | **448 ms** | 426 ms | 707 ms | **10.94 ms** | **12.17 ms** | 171 | 967 |

16/16 全成功 ✅。`request-rate=4` 在只有 16 prompts 样本时仍未饱和（P99 TTFT 707ms << rate=1 时的 1951ms 说明越多并发越稳定，批打满 prefill 摊薄 cost）。

### 对照 Llama-3.1-8B @ 同栈 rate=4

| 模型 | 参数比 | Mean TTFT | Mean TPOT | Out tok/s (@ rate=4) |
|---|---|---|---|---|
| Llama-3.1-8B fp16 | 1× | 160 ms | 4.14 ms | 499 |
| **Kimi-K2 1T fp8** | **125× total, 4× active (32B)** | **448 ms** | **10.94 ms** | 171 |

Kimi K2 vs Llama 8B 的成本比只有 **2.8× TTFT / 2.6× TPOT**，远小于 125× 参数比例 — 正是 MoE top-8 稀疏激活（实际只用 32B/token）加 FP8（半精度）的双重杠杆。

## Henan PR 激活证据（Kimi K2 prefill log 摘录）

```
I efa_transport.cpp:1105] EfaTransport: Initialized EFA device rdmap{85..88,110..113,135..138,160..163}s0  [×16]
I efa_transport.cpp:113]  EfaTransport: Started 16 CQ polling worker threads                                 # PR #1821
I efa_transport.cpp:278]  Auto-split params: page_size=4096, max_pte_entries=23068672,
                          pte_limit=94489280512, max_mr_size=206158430208, chunk_limit=94489280512            # PR #1912 PTE-aware auto-split
W efa_transport.cpp:486]  Chunk 0/1 registered on 16 NICs, addr=0x..., length=524288, duration=10ms           # PR #1821 multi-NIC striping
```

## 经验 & 下一步

### 已踩的坑（已记录于 RUNBOOK）

1. **p5en root EBS 仅 50GB** — 装不下 959GB 模型；挂 NVMe 8 盘 RAID0 到 `/var/lib/yanxi-models`（28TB 可用）
2. **`huggingface-cli` 被 `hf` 替换**（post2 image）— 用 `hf download --max-workers 16` 下 1TB 约 15 min
3. **DeepGEMM JIT 冷启动 3+ 小时** — 切 `--fp8-gemm-backend cutlass` 规避，7 min 到 Ready
4. **`mem-fraction-static=0.92`** 给 Kimi K2 仅剩 ~15GB/GPU KV — 单 prompt 128k context 可能 OOM，压测建议限 context ≤ 32k 或上更大机器
5. **sglang 硬编码 `protocol="rdma"`（已 sed patch）** — 仍有效，EFA 激活 ✅
6. **sglang-router 0.3.2 PD disaggregation** — 1P:2D 正确路由

### 下一步建议（按 ROI 排序）

| 优先级 | 动作 | 预估收益 |
|---|---|---|
| **P0** | 跑 `python3 -m sglang.compile_deep_gemm` 离线生成 DeepGEMM 缓存入 ECR 镜像 → 切回 `deep_gemm` backend | 预计 **10-30%** token/s（CUTLASS 比 DeepGEMM 保守） |
| **P1** | 长 context 压测（8k/32k/128k input）真实 RL 工作负载 | 看 KV cache 压力下 EFA Mooncake 的抖动 |
| **P1** | 开 `--moe-a2a-backend deepep` / UCCL-EP 做多节点 EP decode | 可能直接对标 JoyAI IB 栈吞吐 |
| **P2** | Kimi K2 non-disagg baseline（单节点 TP=8）对照 → 量化 PD 分离收益 | 证明 PD 在 1T MoE 上的价值 |
| **P3** | NIXL backend 替换 Mooncake 做同框架对照 | NIXL LIBFABRIC 路径也走 EFA，去掉 sed hack |

## 产物

- `stage4-p5en/disagg-1p2d-kimi.yaml`（cutlass fp8 + skip-warmup）
- `stage4-p5en/bench-kimi-k2.yaml`
- `stage4-p5en/nvme-setup.yaml`（8 × NVMe RAID0 挂载 DaemonSet）
- `stage4-p5en/model-prefetch-3node.yaml`（改 `hf download`）
- `results/stage4-p5en/KIMI_K2_RESULTS.md`（本文件）
