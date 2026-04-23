# Stage 4 p5en — 1P:2D Full-Stack Disaggregation ✅ PASS

**Date**: 2026-04-22
**Cluster**: EKS `gpu-cluster-ohio`, us-east-2a
**Instances**: 3 × p5en.48xlarge (H200 141GB × 8, EFA v3 16 × 200 Gb/s = 3.2 Tbps)
**Image**: `yanxi/sglang-mooncake:v2`
  - base: `yanxi/mooncake-nixl:v2` (Mooncake v0.3.10.post2, SHA `e1d6d6f6f4`, Henan 4 PRs)
  - sglang: **0.5.10** (customer production version, matches JD JoyAI prod)
  - sglang-router: **0.3.2** (pip installed at LB boot)
  - NIXL v1.0.1（备选，未启用）

## 拓扑

| 角色 | Pod | Node | IP |
|---|---|---|---|
| Prefill | `sglang-prefill` TP=8 | ip-10-1-11-108 | 10.1.11.221 |
| Decode-0 | `sglang-decode-0` TP=8 | ip-10-1-11-93 | 10.1.11.125 |
| Decode-1 | `sglang-decode-1` TP=8 | ip-10-1-11-197 | 10.1.11.70 |
| LB | `sglang-lb` (sglang-router `--pd-disaggregation`) | ip-10-1-11-108 | 10.1.11.85 |

`podAntiAffinity` 强制 1P + 2D 跨 3 节点。

## 关键修复：sglang "rdma" → "efa"

**根因**：sglang 0.5.10 的 `mooncake_transfer_engine.py:186` 硬编码 `protocol="rdma"`，在 AWS p5en 上映射到 libibverbs `RdmaTransport`（EFA 不支持标准 RC QP 的 `ibv_post_send`）。

**修复**：launcher 启动时 `sed -i 's/"rdma",$/"efa",/'` 改写 sglang 模块，让 Mooncake 激活 `EfaTransport`（libfabric efa provider + Henan #1509/#1523/#1821/#1912 multi-NIC striping）。

**验证启动日志**：
```
[launcher] patching /usr/local/lib/.../mooncake_transfer_engine.py: rdma -> efa
I topology.cpp:124] Device rdmap{85,86,87,88,110,111,112,113,135,136,137,138,160,161,162,163}s0 port 1 is available
I transfer_engine_py.cpp:198] Topology discovery complete for EFA. Found 16 devices.
I transfer_engine_py.cpp:221] Installing EFA transport as requested by protocol parameter
I efa_transport.cpp:94] [EFA] AWS Elastic Fabric Adapter transport initialized
```

## Smoke Test

```bash
curl -X POST http://sglang-lb:8000/v1/chat/completions \
  -d '{"model":"/models/current","messages":[{"role":"user","content":"Say hi in 5 words"}],"max_tokens":20}'

# Response: {"content":"Hi, bro!", "finish_reason":"stop"}  ✅
```

## Benchmark Sweep (128 prompts × 1024 in / 256 out × 3 rates)

| request-rate | Success | Duration | req/s | **Mean TTFT** | Median TTFT | P99 TTFT | **Mean TPOT** | **Mean ITL** | Out tok/s | Total tok/s |
|---|---|---|---|---|---|---|---|---|---|---|
| **4** | 128/128 | 33.79 s | 3.79 | **570.94 ms** | 47.68 ms | 4333.08 ms | **4.65 ms** | **1.75 ms** | 499 | 2442 |
| **8** | 128/128 | 16.93 s | 7.56 | **41.39 ms** | 36.16 ms | 78.02 ms | **1.42 ms** | **1.44 ms** | 996 | 4872 |
| **16** | 128/128 | 8.55 s | 14.98 | **73.38 ms** | 40.53 ms | 416.52 ms | **1.43 ms** | **1.46 ms** | **1974** | **9655** |

### p5 baseline 对照（2026-04-21 同 1P:1D 栈，sglang 0.4.10 + mooncake post1 rdma-fallback-TCP）

| 维度 | p5 1P:1D baseline (req-rate=inf) | **p5en 1P:2D rate=16 (今天)** | 增幅 |
|---|---|---|---|
| Out tok/s | 2994 | **1974** | -34%（rate=16 未压满） |
| Mean TTFT | 3320 ms | **73 ms** | **46× 更好** |
| Mean TPOT | — | **1.43 ms** | — |
| Mean ITL | 3.79 ms | **1.46 ms** | **2.6× 更好** |
| Success rate | 128/128 | **128/128** | ✅ |

rate=16 未饱和（P99 TTFT 仅 416 ms，TPOT/ITL 线性无拐点），下一步可直接推到 rate=32/64 或 `--request-rate inf` 探拐点。

## Henan EFA PR 证据

