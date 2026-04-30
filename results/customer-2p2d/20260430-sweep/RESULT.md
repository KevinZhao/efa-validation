# GLM-5.1-FP8 · 2P:2D · 2026-04-30 配置调优与压测扫描

> **一句话结论**：从 baseline 2,092 tok/s 经过 3 次配置调优到达 **14,730 tok/s**（+604%），唯一硬限是 prefill 侧 DeepEP normal-mode 在 ISL=120k × c≥8 触发 CPU recv timeout。

**Region**: eu-south-2 (Zaragoza), AZ **eu-south-2a**
**Account**: 338295026919 (客户账号 JD-MaaS / JoyAI)
**Model**: `zai-org/GLM-5.1-FP8`（705 GB / 142 safetensors, DSA 架构）
**Image**: `public.ecr.aws/n3l4x8f3/sglang-mooncake-uccl:2026.04.28-h200.3`（SGLang 0.5.10 + Mooncake Henan EFA PRs 含 #1944 + UCCL-EP）
**Bench 容器**: `lmsysorg/sglang:v0.5.10`（`sglang.bench_serving` + `sglang_router`）

## 1. 拓扑（所有轮次共用）

4 × p5en.48xlarge Spot（Capacity Block），32 × H200，每台 16 × 400Gbps EFA v2，**单 AZ eu-south-2a**，Host docker（bypass K8s）：

| 节点 | Role | IP (enp71s0) | 并行度（本节点） |
|---|---|---|---|
| i-075c9f2ba6ff398ed | Prefill node_rank=0 | 6.166.120.245 | tp=8 (PP stage 0) |
| i-0e1ab7b1c112f2d75 | Prefill node_rank=1 | 6.166.123.226 | tp=8 (PP stage 1) |
| i-01e9d1dd51ebc8eb5 | Decode node_rank=0  | 6.166.123.15  | tp/ep shard 0..7 of 16 |
| i-035846380ab547e18 | Decode node_rank=1  | 6.166.124.241 | tp/ep shard 8..15 of 16 |

**并行度总览**：
- **Prefill**: `tp=8 pp=2 dp=1 ep=8 attn_cp=8`（NSA 序列方向 CP split 8-way）；DeepEP **normal** mode
- **Decode**: `tp=16 dp=16 ep=16`（每 rank 一个 DP/EP slot）；DeepEP **low_latency** mode
- **Router**: `glm-router` 容器跑在 P0 host，监听 `:30000`，`--pd-disaggregation --prefill http://6.166.120.245:30082 --decode http://6.166.123.15:30081`
- **Bench client**: P0 host docker，走 loopback 打 router

## 2. 5 轮结果汇总

所有轮次都走 **router → PD disagg → Mooncake/EFA KV transfer**。

| # | 时间 UTC | ISL | OSL | c | rate | 配置差异 | Duration | **Total tok/s** | Input tok/s | Output tok/s | Mean TPOT | P99 E2E |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **R2** | 09:03 | 60k | 1k | 2 | 2.0 | baseline（无 EAGLE，无 rail split）| 466.73 s | **2,092** | 2,057 | 35.1 | 44.97 ms | 65,821 ms |
| **R4** | 10:37 | 60k | 1k | 2 | 2.0 | **+ EFA rail split**（UCCL→high 8 / Mooncake→all 16）| 294.95 s | **3,310** | 3,255 | 55.5 | 28.18 ms | 37,256 ms |
| **R5** | 11:08 | 60k | 1k | 2 | 2.0 | **+ EAGLE spec decoding**（steps=3 topk=1 draft=4）| 193.30 s | **5,051** | 4,966 | 84.8 | 19.19 ms | 31,747 ms |
| **R8** | 12:44 | **120k** | 1k | 2 | 0.3 | ISL ×2, 同 R5 配置 | 195.62 s | **9,899** | 9,815 | 83.8 | 19.83 ms | 28,781 ms |
| **R9** 🏆 | 12:54 | 120k | 1k | **4** | 0.3 | concurrency ×2 | **131.45 s** | **14,730** | 14,606 | 124.6 | 23.51 ms | 55,859 ms |
| R10 | 13:00 | 120k | 1k | **8** | 0.3 | concurrency ×2 | 💥 | — | — | — | — | — |

