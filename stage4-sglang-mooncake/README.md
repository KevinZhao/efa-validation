# Stage 4 — SGLang PD 1P:1D on EFA with Mooncake KV

## Manifest 清单

| 文件 | 用途 |
|---|---|
| `baseline-tp8.yaml` | 单节点 TP=8 baseline（先跑通 sglang 镜像，再做对照 TTFT/TPOT） |
| `disagg-1p1d.yaml` | Prefill LWS（1 pod, TP=8）+ Decode LWS（1 pod, TP=8）+ mini_lb Deployment + ClusterIP 服务 |
| `bench-serving.yaml` | `sglang.bench_serving` 客户端 Pod，跑完写 `/results/*.json` |

## 模型

首轮用 **Qwen2.5-7B-Instruct** 做冒烟（权重公开可 `hf-transfer` 拉）。
后续按需替换为：
- JoyAI-LLM-Flash（jdopensource/JoyAI-LLM-Flash，如果公开）
- DeepSeek-V3/R1（MoE 288 experts，更贴近客户生产形态，但单节点显存不够）
- Qwen3-235B-A22B（未公开时略过）

## 跑法

```
# 0. 预拉模型
kubectl apply -f model-prefetch.yaml
# 1. baseline TP=8 单机
kubectl apply -f baseline-tp8.yaml
kubectl apply -f bench-serving.yaml  # TARGET_URL=http://sglang-baseline:30000
# 2. 1P:1D 跨机
kubectl apply -f disagg-1p1d.yaml
kubectl apply -f bench-serving.yaml  # TARGET_URL=http://sglang-lb:8000
```

## 出口

按 Plan §4.4：1P:1D 的 TTFT/TPOT ≤ 单机 baseline × 1.3；OTPS 达 SLA 假设。
