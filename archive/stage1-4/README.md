# Stage 1-4 归档

Stage 1-4 已于 2026-04-22/23 在 p5 / p5en 上完成执行，结论见 `../../results/STAGE1-4_P5EN_SUMMARY.md`。
此目录下保留的是**当时实际 `kubectl apply` 过的 manifest**，用于历史复现。
当前主线（Stage 5+）见仓库根 `STAGE5_PLAN.md` + `manifests/stage5-p5en/`。

## 目录对照

| 归档路径 | 阶段 | 说明 |
|---|---|---|
| `stage1-nccl-tests/` | 1 | NCCL all-reduce MPIJob，得到 EFA busBW 基线 (p5en 479.97 GB/s) |
| `stage3-kv/` | 3 | Mooncake + NIXL bench job 模板（v0.3.10.post1）|
| `stage3-mooncake-nixl/` | 3 | Mooncake `transfer_engine_bench` over EFA（DRAM/VRAM sweep）|
| `stage3-nixl-bench/` | 3 | NIXL `nixlbench` over LIBFABRIC（对照组）|
| `stage4-e2e/` | 4 | PD 1P:1D LWS 初版架构（被 `stage4-sglang-mooncake/` 取代）|
| `stage4-sglang-mooncake/` | 4 | p5 上 SGLang 0.4.10 + Mooncake PD 实测 manifest |
| `stage4-p5en/` | 4 | p5en 上 SGLang 0.5.10 + Kimi-K2 1P:2D；**`KIMI_K2_SETUP_GUIDE.md` 对外可复现指南** |
| `common/` | 1-4 | 历史 Dockerfile：`base-cuda-efa`、`nccl-tests-v2`、`mooncake-nixl`、`sglang-mooncake` |
| `ssm-payloads/` | 1-4 | 历史 build SSM payload（一次性固化，已不复用） |

### Dockerfile 归档说明

Stage 1-4 的共同基础链 base-cuda-efa → {nccl-tests, uccl-ep, mooncake-nixl, sglang-mooncake}
已归档到 `common/`。这些 Dockerfile 构建出的 ECR tag（`base-cuda-efa:v1`、`nccl-tests:v2`、
`mooncake-nixl:v5`、`sglang-mooncake:v5`）**仍在 ECR 上可用**，部分被当前镜像作为 `BASE_IMAGE`
引用（如 `Dockerfile.sglang-mooncake-uccl` 的 base 是 `sglang-mooncake:v5`）。但**不再从源码重建**。

若需要重建 Stage 1-4 镜像：
```bash
# 把 Dockerfile 恢复到 common/（或直接在 archive 路径下构建）
./scripts/build-image.sh archive/stage1-4/common/Dockerfile.base-cuda-efa base-cuda-efa v1
```

完全弃用的 `Dockerfile.nccl-tests`（最初的 pytorch 24.10 单层 base，build 过慢放弃）已 `git rm`，
git 历史可追溯。

## 对应的测量数据（未归档，仍在 `results/`）

- `results/stage1/`, `results/stage1-p5en/`
- `results/stage2/`, `results/stage2-p5en/`, `results/stage2-p5en-2026-04-23/`
- `results/stage3/`, `results/stage3-p5en/`
- `results/stage4/`, `results/stage4-p5en/`
- `results/STAGE1-4_P5EN_SUMMARY.md`
- `results/NG_INVENTORY.md`

## 重要基线数据（供 Stage 5+ 引用）

- `results/stage4/NIXL_VS_MOONCAKE_COMPARISON.md` — 同环境同 workload 下 NIXL vs Mooncake 对照（Lane K 判定依据）
- `results/stage4/TP16_VS_TP8_EFA.md` — EFA 上 TP all-reduce 代价实测
- `results/stage4-p5en/KIMI_K2_RESULTS.md` — Kimi-K2 1T MoE 在 p5en 的实测数据

## 镜像基线说明

Stage 1-4 运行在 **v2 镜像基线**（Mooncake v0.3.10.post2 + Henan 4 EFA PRs，不含 #1944）。
Stage 5 起已切 v5 基线（追加 #1944），Stage 1-4 的数字**不再作为新运行的对照**，
但作为"v2 基线"保留历史可溯源性。

## 恢复到可运行状态

如果需要重跑其中某个阶段：

```bash
# 示例：重跑 Stage 1 NCCL all-reduce
kubectl apply -f archive/stage1-4/stage1-nccl-tests/mpijob-nccl-tests.yaml
```

注意 manifest 内的镜像 tag 是 v1/v2，按需升级到 v5 或 customer-h200 镜像。