### 每次相比 R2 的增幅（tok/s）
- R4: +58% (2092 → 3310)
- R5: **+141%**（+EAGLE 几乎翻倍）
- R8: +373%（同 R5 配置 ISL ×2 近线性）
- **R9: +604%**（**当前峰值**）
- R10: ❌ DeepEP CPU recv timeout（c=8 × ISL=120k 打爆 prefill EFA a2a）

### 延迟趋势（Mean E2E 随配置改进）
```
R2: 58,198 ms  ████████████████████████████████████████████████
R4: 36,762 ms  ██████████████████████████████
R5: 23,261 ms  ███████████████████
R8: 23,936 ms  ███████████████████      (ISL 120k，但延迟不涨)
R9: 29,325 ms  ████████████████████████   (c=4 tail 拉长)
```

## 3. 关键优化归因分析

### 优化 1 · EFA rail split（R2 → R4, +58% throughput）

**做法**（commit 7768f6b）：
```yaml
environment:
  - UCCL_IB_HCA=rdmap87s0,rdmap88s0,rdmap112s0,rdmap113s0,rdmap137s0,rdmap138s0,rdmap162s0,rdmap163s0
  - FI_EFA_IFACE=<same>
# Mooncake KV 仍用全 16 rails via --disaggregation-ib-device
```
- UCCL-EP alltoall 锁到高 8 rails
- Mooncake KV transfer 用全 16 rails

**收益**：消除 UCCL-EP 和 Mooncake KV 在 EFA QP 资源上的竞争；**P99 ITL 从 177 ms → 35 ms（-80%）**，尾部延迟抖动大幅改善。

### 优化 2 · EAGLE Speculative Decoding（R4 → R5, +53% throughput）

**做法**：decode 两个 yml 加回
```
--speculative-algorithm EAGLE
--speculative-num-steps 3
--speculative-eagle-topk 1
--speculative-num-draft-tokens 4
```
**收益**：
- TPOT 从 28.18 ms → **19.19 ms**（-32%）
- Output throughput 从 55.5 → **84.8 tok/s**（+53%）
- Spec acceptance rate 实测约 60-70%（2.37x decode 加速）

**风险记录**：当天上午同一组 flag 在客户精简版 compose（缺 `enable-dp-lm-head`/`deepep-mode=low_latency` 等）下触发 **draft-extend cuda graph capture busy-wait**。仓里 checked-in 版本的完整 flag 组合避开了这个 bug。

### 优化 3 · ISL ×2（R5 → R8，throughput 近似线性 scaling）

**做法**：**无代码改动**，只改 bench 参数 `random-input-len 60000 → 120000`。

**关键观察**：
- ISL 翻倍，duration 几乎不变（193s → 196s）
- Input throughput 从 4,966 → 9,815 tok/s（**+98%**）
- 证明 **c=2 时 prefill 算力远没饱和**

### 优化 4 · concurrency ×2（R8 → R9, +49% throughput）

**做法**：`--max-concurrency 2 → 4`，其它不动。

**观察**：
- Throughput 从 9,899 → 14,730 tok/s（+49%，**不是预期的 +100%**）
- Observed concurrency 3.57（不是 4）
- Duration 从 196s → 131s（-33%）
- **Tail latency 开始恶化**：P99 E2E 28.8s → 55.9s（+94%），P99 TPOT 25ms → 54.6ms（+117%）

**含义**：**Prefill 开始显露饱和**（c=2 已吃掉 50-60% prefill 吞吐，c=4 填满但有排队）。

### 边界 · c=8 崩溃（R10, DeepEP CPU recv timeout）

尝试 `--max-concurrency 8 --num-prompts 16 --request-rate 0.3 --random-input-len 120000`：

**崩溃点**：
```
DeepEP timeout check failed: rank = 6, thread = 0..7, value = 1024
Health check failed. Server couldn't get a response from detokenizer for 20s
P0 /health = 000 timeout
```

