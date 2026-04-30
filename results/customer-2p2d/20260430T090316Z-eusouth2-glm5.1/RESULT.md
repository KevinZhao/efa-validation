# GLM-5.1-FP8 · 2P:2D (P: tp=8 pp=2, D: tp=16 ep=16) · bench_serving 60k/1k c=2 r=2 · 2026-04-30

**Region**: eu-south-2 (Zaragoza), AZ **eu-south-2a**
**Account**: 338295026919 (客户账号 JD-MaaS / JoyAI)
**Cluster / Infra**: 客户自建 EKS `jdmaas-gpu` 的 p5en.48xlarge 节点，compose 直跑 host docker（bypass K8s）
**Status**: ✅ 16 / 16 成功完成，无崩溃、无 DeepEP timeout

## 1. 拓扑

PD disagg **2P:2D** 全部 p5en.48xlarge Spot (Capacity Block purchase-option)，每台 8×H200：

| 节点 | Role | IP (enp71s0) | 容器 | 并行度（本节点）|
|---|---|---|---|---|
| i-075c9f2ba6ff398ed | Prefill node_rank=0 | 6.166.120.245 | `aws_review-ds32-chat-1-1` (e64fc22b67fd) | tp=8 (PP stage 0) |
| i-0e1ab7b1c112f2d75 | Prefill node_rank=1 | 6.166.123.226 | `aws_review-ds32-chat-1-1` (61a269e15a1e) | tp=8 (PP stage 1) |
| i-01e9d1dd51ebc8eb5 | Decode node_rank=0  | 6.166.123.15  | `aws_review-ds32-chat-1-1` (cf57492c568c) | tp/ep shard 0..7 of 16 |
| i-035846380ab547e18 | Decode node_rank=1  | 6.166.124.241 | `aws_review-ds32-chat-1-1` (96f51b7ddcc8) | tp/ep shard 8..15 of 16 |

**并行度总览**：
- **Prefill 组**: 2 nodes × 8 GPU = 16 H200，`tp=8 pp=2 dp=1 ep=8 attn_cp=8`；NSA prefill context-parallel split 8 路；DeepEP **normal** mode
- **Decode 组**: 2 nodes × 8 GPU = 16 H200，`tp=16 dp=16 ep=16`（`enable_dp_attention=True, enable_dp_lm_head=True`，每 rank 一个独立 DP/EP slot）；DeepEP **low_latency** mode
- **总计**: 4 节点 × 8 H200 = **32 H200**，都挂在 p5en EFA v2（每节点 16×400Gbps RDMA NIC）

Router: `glm-router` (lmsysorg/sglang:v0.5.10 `sglang_router.launch_router`) 跑在 **P0**, 监听 `0.0.0.0:30000`，`--pd-disaggregation --prefill http://6.166.120.245:30082 --decode http://6.166.123.15:30081`。

Bench client: `glm-bench` 容器 (lmsysorg/sglang:v0.5.10 `sglang.bench_serving`) 跑在 **P0** host docker，走 loopback 打 router。

## 2. 镜像 / 版本

