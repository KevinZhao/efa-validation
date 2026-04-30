# Kimi-K2.5 PD-disagg Segfault 复现与 RCA

## 环境
- Region: ap-northeast-1 (Tokyo) usw2-az4 → apne1-az4
- VPC/Subnet: 10.99.0.0/16 / subnet-08ce5db3ae0f174b9 (private az4)
- Placement Group: `yanxi-tokyo-cluster` (cluster strategy) **← 关键，跨节点 EFA 必需**
- Nodes:
  - P: i-0ede524c3f8991aed / 10.99.10.151 (16× EFA ENI)
  - D: i-0b6f3a77216dcd7b8 / 10.99.10.106 (16× EFA ENI)
- AMI: ami-0c3b4f435169d5cdd (DLAMI AL2023 + NVIDIA + PyTorch 2.7)
- Docker image: `public.ecr.aws/n3l4x8f3/sglang-mooncake-uccl:2026.04.28-h200.3`
- Model: moonshotai/Kimi-K2.5 (compressed-tensors INT4, 555 GiB disk, 64 shards)
- Config: TP=8, prefill DP=2 / decode DP=8, enable-dp-attention, mem-fraction=0.85

## 触发步骤
1. P + D compose up，sglang loads K2.5，P/D 各自 warmup 成功（localhost）
2. Router (sglang-router 0.3.2, `--pd-disaggregation`) 起 38000
3. `bench_serving` `--random-input-len 2048 --random-output-len 1024 --num-prompts 128 --max-concurrency 4`
4. P 在运行几秒后 scheduler + data_parallel_controller 崩溃

## 核心错误（P 日志）

```
[2026-04-29 11:58:13 DP1 TP7] Scheduler hit an exception: Traceback (most recent call last):
  File "sglang/srt/disaggregation/prefill.py", line 428, event_loop_overlap_disagg_prefill
  File "sglang/srt/disaggregation/prefill.py", line 376, get_next_disagg_prefill_batch_to_run
  File "sglang/srt/managers/scheduler.py", line 257, maybe_prepare_mlp_sync_batch
  File "sglang/srt/managers/scheduler_dp_attn_mixin.py", line 202, prepare_mlp_sync_batch_raw
      mlp_sync_info.all_gather(device=device, group=group)
  File "sglang/srt/managers/scheduler_dp_attn_mixin.py", line 81, all_gather
      torch.distributed.all_gather_into_tensor(
  File "torch/distributed/c10d_logger.py", line 81, wrapper
  File "torch/distributed/distributed_c10d.py", line 4056, all_gather_into_tensor
      work.wait()
RuntimeError: [/pytorch/third_party/gloo/gloo/transport/tcp/pair.cc:538]
    Read error [10.99.10.151]:63667: Connection reset by peer
```

接着：
```
Fatal Python error: Aborted
Subprocess scheduler_0 (pid=403) crashed with exit code -3.
```

Core dumps：
- `/data/export/coredump/core.sglang::schedul.493.1777463888` (12 GiB)
- `/data/export/coredump/core.sglang::data_pa.403.1777463893` (1.4 GiB)

## 根因（RCA）

**DP Attention 的 Gloo CPU all_gather 在主 ENI (`enp71s0`) 上被高并发请求打崩**：

1. 客户 compose `--enable-dp-attention` → prefill dp=2, decode dp=8
2. DP Attention 每 batch 要 CPU 侧 `all_gather_into_tensor` 同步 batch 元信息
3. sglang 这个 all_gather 走 **Gloo (TCP) backend**，不走 NCCL/EFA
4. Gloo 绑 `GLOO_SOCKET_IFNAME=enp71s0`（客户 env + 我们 compose 均设）
5. EFA 的 16 rail 只给 Mooncake KV transfer 用，**Gloo 只用 primary 1 张 ENI**
6. 高并发（rate=4，多 request 并发 decode batch 准备）让 enp71s0 上的 TCP socket 拥塞
7. Connection reset by peer → `work.wait()` 抛 RuntimeError → scheduler 进程抛 `Fatal Python error: Aborted` → SIGABRT（exit code -3 = SIGQUIT，sglang 主动 cleanup）→ core dump

## 客户现场为什么触发

客户生产环境同样：
- `--enable-dp-attention` 开
- `GLOO_SOCKET_IFNAME=enp71s0` 绑主 ENI
- rate=4 2K/1K 128 prompts 同样高并发
- Gloo TCP 同样被挤爆

**原因不在 Mooncake/UCCL/EFA，也不在 K2.5 模型本身。是 sglang DP-Attention 的 MLP sync 走 Gloo TCP primary-ENI 的单点瓶颈 + torch 对 Gloo connection reset 的异常处理不够干净（直接 SIGABRT）。**

## 缓解/Workaround

**已验证可行** ✅：**prefill 和 decode 必须 `--dp-size` 严格相等**（对称 DP group）

测试矩阵：
| Prefill dp | Decode dp | Kernel tuning | Gloo timeout | 结果 |
|---|---|---|---|---|
| 2 | 8 | 默认 | 默认 | ❌ crash <1 min（客户原配置）|
| 2 | 4 | 默认 | 默认 | ❌ crash <2 min |
| 2 | 2 | 默认 | 默认 | ✅ **稳定** |
| 2 | 8 | **somaxconn=65535 tcp_max_syn_backlog=65535 rmem/wmem=128M** | **GLOO_SOCKET_TIMEOUT=300 + send/recv 300s** | ❌ crash 3.5 min（**只延后不解决**）|

不对称 DP 下 sglang 多处 Gloo collective 需要 P/D 对称：
- `scheduler_dp_attn_mixin.py:202 prepare_mlp_sync_batch_raw → all_gather_into_tensor`
- `disaggregation/utils.py:59 poll_and_all_reduce → all_reduce`
- `scheduler.py:1498 broadcast_pyobj → broadcast`

每处都是 Gloo peer sync，任一处 reset 就 SIGABRT。

详细：
- DP Attention 的 MLP sync `all_gather_into_tensor` 走 Gloo TCP
- 该 all_gather 跨 P/D 做 global batch 元信息同步，要求两侧 world_size 匹配
- 只要 P_dp ≠ D_dp，gloo peer 同步阶段读写不对称 → TCP socket peer reset → scheduler Aborted
- 不是整数倍关系可以救，**必须完全相等**

其他候选（未验证，可按需备选）：
1. 关 `--enable-dp-attention`（彻底消除 Gloo all_gather，吞吐可能降）
2. 增大 Gloo TCP timeout：`GLOO_SOCKET_TIMEOUT=300`
3. 调内核：`sysctl -w net.core.somaxconn=65535 net.ipv4.tcp_max_syn_backlog=65535`

## 推荐给客户
- **短期**：把 decode 的 `--dp-size 8` 改为 `--dp-size 2`（和 prefill 对齐）
- **长期**：sglang 该修 `prepare_mlp_sync_batch_raw` 在 asym DP 时的 group 处理，或者文档明确要求 prefill/decode DP size 对称

## Core Dumps

```
/data/export/coredump/core.sglang::data_pa.403.1777463893   1.4 GiB
/data/export/coredump/core.sglang::schedul.493.1777463888   12  GiB
```

可 `scp` 回本地 + `gdb python3 core` 分析。
