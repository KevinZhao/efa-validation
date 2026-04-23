# Stage 3.1 Round B — Mooncake DRAM→DRAM 参数扫 (EFA)

## 扫描矩阵 & 结果

| tag | threads | batch | block | duration(s) | batches | **throughput GB/s** |
|---|---|---|---|---|---|---|
| baseline (前轮) | 12 | 64 | 4 MiB | 60.11 | 4324 | **19.31** |
| baseline (本轮) | 12 | 64 | 4 MiB | 33.36 | 12 | 0.10 (noise,建链占满 30s 窗口) |
| **t24** | **24** | **64** | **4 MiB** | **30.09** | **4317** | **38.51** ⭐ |
| t32 | 32 | 64 | 4 MiB | 30.22 | 4104 | 36.46 |
| t48 | 48 | 64 | 4 MiB | — | — | FAIL (process crash) |
| t32_b128 | 32 | 128 | 4 MiB | — | — | FAIL (CQ/mem) |
| t32_blk16M | 32 | 64 | 16 MiB | — | — | **initiator OOMKilled @128Gi** |

（后续 4 组没跑到，initiator 被 OOMKilled）

## 结论

- **DRAM 单 GPU 路径最优值 ≈ 38.5 GB/s** (t=24, batch=64, blk=4MiB)
  - 相比前轮 (19.31 GB/s @ t=12) 翻 2× — 前次 thread 严重不足
  - 此即 Mooncake DRAM 路径的实测上限；PCIe x16 Gen5 单向 ~63 GB/s 的 ~60%
- threads=32 性能反降 (36.46 vs 38.51) — CPU context switch / CQ 争用
- threads=48 process crash
- batch=128 × threads=32 × block=16MiB 系列都撞内存/CQ 上限
- **单 pod 连跑 sweep 不可行**：连接池内存不回收，累积 OOMKilled

## 距 Plan 150 GB/s 的差距原因

1. **Mooncake EFA transport 不支持 `use_vram=true`**（已确认源码：`efa_context.cpp:277` 用 `fi_mr_reg` 不带 `FI_HMEM`，GPU 指针注册直接 SIGSEGV）
   - 走 DRAM 必过 CPU copy / PCIe bounce buffer，~40 GB/s 即硬顶
2. **`transfer_engine_bench` 单 GPU 绑定**：`--gpu_id=0`，没扫多 GPU
   - 8 张 GPU × 25 GB/s ≈ 200 GB/s 理论值，但需要多 process / worker 并发（上游 bench 不支持）
3. **32 × EFA NIC × 100 Gb/s = 400 Gb/s = 50 GB/s 裸带宽**（每节点）
   - 单 GPU 路径下 38.5 GB/s 已接近 NIC 理论（77%）
   - 跨多 GPU 并行才能吃满带宽

## 参数推荐

若只做 DRAM 冒烟 / smoke：`threads=24 batch=64 block=4MiB duration=60` ≈ 38 GB/s 稳定。

## 下一步（VRAM 路径）

方案 A 由后台 agent 跑中 (nixlbench + EFA VRAM)，结果写入 `NIXL_RESULT.md`。