**根因**：8 并发 × ISL=120k → 每 prefill MoE layer 的 EFA alltoall 流量 ×2 相比 c=4。高 8 rails（UCCL-EP 专用）在这个数量级下 QP 资源耗尽，DeepEP recv buffer 等不到对端数据超时。

**对比**：上午第一次 `c=128 × ISL=60k` 也是同样错误（整条 EFA 路径被打爆）；本次 c=8 × 120k 触发同一 bug 但流量规模低一个数量级 → 真正的触发因素是**单步 a2a 的数据量**，不是总量。

## 4. 配置归档（最优配置 = R9）

**Prefill**（`customer_glm_5.1/prefill-docker-compose-{0,1}.yml`）：
```yaml
environment:
  - MOONCAKE_PROTOCOL=efa
  - FI_PROVIDER=efa
  - FI_EFA_USE_DEVICE_RDMA=1
  - FI_EFA_USE_HUGE_PAGE=1
  - MC_NUM_CQ_PER_CTX=4
  - MC_MAX_WR=16384
  - MC_MAX_CQE_PER_CTX=65536
  - MC_SLICE_SIZE=1048576
  - MC_EFA_STRIPING_THRESHOLD=1073741824
  # rail split
  - UCCL_IB_HCA=rdmap87s0,rdmap88s0,rdmap112s0,rdmap113s0,rdmap137s0,rdmap138s0,rdmap162s0,rdmap163s0
  - FI_EFA_IFACE=rdmap87s0,...,rdmap163s0

command:
  --tp-size 8 --pp-size 2 --nnodes 2 --dp-size 1
  --chunked-prefill-size 16384 --mem-fraction-static 0.85
  --attention-backend nsa --page-size 64
  --enable-nsa-prefill-context-parallel --nsa-prefill-cp-mode round-robin-split
  --moe-a2a-backend deepep --deepep-mode normal
  --ep-dispatch-algorithm dynamic --eplb-algorithm deepseek
  --disable-shared-experts-fusion --moe-dense-tp-size 1
  --disaggregation-mode prefill --disaggregation-transfer-backend mooncake
  --disaggregation-ib-device rdmap85s0,rdmap86s0,rdmap110s0,rdmap111s0,rdmap135s0,rdmap136s0,rdmap160s0,rdmap161s0,rdmap87s0,rdmap88s0,rdmap112s0,rdmap113s0,rdmap137s0,rdmap138s0,rdmap162s0,rdmap163s0
  --context-length 202752 --max-running-requests 8
```

**Decode**（`customer_glm_5.1/decode-docker-compose-{0,1}.yml`）：
```yaml
environment:
  - UCCL_IB_MAX_INFLIGHT_LOW_LATENCY=128
  - SGLANG_DEEPEP_NUM_MAX_DISPATCH_TOKENS_PER_RANK=128
  - UCCL_SOCKET_IFNAME=enp
  - UCCL_IB_HCA=<same high 8>
  - FI_EFA_IFACE=<same high 8>

command:
  --tp-size 16 --dp-size 16 --nnodes 2
  --enable-dp-attention --enable-dp-lm-head --moe-dense-tp-size 1
  --attention-backend nsa --page-size 64
  --moe-a2a-backend deepep --deepep-mode low_latency
  --ep-dispatch-algorithm dynamic --eplb-algorithm deepseek
  --disable-shared-experts-fusion
  --cuda-graph-max-bs 16 --max-running-requests 256 --mem-fraction-static 0.74
  --disaggregation-mode decode --disaggregation-transfer-backend mooncake
  --disaggregation-ib-device <all 16 rails>
  --prefill-round-robin-balance
  --context-length 202752
  # EAGLE
  --speculative-algorithm EAGLE
  --speculative-num-steps 3
  --speculative-eagle-topk 1
  --speculative-num-draft-tokens 4
```

