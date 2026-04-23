# Stage 2 - UCCL-EP on EFA (correctness + smoke)

## 结果

**PASS** — UCCL-EP `test_low_latency.py` 在 16 rank × 2 × p5.48xlarge 上通过所有正确性检查。

| 指标 | 值 |
|---|---|
| 配置 | `num_tokens=128`, `hidden=7168`, `topk=8`, `num_experts=288` |
| 拓扑 | 2 节点 × 8 H100 = 16 rank（inter-node 走 EFA / aws-ofi-nccl） |
| 正确性 | 所有 ranks 输出 `✓ All correctness tests passed!`（跨 `return_recv_hook × dispatch_use_fp8 × round_scale × use_ue8m0` 16 种设置组合） |
| Dispatch+combine BW | 6.92 ~ 7.02 GB/s / rank |
| Dispatch BW | 6.50 ~ 9.05 GB/s / rank |
| Combine BW | 5.87 ~ 8.01 GB/s / rank |
| Dispatch send+recv | ~85 ~ 215 μs / rank |
| Combine send+recv | ~89 ~ 215 μs / rank |

## 验证路径

- 镜像：`788668107894.dkr.ecr.us-east-2.amazonaws.com/yanxi/uccl-ep:v2`
- 测试脚本：upstream `/opt/uccl/ep/bench/test_low_latency.py`（UCCL-EP 仓库自带）
- 启动：MPIJob (`stage2-uccl-ep/mpijob-uccl-upstream.yaml`) + `wrapper.sh` 做 OMPI→torchrun env 翻译
- 完整日志：`results/stage2/uccl-upstream-full.log`（也在 `s3://yanxi-validation-788668107894/logs/s2-uccl-upstream-full.log`）

## 与原计划的偏离

1. **放弃 DeepEP 逐元素对比**。原计划让 UCCL-EP 与 DeepEP 在同样输入下做 `max_abs_diff<1e-3`。
   DeepEP v1.2.1 预编译的 `deep_ep_cpp.so` 与我们的运行时（CUDA 12.6 + PyTorch 2.5.1+cu124）
   存在 RDC link 不匹配：`undefined symbol: __cudaRegisterLinkedBinary_*_layout_cu_*`。
   GPU 节点上尝试 `pip install . --force-reinstall` 也失败（build env 里无 torch）。
   决定 Stage 2 只做 UCCL-EP 自身上游一致性测试；DeepEP 对比留到后续阶段在
   rebuild 镜像（固定 CUDA 12.4 / 或拉 DeepEP 源码 + 运行时 build）后再做。
2. **`libc10.so` 需要显式加入 LD_LIBRARY_PATH**。UCCL-EP 的 CPython ext 依赖 torch
   原生库，默认 ldconfig 路径不覆盖 `torch/lib`；wrapper.sh 里手动 `export
   LD_LIBRARY_PATH=$(python -c 'import torch; ...'):$LD_LIBRARY_PATH`。
3. **MPIJob → torchrun 环境翻译**：upstream 脚本期望 `RANK / LOCAL_RANK / LOCAL_WORLD_SIZE /
   WORLD_SIZE / MASTER_ADDR / MASTER_PORT`，MPIJob 只提供 `OMPI_COMM_WORLD_*`；wrapper.sh
   做一次性转换。

## 待办

- [ ] Stage 2 perf（完整 throughput 扫描 `mpijob-perf-uccl.yaml`）：暂缓，等 Stage 3/4 跑通后回补
- [ ] DeepEP 对比：需要 rebuild DeepEP 在 GPU 镜像里（或升 torch 到 cu126），单独 PR