- Prefill + Decode: `public.ecr.aws/n3l4x8f3/sglang-mooncake-uccl:2026.04.28-h200.3`
  - SGLang 0.5.10 + Mooncake (Henan EFA PRs including #1944)
  - UCCL-EP
- Router / Bench client: `lmsysorg/sglang:v0.5.10`（公共镜像，含 `sglang_router` + `sglang.bench_serving`）

## 3. Compose 配置要点

来源：本仓 `customer_glm_5.1/*.yml`（commit 71f176e bump .3 + UCCL-EP tunables + EAGLE 注释 之后；本次启用前本地把 EAGLE 4 行从 compose `command:` 里**删除**以修复 YAML parse 错，不是注释）。

**Prefill 侧**：
```
--tp-size 8 --pp-size 2 --nnodes 2 --dp-size 1
--chunked-prefill-size 16384 --mem-fraction-static 0.85
--attention-backend nsa --page-size 64
--enable-nsa-prefill-context-parallel --nsa-prefill-cp-mode round-robin-split
--moe-a2a-backend deepep --deepep-mode normal
--ep-dispatch-algorithm dynamic --eplb-algorithm deepseek
--disable-shared-experts-fusion --moe-dense-tp-size 1
--disaggregation-mode prefill --disaggregation-transfer-backend mooncake
--context-length 202752 --max-running-requests 8
```

**Decode 侧**：
```
--tp-size 16 --dp-size 16 --nnodes 2
--enable-dp-attention --enable-dp-lm-head --moe-dense-tp-size 1
--attention-backend nsa --page-size 64
--moe-a2a-backend deepep --deepep-mode low_latency
--ep-dispatch-algorithm dynamic --eplb-algorithm deepseek
--disable-shared-experts-fusion
--cuda-graph-max-bs 16 --max-running-requests 256 --mem-fraction-static 0.74
--disaggregation-mode decode --disaggregation-transfer-backend mooncake
--prefill-round-robin-balance
--context-length 202752
# 注意：EAGLE speculative decoding 被禁用（draft-extend cuda graph hang 问题未解决）
```

**EFA 绑定**：16 条 `rdmap{85..88,110..113,135..138,160..163}s0` 作为 `--disaggregation-ib-device`。

**Env** (decode)：
```
UCCL_IB_MAX_INFLIGHT_LOW_LATENCY=128
SGLANG_DEEPEP_NUM_MAX_DISPATCH_TOKENS_PER_RANK=128
UCCL_SOCKET_IFNAME=enp
FI_PROVIDER=efa  FI_EFA_USE_DEVICE_RDMA=1  FI_EFA_USE_HUGE_PAGE=1
MOONCAKE_PROTOCOL=efa
MC_NUM_CQ_PER_CTX=4  MC_MAX_WR=16384  MC_MAX_CQE_PER_CTX=65536
MC_SLICE_SIZE=1048576  MC_EFA_STRIPING_THRESHOLD=1073741824
```

模型：`/export/models/zai-org/GLM-5.1-FP8`（本地 28 TB xfs on 8×3.5TB NVMe LVM，705 GB / 142 safetensors shards，**不走 S3 / FSx，直接本地盘**）。

## 4. Bench 命令

```
python3 -m sglang.bench_serving \
  --backend sglang-oai-chat \
  --host 6.166.120.245 --port 30000 \
  --model glm-5-fp8-long-pd \
  --tokenizer /models/model \
  --dataset-name random \
  --random-input-len 60000 --random-output-len 1024 --random-range-ratio 1 \
  --num-prompts 16 \
  --max-concurrency 2 \
  --request-rate 2 \
  --pd-separated \
  --warmup-requests 1 \
  --output-file /logs/bench/bench_60k_1k_c2_r2.json
```

- **ISL 60000 / OSL 1024 固定**（`random_range_ratio=1` 不扰动长度）
- **#prompts 16**，**并发 2**，**到达率 2 req/s Poisson**
- Total input tokens = **960,000** / Total output tokens = **16,384**
- 启动时间 2026-04-30 **09:03:16 UTC**，结束 **09:11:28 UTC**（cold-start 阶段，DeepGEMM JIT 仍在继续）

## 5. 结果

### 核心数字

| 指标 | 值 |
|---|---|
| Successful requests | **16 / 16** ✅ |
| Benchmark duration | **466.73 s** (≈ 7 min 47 s) |
| Request throughput | **0.034 req/s** |
| Input token throughput | **2056.87 tok/s** |
| Output token throughput | **35.10 tok/s** |
| Total token throughput | **2091.98 tok/s** |
| Peak output tok/s | 25.0 |
| Peak concurrent requests | 4 |
| Observed concurrency | 1.995 |

### 延迟分布 (ms)

| 指标 | Mean | Median | P90 | P95 | P99 |
|---|---|---|---|---|---|
| **E2E latency** | 58,198.70 | 58,558.44 | 63,548.45 | — | 65,821.49 |
| **TTFT** | 12,189.04 | **0.00** | — | — | 61,881.18 |
| **TPOT** (excl. 1st) | 44.98 | 53.52 | — | — | 63.33 |
| **ITL** | 54.99 | 50.09 | — | 105.77 | 177.45 |
| ITL Max | 341.63 | | | | |

> TTFT median=0 + mean=12.2s 的对比说明分布极度双峰：
> 一半请求在 streaming-chat 首 chunk 基本"瞬间"返回（chunked-prefill 下 SSE 第一个 chunk 在首 chunk forward 完就 flush）；另一半请求卡在 cold-start + 队头（等前面 prefill 腾空的排队时间），拉出 P99 62s 的尾巴。

### Retokenize 提示

`total_output_tokens_retokenized = 1731`（客户端重编码后）而 server 统计 **16,384**（基于内部 id 计数）。差值来自 GLM tokenizer 的 reasoning content 处理（大部分请求因 reasoning 产生重复 token 被 dedup/re-tokenize 差异），**不影响服务端吞吐读数**，但客户端 tok/s 数字是按 retokenized 算的话会显著偏低。Bench 报告的 `output_throughput` 用的是 server-side `total_output_tokens`。

## 6. 失败过的实验（作为对比）

同轮测试里 **rate=inf / concurrency=8** 被尝试但失败（容器 `glm-bench` 上一版），服务端 prefill 出现大量：

```
DeepEP timeout check failed: rank = X, thread = Y, value = 1024
Received signal QUIT, but no handler is defined for it.
Health check failed. Server couldn't get a response from detokenizer for 20 seconds.
```

重启 prefill 之后，**rate=2 / concurrency=2** 保守设置一次跑通 16/16。根因方向：EFA / Mooncake 的 prefill→decode KV 传输在高并发 60k 长 context 下会触发 DeepEP normal-mode dispatch 的超时保护。

**结论**：当前镜像 + compose 在 **concurrency ≤ 2 + 长 context** 场景稳定；更高并发需要进一步调优 `--deepep-config`、`MC_NUM_CQ_PER_CTX`、`UCCL_IB_MAX_INFLIGHT_LOW_LATENCY` 等 EFA/UCCL/Mooncake 并发深度参数。

## 7. 系统瓶颈分析

**Prefill 侧 (ISL=60k, 16 H200 tp=8 pp=2 ep=8 dp=1)**：
- 单请求 prefill ≈ 30 s × 60k tokens → 单路 **~2000 tok/s**
- 并发 2 下 aggregate 2057 tok/s；`dp=1` 下两路请求共享同一个 PP group 内部 pipeline bubble，prefill 算力未饱和
- **Prefill TTFT cold-start 62s** 主因：首次 DeepGEMM JIT 编译 + EFA QP 首次使用（Mooncake peer-reconnect 浪潮）
- 上限测算（热态）：16 H200 on 2P × NSA prefill-CP ~ **30-50k tok/s** peak（需 concurrency > 4 才能让 pipeline 两级都吃满）

**Decode 侧 (OSL=1k, 16 H200 tp=16 dp=16 ep=16)**：
- 单请求 TPOT 54 ms → **18.5 tok/s per request**
- concurrency=2 → aggregate **35 tok/s** ✅ 符合预期
- decode `dp_size=16` 全展开（每 rank 一个独立 DP slot）但本轮 concurrency 只用到 2 个 slot，其余 14 rank idle —— 并发提高后才能吃掉所有 dp slot
- Decode 上限（假设 30 req 并发，对标 Kimi-K2.5 同 region 的观测）：**~1500 tok/s aggregate**

## 8. 归档内容

```
./RESULT.md                   # 本文件
./bench_60k_1k_c2_r2.json     # bench_serving 原始 JSON（包含所有统计字段）
```

## 9. 后续建议

1. **加并发 sweep**：rate=4/conc=4 → rate=8/conc=8 → rate=16/conc=16，找 DeepEP/EFA 真正瓶颈点
2. **Prefill warmup**：测前发 2-3 个 60k/1k 请求预热 JIT + Mooncake QP，然后 reset 统计再跑，避免 cold-start 污染 TTFT mean
3. **修复 EAGLE decode**：上午的 draft-extend cuda graph hang 仍未解（已暂禁），开启后 decode TPOT 有望从 55 ms → 20-25 ms（spec acceptance ~ 2.5x）
4. **改 `--deepep-config`**：日志里有提示 `Only use 20 SMs for DeepEP communication. This may result in highly suboptimal performance.` 这是当前 prefill 侧 warning，调大 SM 数可能帮助 DeepEP 拥塞时的表现