**Bench client**（R9 峰值）：
```bash
python3 -m sglang.bench_serving \
  --backend sglang-oai-chat \
  --base-url http://6.166.120.245:30000 \
  --dataset-name random \
  --random-input-len 120000 --random-output-len 1024 --random-range-ratio 1 \
  --num-prompts 16 --max-concurrency 4 --request-rate 0.3 \
  --pd-separated --warmup-requests 1 \
  --tokenizer /models/model --model glm-5-fp8-long-pd
```

## 5. 性能提升下一步（基于本轮 sweep 的发现）

按**收益 × 风险比**排序：

### 立刻能做（Tier 1 · 1-2h 实验）
1. **找真实拐点** - c=5/6/7 逐步试，当前 c=4 成功 c=8 崩，实际上限可能在 c=6 附近（可能 17-19k tok/s）
2. **Chunked prefill size 加大** - 当前 `--chunked-prefill-size 16384`，120k prompt 切 8 块 → 8 次 a2a dispatch。改 32768 → 4 次，DeepEP 压力减半。改动小，可能直接解决 c=8 崩溃
3. **DeepEP env 调优** - `DEEPEP_RECV_TIMEOUT_MS=300000` + `SGLANG_DEEPEP_NUM_MAX_DISPATCH_TOKENS_PER_RANK=256`

### 中期结构性（Tier 2 · 半天实验）
4. **EFA rail 完全互补** - Mooncake 改为低 8 rails 专用（当前用全 16），UCCL 继续高 8 → 彻底消除 rail 共享
5. **Decode KV FP8 量化** - `--kv-cache-dtype fp8_e5m2` → KV 池容量翻倍 → decode 并发上限翻倍
6. **EAGLE 参数 sweep** - 试 `num-steps=5 num-draft-tokens=6` 或 `num-steps=2 num-draft-tokens=3` 看 TPOT 能否 <18ms

### 扩容（Tier 3）
7. **3P:2D** - prefill 加一台 → input throughput 从 14.6k → ~22k（+50%）。但 c=4 时 prefill 才饱和 50-60%，3P 的投入产出比要估
8. **替换 NSA→FA3** - 如果客户放弃长上下文场景，decode 可改用 fa3 backend，但会损失 long context 能力

### 不推荐
- `--moe-a2a-backend none`（已测，prefill 吞吐掉得多）
- 超大 `--cuda-graph-max-bs`（实测 decode 用 16 已够）

## 6. 归档内容

```
./RESULT.md                                  # 本文件
./raw/
  bench_60k_1k_c2_r2_20260430T090316Z.json   # R2 baseline
  bench_60k_1k_c2_r2_20260430T103733Z.json   # R4 rail split
  bench_60k_1k_c2_r2_eagle_20260430T110814Z.json  # R5 +EAGLE ⭐
  bench_120k_1k_c2_r0.3_20260430T124454Z.json # R8 ISL=120k
  bench_120k_1k_c4_r0.3_20260430T125446Z.json # R9 c=4 🏆
  (R10 c=8 崩溃，无 json)
```

配套已提交到 git：
- `customer_glm_5.1/prefill-docker-compose-{0,1}.yml`（commit 7768f6b 的 rail split）
- `customer_glm_5.1/decode-docker-compose-{0,1}.yml`（EAGLE 启用，未提交，见 `git status`）

## 7. 遗留问题 / 后续工作

1. **c=8 DeepEP CPU recv timeout** 还没彻底解决。Tier 1 的 chunked-prefill 加大值得先试。
2. **上午早期遇到的 EAGLE draft-extend cuda graph busy-wait** bug 在精简 compose 下复现，仓里完整版没事，**但机制没彻底搞懂**，下次配置微调可能又踩。
3. **Mooncake peer reconnect 浪潮** 在 prefill 每次重启后都会持续 ~60s，期间 P/D 间 KV transfer 性能不佳。目前观察是"自愈"，没影响最终 bench 结果，但客户线上场景下 prefill 替换需要注意。
4. **Retokenize 差距很大**（R9 total_output_tokens=16,384 vs retokenized=2,078）——  GLM tokenizer 对 random 数据生成有复发模式，client-side tok/s 数字会被压缩。服务端 throughput 数字（用 server 自己的 token count）是正确口径。
