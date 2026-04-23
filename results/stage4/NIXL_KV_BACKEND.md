# Stage 4 — NIXL KV Transport on EFA（方案 C，已出完整数据）

## 目标

把 sglang 1P:1D 的 KV backend 从 Mooncake 切到 NIXL，验证 TTFT 是否改善 + 整体稳定性。

## 通路搭建（共 5 个集成层的 gap，均有 workaround）

| # | 问题 | 根因 | 修复 |
|---|------|------|------|
| 1 | `ModuleNotFoundError: nixl._api` | 镜像包名是 `nixl_cu12`，sglang 期望 `nixl` | site-packages 建 symlink `nixl → nixl_cu12` |
| 2 | `ImportError: libnixl.so: cannot open…` | `/opt/nixl/lib/x86_64-linux-gnu` 不在 `ld.so` 路径 | `/etc/ld.so.conf.d/nixl.conf` + `ldconfig` |
| 3 | `Error accessing directory /opt/nixl/lib/plugins` | NIXL 默认 plugin dir 不存在 | symlink + `NIXL_PLUGIN_DIR=/opt/nixl/lib/plugins` |
| 4 | `register_memory() got unexpected keyword 'is_sorted'` | NIXL v1.0.1 签名变了 | `sed -i 's/, is_sorted=False//g' …/nixl/conn.py` |
| 5 | **UCX backend 卡死 KV transfer**（warmup 1800s timeout） | sglang 默认 `nixl_agent(uuid)` → `backends=["UCX"]`；镜像 UCX <1.19 在 EFA 上无 CUDA 支持 | sed patch conn.py 强制 `nixl_agent_config(backends=["LIBFABRIC"])` + plugin 目录只留 `libplugin_LIBFABRIC.so` |

完整 launcher 实现见 `stage4-sglang-mooncake/launcher-v2.yaml`。

## 结果（Mistral-7B，1P:1D，TP=8 跨 2 节点 EFA）

### NIXL (LIBFABRIC backend) 完整 sweep — 5 rates

| rate | req/s | TTFT mean (ms) | TTFT p99 (ms) | ITL mean (ms) | ITL p99 (ms) | E2E mean (ms) | out tok/s | total tok/s |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 2   | 2.47  | **76.27**   | 576.50  | 2.87 | 4.75  | 452.58  | 325.83 | 1590  |
| 4   | 4.89  | **47.55**   | 77.21   | 2.67 | 5.11  | 397.73  | 645.51 | 3150  |
| 8   | 9.58  | **50.08**   | 75.93   | 2.81 | 5.69  | 418.07  | 1265.65 | 6177 |
| 16  | 18.26 | **61.77**   | 217.90  | 3.09 | 7.28  | 467.51  | 2413.10 | 11777 |
| inf | 47.42 | **1181.83** | 1950.38 | 4.78 | 16.90 | 1808.62 | 6265.85 | 30581 |

**关键特征**:
- TTFT 在 rate 2-16 稳定在 50-80 ms（比 Mooncake rate=2 的 3533ms **低 ~70 倍**）
- ITL 2.7-7.3 ms（stream 生成稳）
- total token throughput 线性扩展至 rate=16 达 11.8k tok/s，inf 突破 30k tok/s
- 全程 5 rates 无崩溃、无 evict（EBS 已扩 2TB）

### Mooncake baseline（上轮同环境 Mistral-7B）

| rate | req/s | TTFT mean (ms) | 备注 |
|---:|---:|---:|---|
| 2   | — | 3533 | prefill 在 rate=2 后崩溃 |
| 4/8/16/inf | — | — | 未完成，prefill 崩 |

## 对比结论

| 维度 | Mooncake | NIXL (LIBFABRIC) | 差距 |
|---|---|---|---|
| rate=2 TTFT | 3533 ms | 76 ms | **NIXL 快 46×** |
| 稳定性（5 rate sweep） | 崩在 rate=2 | 5/5 全通 | NIXL 完胜 |
| 最高 sustained tok/s | < rate=2 已崩 | 30581 (inf) | — |
| 集成难度 | EFA transport 缺 FI_HMEM | 5 层 workaround（见上表） | 均可 patch |

## 关键发现

1. **Mooncake EFA transport 的 VRAM 路径不可用**（`fi_mr_reg` 无 `FI_HMEM`）——KV 走 CPU bounce buffer 导致 rate≥2 就垮
2. **NIXL 必须用 LIBFABRIC backend，不能用 UCX**：镜像 UCX <1.19 在 EFA 上连 agent 注册都通不过（warmup 1800s timeout）
3. **sglang 默认 nixl 构造未暴露 backend 参数**：必须 monkey-patch `conn.py` 传 `nixl_agent_config(backends=["LIBFABRIC"])`
4. **EBS 容量是 PD 稳定性的前置条件**：50GB root 不够容纳 13.5GB 模型 + container runtime + sglang logs，会触发 kubelet evict → 已扩 2TB × 4 vols（root + data × 2 节点），iops 16000 / 吞吐 1000 MB/s

## 生产部署 checklist

- ✅ EBS root ≥ 2TB，数据盘 ≥ 2TB，gp3 iops ≥ 16000，throughput ≥ 1000 MB/s
- ✅ NIXL 镜像构建时安装 LIBFABRIC plugin，runtime 确保 `/opt/nixl/lib/plugins/` 只暴露 LIBFABRIC
- ✅ sglang nixl/conn.py 的 `nixl_agent(...)` 调用必须指定 `backends=["LIBFABRIC"]`
- ✅ EFA v2 libfabric ≥ 2.4.0（PXN over EFA 需要）
- ⚠️ 如果生产是 IB 而非 EFA，换用 UCX plugin 并确保 UCX ≥ 1.19 w/ CUDA

## 归档

- `launcher-v2.yaml` — NIXL 运行时 + 5 层 sed patch
- `disagg-1p1d.yaml` — `KV_TRANSPORT_BACKEND=nixl`
- `bench-disagg-sweep.yaml` — 5-rate sweep job
- `/var/lib/yanxi-logs/stage4/disagg-summary.tsv` 节点侧备份
- raw per-rate logs: `bench-disagg-sweep-wvwkk:/results/disagg-rate-{2,4,8,16,inf}.{json,log}`