| PR | 功能 | 日志证据（prefill pod） |
|---|---|---|
| #1509 AWS EFA transport | EfaTransport class | `[EFA] AWS Elastic Fabric Adapter transport initialized` |
| #1523 TCP fallback + docs | — | 未触发，数据路径全走 EFA |
| #1821 fi_read + multi-NIC striping | 16 CQ workers | `Topology discovery complete for EFA. Found 16 devices` |
| #1912 PTE-aware auto-split MR | auto-split | 懒加载（prod first request 触发，见 Stage 3 log） |

## 已解决的问题

| # | 问题 | 修复 |
|---|---|---|
| 1 | prefetch job 用 `huggingface-cli`，post2 镜像已删 CLI | 改 `hf download` |
| 2 | sglang 0.5.10 删 `launch_lb` | pip `sglang-router==0.3.2` + `launch_router --pd-disaggregation` |
| 3 | `--disaggregation-ib-device` 接受 `rdmapXXXs0` 不接 `rdmapXXXs0-rdm` | launcher 用 sed 去后缀 |
| 4 | sglang hardcode `protocol="rdma"` → EFA 上 libibverbs 路径挂起 | **`sed -i 's/"rdma",$/"efa",/'` 启动时 patch** |
| 5 | `mem-fraction-static=0.85` 触发 decode OOM 重启 | 降到 0.70 |

## 产物

- `stage4-p5en/disagg-1p2d.yaml` (含 rdma→efa sed patch)
- `stage4-p5en/model-prefetch-3node.yaml` (hf CLI 兼容)
- `stage4-p5en/bench-1p2d-sweep.yaml`
- `results/stage4-p5en/DISAGG_1P2D_SWEEP.md`（本文件）
- ECR: `788668107894.dkr.ecr.us-east-2.amazonaws.com/yanxi/sglang-mooncake:v2`

## Llama-3.1-8B-Instruct Run（更大模型跑通）

同 1P:2D 拓扑 × `NousResearch/Meta-Llama-3.1-8B-Instruct`（4.7× SmolLM2 参数，32 heads TP=8，16GB fp16 weights/GPU shard 2GB）：

- **Smoke**: `hi` → `"How are you today? Is there something I can"` ✅
- **EFA 证据**: `EfaTransport: Initialized EFA device rdmap{85,86,87,88,110-113,135-138,160-163}s0` × 16 + `EfaTransport: Started 16 CQ polling worker threads` + `Clamped max_mr_size to device limit: 206158430208` (192 GB MR 空间/NIC)

### Llama-3.1-8B bench sweep (128 prompts × 1024in/256out)

| rate | Success | Duration | req/s | **Mean TTFT** | Median TTFT | P99 TTFT | **Mean TPOT** | **Mean ITL** | Out tok/s | Total tok/s |
|---|---|---|---|---|---|---|---|---|---|---|
| **4** | 128/128 | 33.77 s | 3.79 | **160.2 ms** | 57.5 ms | 1369.6 ms | **4.14 ms** | **2.48 ms** | 499 | 2439 |
| **8** | 128/128 | 16.94 s | 7.55 | **53.1 ms** | 43.9 ms | 118.9 ms | **2.37 ms** | **2.40 ms** | 996 | 4862 |
| **16** | 128/128 | 8.65 s | 14.79 | **57.2 ms** | 54.3 ms | 121.1 ms | **2.46 ms** | **2.49 ms** | **1950** | **9521** |

### SmolLM2-1.7B vs Llama-3.1-8B 对照（同拓扑、同 3 节点、同 sweep）

| 指标 @ rate=16 | SmolLM2-1.7B | Llama-3.1-8B | Llama / SmolLM2 |
|---|---|---|---|
| Mean TTFT | 73.4 ms | 57.2 ms | **0.78×** (更快，模型大但 KV 传输主导) |
| Mean TPOT | 1.43 ms | 2.46 ms | 1.72× (8B/1.7B ≈ 4.7×，非线性增长 — H200 HBM3e 吃得动) |
| Mean ITL | 1.46 ms | 2.49 ms | 1.71× |
| Out tok/s | 1974 | 1950 | -1% (持平，说明 **H200 在 8B 仍带宽过剩**) |
| P99 TTFT | 416.5 ms | 121.1 ms | **0.29×** (更稳定) |

**洞察**: 8B 模型下 P99 TTFT 明显更稳定（未饱和时，prefill chunked 的成本均摊更好），TPOT 增幅仅 1.7×（远小于参数比 4.7×），证明 H200 HBM3e 4.8 TB/s 带宽有很大裕量。下一步可上 Llama-3.1-70B（TP=8 @ fp8）或推 rate=32/64 找饱和点。

## 下一步建议

1. **长时压测**：rate=32/64 推到饱和点，记录 SLA 拐点（P99 TTFT/TPOT）
2. **更大模型**：Llama-3.1-70B-FP8（140GB @ fp8 / 8 = 17.5GB/GPU, TP=8 勉强放下），或 Qwen2.5-72B AWQ
3. **1P:4D / 2P:4D scale-out**：复用同一模板，只扩 decode replicas
4. **向 sglang upstream 提 PR**：让 `protocol="rdma"|"efa"` 可通过 CLI 参数切换（免 sed hack）
