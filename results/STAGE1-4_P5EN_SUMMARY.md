# Stage 1–4 on p5en (2026-04-22) — 执行总结

## 环境

| 项 | 值 |
|---|---|
| 节点 | **3× p5en.48xlarge** (us-east-2a) + 2× p5.48xlarge (us-east-2b, 保留) |
| GPU | H200 141GB HBM3e × 8/node = 24 张 H200 |
| EFA | v3, 16 NIC × 200 Gb/s = 3.2 Tbps / node |
| Driver | 580.126.09 (内建 GDR，不需要 nvidia_peermem 模块) |
| CUDA | 13.0 |
| K8s | EKS 1.35.3 / Amazon Linux 2023 / containerd 2.2.1 |
| GPU Operator | **v25.10.1** (`toolkit.enabled=true` + cdi) |

## 结果对比总表

| Stage | p5 (旧) | **p5en (新)** | 提升 | 状态 |
|---|---|---|---|---|
| **1 NCCL all-reduce 8GB busBW** | 476 GB/s | **479.97 GB/s** | +1% | ✅ PASS |
| **2 UCCL-EP Dispatch+Combine /rank** | 6.92–7.02 GB/s | **36.49–36.64 GB/s** | **5.2×** | ✅ PASS |
| **2 UCCL-EP correctness** | 16/16 | **16/16** | = | ✅ PASS |
| **3 Mooncake DRAM throughput** | 19.31 GB/s (post1, t=12) | **123.20 GB/s** (post2, t=12) | **6.4×** | ✅ PASS |
| **3 Mooncake VRAM throughput** | SIGSEGV (无 FI_HMEM) | ⚠️ SIGSEGV (新 transport_engine_bench bug) | - | ⚠️ 待排查 |
| 4 SGLang 1P:1D | Mistral-7B 46× 崩 / NIXL 76ms TTFT | 待测 | - | 🔄 进行中 |

## 关键突破

### 1. Stage 2 UCCL-EP 跨代跃进
- **H200 HBM3e 4.8 TB/s** vs H100 HBM3 3.35 TB/s — 内存带宽 +43%
- MoE all-to-all 小消息场景下跨机 BW 直接 5× 增长
- 对比 IB + DeepEP 公开数字 (~10 GB/s/rank)：p5en+UCCL-EP **超过 IB 方案 3.5×**
- MoE decode TPOT 中 EP 占比预计从 50-80% 降到 15-25%

### 2. Stage 3 Mooncake 多 NIC 聚合生效
王鹤男 4 个 PR（#1509 / #1523 / #1821 / #1912）全部生效：
- `fi_mr_regattr` + `FI_HMEM_CUDA` — GPU 内存注册 API (#1509/#1912)
- `Started 16 CQ polling worker threads` — 每 NIC 1 CQ (#1821)
- `Chunk 0/1 registered on 16 NICs, duration=427ms` — 自动 striping (#1821)
- `Auto-split params: page_size=4096, max_pte_entries=23068672` — PTE-aware (#1912)

**打破之前的 40 GB/s "单 NIC 天花板"**（SWEEP_RESULT_B 里基于 post1 的错误结论）。

### 3. GPU Operator 升级解锁 p5en
- v24.9.2 在 CUDA 13 / driver 580 上配不出 containerd runtime handler
- **v25.10.1 + toolkit.enabled=true** 自动 `nvidia-ctk runtime configure`
- Pod sandbox 里 `/dev/nvidia*` + `nvidia-smi` 全部正常

## 关键踩坑 + 解决

| 问题 | 原因 | 修复 |
|---|---|---|
| GPU Operator v24.9.2 `failed` | chart 不支持 CUDA 13 / driver 580 / H200 PCI ID | uninstall + install v25.10.1，开 toolkit + cdi |
| p5 节点上 sglang-tp16 正在运行怕被打断 | - | 给 p5 节点打 `nvidia.com/gpu.deploy.*=false` label, Operator 跳过 |
| Mooncake post2 cmake 失败 | `WITH_STORE_RUST=ON` 默认但依赖 `WITH_STORE=ON` | Dockerfile 加 `-DWITH_STORE_RUST=OFF` |
| EFA NIC 数量 32→16 | p5en 是 16 × 200 Gb (不是 32 × 100 Gb) | 批量 sed 所有 manifest `vpc.amazonaws.com/efa: 32→16` |
| Mooncake VRAM SIGSEGV | bench 代码 VRAM 初始化某问题 | Stage 4 绕开（走 sglang Python API）|
| sglang-launcher.sh COPY 失败 | build-image.sh 只传 Dockerfile | base64 嵌入 Dockerfile RUN |
| Dockerfile ADD S3 URL 403 | S3 object 默认私有 | 改用内嵌 base64 decode |

## 版本锁定（可复现）

```
ECR 788668107894.dkr.ecr.us-east-2.amazonaws.com/yanxi/:
├── base-cuda-efa:v1       (复用 p5 镜像)
├── nccl-tests:v2          (Stage 1, 复用)
├── uccl-ep:v2             (Stage 2, 复用)
├── mooncake-nixl:v2       (Stage 3 新镜像, Mooncake e1d6d6f6 = post2 SHA)
└── sglang-mooncake:v2     (Stage 4 新镜像, sglang 0.5.10 on mooncake-nixl:v2)
```

## 文件
- `results/stage1-p5en/SUMMARY.md`
- `results/stage2-p5en/SUMMARY.md`
- `results/stage3-p5en/SUMMARY.md`
- `results/stage4-p5en/SUMMARY.md` (待生成)
- `logs/s3://yanxi-validation-788668107894/logs/stage{1,2,3}-p5en/`
