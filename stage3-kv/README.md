# Stage 3 — KV Cache 跨节点传输（Mooncake 主，NIXL 对照）

Stage 3 目标：Mooncake KV 跨节点传输（EFA v2）。

## 目标

| 路径 | 定位 | 判据 |
|------|------|------|
| **Mooncake Transfer Engine + `efa` 协议** | **主**（目标生产栈 KV 层） | 2 节点跨机 put/get，**单节点聚合吞吐 ≥ 150 GB/s，目标 ≈ 170 GB/s**（8× EFA） |
| NIXL + `LIBFABRIC` backend | 对照 / fallback | 等价 payload 下的带宽 / 延迟相对位置（Mooncake `EFA` 路径若翻车时能否顶上） |

Payload 扫描：`64KB, 1MB, 16MB, 256MB, 1GB` × `put (write)` + `get (read)`。

## 上游 Pinned Refs（2026-04-21 调研）

| 组件 | Ref | 来源 | 备注 |
|------|-----|------|------|
| Mooncake | **`v0.3.10.post1`** (2026-04-01) | `github.com/kvcache-ai/Mooncake/releases` | `cmake -DUSE_EFA=ON -DUSE_CUDA=ON`；bench 走 `transfer_engine_bench --protocol=efa`；env var `MOONCAKE_PROTOCOL=efa`；Python 包在 `mooncake-wheel/` |
| NIXL | **`v1.0.1`** (2025-04-14) | `github.com/ai-dynamo/nixl/releases` | EFA 通过 `--backend LIBFABRIC` + `src/plugins/libfabric/`；meson 用 `enable_plugins=UCX,LIBFABRIC,MOONCAKE`；`nixlbench` 走 ETCD 协调 |
| UCX | `v1.18.0` | NIXL UCX backend 依赖（triage 备份） | 在镜像里一并构建；主路径不走 UCX |

## 产物

| 文件 | 作用 |
|------|------|
| `../common/Dockerfile.mooncake-nixl` | 同时构建 Mooncake TE (USE_EFA=ON) + NIXL (LIBFABRIC plugin)；基于 `base-cuda-efa:v1` |
| `job-mooncake-bench.yaml` | MPIJob：2 节点跨机 Mooncake `transfer_engine_bench` |
| `job-nixl-bench.yaml` | MPIJob：2 节点跨机 NIXL `nixlbench`（payload 与上一 job 对齐，Launcher 内跑 etcd 做 rendezvous） |

## 构建镜像

```bash
# 在本机（本 repo 根目录），复用阶段 0 / 阶段 1 的 builder + ECR 流水线：
./scripts/build-image.sh \
    common/Dockerfile.mooncake-nixl \
    mooncake-nixl \
    v1 \
    --build-arg=BASE_IMAGE=<AWS_ACCOUNT_ID>.dkr.ecr.us-east-2.amazonaws.com/efa-validation/base-cuda-efa:v1
```

镜像 Dockerfile 已把 `MOONCAKE_REF` / `NIXL_REF` / `UCX_VERSION` 写死成上游验证过的 tag；
如果要尝试更新的 commit，用 `--build-arg MOONCAKE_REF=<sha>` 单独覆盖，而不是改 Dockerfile 默认值。

构建完成后 ECR 会得到：

```
<AWS_ACCOUNT_ID>.dkr.ecr.us-east-2.amazonaws.com/efa-validation/mooncake-nixl:v1
<AWS_ACCOUNT_ID>.dkr.ecr.us-east-2.amazonaws.com/efa-validation/mooncake-nixl:latest
```

镜像内置 build-time sanity checks：`fi_info -p efa`、`transfer_engine_bench` 二进制、
`nixlbench` 二进制、`python3 -c "import mooncake"`，缺一则 build 失败——避免把半坏镜像推 ECR。

## 运行

```bash
# 堡垒机（Ohio）上，前置资源已在 RUNBOOK 里就绪：
kubectl apply -f ../common/00-namespace.yaml          # 幂等
kubectl apply -f job-mooncake-bench.yaml              # 主路径
# 跑完后拉日志；gate 通过再跑对照：
kubectl apply -f job-nixl-bench.yaml                  # fallback / 对照
```

观察 / 取日志：

```bash
kubectl -n efa-validation get mpijob
kubectl -n efa-validation logs -f job/mooncake-bench-efa-launcher
# 汇总日志落在 launcher 容器的 /tmp/：
#   /tmp/mooncake-bench-<stamp>.summary.log
#   /tmp/mooncake-bench-<stamp>.client.log
#   /tmp/mooncake-bench-<stamp>.server.log
# NIXL 对应：
#   /tmp/nixl-bench-<stamp>.summary.log
#   /tmp/nixl-bench-<stamp>.initiator.log
#   /tmp/nixl-bench-<stamp>.target.log
#   /tmp/nixl-bench-<stamp>.env.log
```

