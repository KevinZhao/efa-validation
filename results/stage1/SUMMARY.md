# 阶段 1：EFA 基础链路 — 结果

**时间**：2026-04-21 07:50 UTC
**配置**：2× p5.48xlarge Spot (us-east-2b) / 16 × H100 / EFA v2 / NCCL 2.23.4 / aws-ofi-nccl v1.19.0
**镜像**：`788668107894.dkr.ecr.us-east-2.amazonaws.com/yanxi/nccl-tests:v2`
**完整日志**：`all_reduce_alltoall_20260421T075000Z.log`（16327 行）

## all_reduce_perf 8KB–8GB (busBW)

| size | busBW (out-of-place) | busBW (in-place) |
|---:|---:|---:|
| 8 KB | 0.12 GB/s | 0.12 GB/s |
| 64 KB | 0.82 GB/s | 1.54 GB/s |
| 1 MB | 20.05 GB/s | 20.34 GB/s |
| 8 MB | 90.43 GB/s | 91.02 GB/s |
| 128 MB | 311.55 GB/s | 311.84 GB/s |
| 512 MB | 402.93 GB/s | 401.23 GB/s |
| 1 GB | 442.20 GB/s | 442.54 GB/s |
| 4 GB | 467.43 GB/s | 467.63 GB/s |
| **8 GB** | **476.91 GB/s** | **479.25 GB/s** |

**Avg bus bandwidth** (几何平均) = **172.311 GB/s**

## all_to_all_perf 8KB–4GB

**Avg bus bandwidth** = **36.0702 GB/s**（小消息拉低平均，大消息会趋于单向 EFA 物理带宽）

## 判据检查

| 判据 | 目标 | 实测 | 结论 |
|---|---|---|---|
| 跨节点 all-reduce 大消息 ≥ 名义 3.2 Tbps (400 GB/s) 的 80% = 320 GB/s | 320 GB/s | **476 GB/s @ 8GB** / **402 GB/s @ 512MB** | ✅ **超过** |
| `FI_PROVIDER=efa` 生效 | EFA | `NCCL INFO NET/Plugin: Libfabric`, `NET/OFI Selected Provider is efa` 全员出现 | ✅ |
| all-to-all 无异常尖峰 | 无 | 曲线平滑 | ✅ |

## 关键排障记录

1. **ARM Launcher × x86 image** → `nodeSelector: p5.48xlarge` + toleration
2. **`/etc/mpi/discover_hosts.sh` 返回空 HOSTS** → 加轮询等待 worker 注册循环
3. **SSH `Permission denied`** → OpenSSH `StrictModes yes` 拒收 kubeflow projected volume 的 key → 改 base Dockerfile: `StrictModes no`
4. **mpirun 卡住不起 orted** → hostname FQDN 跨节点反查失败 → 加 `--mca orte_keep_fqdn_hostnames 1 --mca oob_tcp_if_include eth0 --mca btl_tcp_if_include eth0`
5. **OpenMPI host:slot 分配不正确** → 用 hostfile `hostX slots=8` 代替 `--host h1,h2`
6. **CUDA runtime insufficient** → 节点上 `/dev/nvidia*` 没注入 container
7. **根因**：EKS GPU AMI 的 `nvidia-device-plugin:v0.15.0` + containerd 2.2 + nvidia-container-toolkit 1.19 在 CDI 自动模式下不工作
8. **方向 D 失败**（改 `mode=auto→legacy`）：所有 pod sandbox 创建报错 `expected cgroupsPath slice:prefix:name` → 回滚 `mode=auto`
9. **方向 B' 成功**：部署 NVIDIA GPU Operator v24.9.2（driver/toolkit disabled，仅替换 device plugin + validator + dcgm）→ GPU 设备正确注入 container

## 环境副产物（留给阶段 2-4 用）

- `yanxi-validation` namespace (SA `yanxi-runner`)
- `gpu-operator` namespace 的完整 operator stack
- `mpi-operator` v0.6.0、LWS v0.7.0
- ECR 镜像：`yanxi/base-cuda-efa:v1`, `yanxi/nccl-tests:v2`
- S3 bucket `yanxi-validation-788668107894`（manifests、logs）
- 堡垒机 kubeconfig ctx: `ohio`