上传日志到 S3（和阶段 1 的惯例保持一致）：

```bash
kubectl -n efa-validation cp \
    <launcher-pod>:/tmp/ \
    ./logs/stage3-kv/ \
    -c launcher
aws s3 sync ./logs/stage3-kv/ s3://efa-validation-<AWS_ACCOUNT_ID>/logs/stage3-kv/
```

## 期望判据

| 检查项 | 判据 | 不达则 |
|--------|------|-------|
| EFA provider 可见 | 两个 worker 上 `fi_info -p efa -t FI_EP_RDM` 均输出至少 1 条 endpoint | 先查节点 EFA 驱动 / SG 规则，阶段 1 已踩过的坑 |
| Mooncake TE 走 `efa` 协议 | 客户端日志里出现 `protocol=efa` / libfabric 启动行 | 若仍走 tcp/rdma，查 `MOONCAKE_PROTOCOL` 是否被底层覆盖；检查镜像里 `USE_EFA` 是否实际 ON |
| **Mooncake 单节点聚合吞吐** | **≥ 150 GB/s（目标 ≈ 170 GB/s）** in 大 payload 段（256MB / 1GB） | 先排查 SRD / libfabric 配置；仍差距大 → Mooncake 上游 issue + 端到端切 NIXL fallback |
| Mooncake 尾延迟 | 1MB 段 p99 / p50 比值 ≤ 3 | 记录即可，不作 gate；长尾详细结论回传上游 |
| NIXL LIBFABRIC backend 可用 | initiator 日志含 `backend=LIBFABRIC`，且 ETCD rendezvous 成功 | 看 `/tmp/etcd.log`；若 plugin 不加载，验证 `/opt/nixl/lib/plugins/libfabric*.so` 存在 |
| NIXL 对照 | 同 payload 下带宽相对 Mooncake 的位置 | 给上层一个外部参照数字；若反超，也只是 fallback 的利好 |

## 已知 TODO / 风险项

- [ ] **Mooncake `efa_latency_bench.py`**：镜像里已有
  `/opt/mooncake/mooncake-transfer-engine/example/efa_latency_bench.py`，它是上游自带的
  SSH-driven 延迟 sweep 脚本（画图用）。目前 job 没调用它；跑完主流程后如果想补延迟曲线，
  可以手动 `kubectl exec` 到 launcher 直接跑（`--build_dir=/opt/mooncake/build`）。
- [ ] **NIXL python binding 路径**：v1.0.1 用 `src/bindings/python/`；Dockerfile 里有 fallback，
  如果导入失败只影响 python 级别的对照脚本，C++ `nixlbench` 主路径不受影响。
- [ ] **etcd 版本**：Launcher 先用 `dependencies.sh` 安装的 etcd，否则 fallback 拉 `v3.5.13`
  release 二进制。如果目标环境禁止出网，需要预先把 etcd 打进镜像（TODO: 下一轮加到 Dockerfile）。
- [ ] **Mooncake `transfer_engine_bench` 的 `--duration` 语义**：v0.3.10.post1 的 bench 是 duration-driven（持续 N 秒而不是跑固定 iterations），所以 `NUM_ITER` 在 mooncake job 里不用；nixl 用 `--num_iter`。
- [ ] **大 payload 段 OOM 防护**：1GB `--block_size` × `--threads=8` × `--batch_size=128`
  默认会在 initiator 侧 allocate ~1TB VRAM——transfer_engine_bench 会自动循环复用 buffer，
  但首轮跑之前最好在单卡上 smoke test 一次，避免直接在 16 卡上爆。

## 参考

- Mooncake 协议支持：https://kvcache-ai.github.io/Mooncake/getting_started/supported-protocols.html
- Mooncake build 指南：https://kvcache-ai.github.io/Mooncake/getting_started/build.html
- Mooncake bench 源：`mooncake-transfer-engine/example/transfer_engine_bench.cpp` @ v0.3.10.post1
- NIXL release notes：https://github.com/ai-dynamo/nixl/releases/tag/v1.0.1
- NIXL bench README：https://github.com/ai-dynamo/nixl/blob/v1.0.1/benchmark/nixlbench/README.md
- NIXL meson_options：https://github.com/ai-dynamo/nixl/blob/v1.0.1/meson_options.txt
- AWS 官宣 NIXL on EFA：https://aws.amazon.com/about-aws/whats-new/2026/03/aws-support-nixl-with-efa/
- 基础镜像：`../common/Dockerfile.base-cuda-efa`
- 阶段 1 结构参考：`../stage1-nccl-tests/mpijob-nccl-tests.yaml`
- 构建脚本：`../scripts/build-image.sh`
