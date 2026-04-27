# Mooncake vs NIXL 性能对比

**生成日期**：2026-04-27

**数据来源**：
- `results/stage5-p5en/lane-k/20260426T134313Z-p5en-nixl-vs-mooncake-nccl/` — p5en EFA v3
- `results/stage5-p5en/lane-k/20260426T111002Z-p5-nixl-vs-mooncake/` — p5 EFA v2
- `results/stage5-p5en/lane-k/K_VS_MOONCAKE.md` — 汇总表

**测试配置**：
- 镜像 `yanxi/mooncake-nixl:v6.1`，digest `sha256:0970bdb3...227f2`
- Mooncake v0.3.10.post2（upstream @`634b7097`）
- NIXL v1.0.1（meson build，LIBFABRIC 后端）
- 2 节点，同 AZ，DRAM → DRAM，WRITE op，12-tuple (block × threads × batch) 扫描

---

## 1. p5en.48xlarge · EFA v3（16 × 200 Gbps = 400 GB/s 线速）

**Hardware**：2 × p5en.48xlarge (H200 × 8)，us-east-2b
**Run ID**：`20260426T134313Z-p5en-nixl-vs-mooncake-nccl`

| ID  | Block  | Thr | Batch | Mooncake GB/s | NIXL GB/s | Δ% (MC−NIXL) |
|-----|-------:|----:|------:|--------------:|----------:|-------------:|
| p01 | 64 KB  | 4   | 8     | 27.72         | 32.34     | **−14.3%**   |
| p02 | 64 KB  | 4   | 32    | 49.34         | 72.08     | **−31.5%**   |
| p03 | 64 KB  | 4   | 128   | 62.72         | 63.50     | −1.2%        |
| p04 | 256 KB | 4   | 8     | 88.63         | 45.18     | **+96.2%**   |
| p05 | 256 KB | 4   | 32    | 147.00        | 93.92     | **+56.5%**   |
| p06 | 256 KB | 4   | 128   | 171.58        | 58.87     | **+191%**    |
| p07 | 1 MB   | 4   | 8     | 163.46        | 134.23    | **+21.8%**   |
| p08 | 1 MB   | 4   | 32    | 189.95        | 110.79    | **+71.4%**   |
| p09 | 1 MB   | 4   | 128   | 201.92        | 110.54    | **+82.7%**   |
| p10 | 4 MB   | 4   | 8     | **205.04**    | 107.29    | **+91.1%**   |
| p11 | 4 MB   | 4   | 32    | 200.48        | 110.04    | **+82.2%**   |
| p12 | 16 MB  | 4   | 8     | 204.99        | 109.21    | **+87.7%**   |

**聚合**：

| 指标 | Mooncake | NIXL |
|------|---------:|-----:|
| 峰值 GB/s | **205.04** @ 4M×4×8 | 134.23 @ 1M×4×8 |
| 几何均值（12 点） | 117.9 | 80.5 |
| 占 EFA 400 GB/s 线速 | 51.3% | 33.6% |
| 胜点数 | **9/12** | 3/12（全在 64 KB 块） |

---

## 2. p5.48xlarge · EFA v2（32 × 100 Gbps = 400 GB/s 线速）

**Hardware**：2 × p5.48xlarge (H100 × 8)，us-west-2c
**Run ID**：`20260426T111002Z-p5-nixl-vs-mooncake`

| ID  | Block  | Thr | Batch | Mooncake GB/s | NIXL GB/s | Δ% (MC−NIXL) |
|-----|-------:|----:|------:|--------------:|----------:|-------------:|
| p01 | 64 KB  | 4   | 8     | 20.26         | 19.95     | +1.6%        |
| p02 | 64 KB  | 4   | 32    | 33.76         | 38.04     | −11.2%       |
| p03 | 64 KB  | 4   | 128   | 48.59         | 34.16     | +42.2%       |
| p04 | 256 KB | 4   | 8     | 52.99         | 38.27     | +38.5%       |
| p05 | 256 KB | 4   | 32    | **61.12**     | 55.40     | +10.3%       |
| p06 | 256 KB | 4   | 128   | 37.22         | 50.70     | −26.6%       |
| p07 | 1 MB   | 4   | 8     | 51.69         | 36.56     | +41.4%       |
| p08 | 1 MB   | 4   | 32    | 47.73         | 29.54     | +61.6%       |
| p09 | 1 MB   | 4   | 128   | 21.27         | 32.14     | −33.8%       |
| p10 | 4 MB   | 4   | 8     | 40.95         | 13.17     | **+210.9%**  |
| p11 | 4 MB   | 4   | 32    | 40.00         | **75.24** | −46.8%       |
| p12 | 16 MB  | 4   | 8     | 49.21         | 30.79     | +59.9%       |

**聚合**：

| 指标 | Mooncake | NIXL |
|------|---------:|-----:|
| 峰值 GB/s | 61.12 @ 256K×4×32 | 75.24 @ 4M×4×32 |
| 胜点数 | 7/12 | 5/12 |

---

## 3. 硬件升级 p5 → p5en 倍率(同 12 tuple)

| Tuple | p5 MC | p5en MC | MC 倍率 | p5 NIXL | p5en NIXL | NIXL 倍率 |
|-------|------:|--------:|:-------:|--------:|----------:|:---------:|
| p05 256K×4×32 | 61.1 | 147.0 | **2.4×** | 55.4 | 93.9  | 1.7×     |
| p07 1M×4×8    | 51.7 | 163.5 | 3.2×     | 36.6 | 134.2 | 3.7×     |
| p08 1M×4×32   | 47.7 | 190.0 | **4.0×** | 29.5 | 110.8 | 3.8×     |
| p10 4M×4×8    | 41.0 | 205.0 | 5.0×     | 13.2 | 107.3 | **8.1×** |
| p12 16M×4×8   | 49.2 | 205.0 | **4.2×** | 30.8 | 109.2 | 3.5×     |

**12 点几何均值倍率**：
- Mooncake：**2.95×**
- NIXL：**2.20×**

---

## 4. NCCL NVLink 参考线(同 p5en 单节点 8 GPU)

**Run ID**：`20260426T134313Z-p5en-nixl-vs-mooncake-nccl/nccl-single-node.txt`
走 NVLink 4th-gen intra-node，不走 EFA。

| Msg size | NCCL busbw GB/s | 占 NVLink 400 GB/s |
|---------:|----------------:|-------------------:|
| 1 MB     | 39              | 9.8%               |
| 8 MB     | 183             | 45.8%              |
| 64 MB    | 325             | 81.3%              |
| 256 MB   | **347**         | **86.7%**          |

---

## 5. Mooncake 延迟分布(p5en p08 1M×4×32)

| 指标 | Mooncake | NIXL |
|------|---------:|-----:|
| avg_prep (µs) | 未显著 | 3615 |
| p99_prep (µs) | 未显著 | 7210 |

---

## 6. 测试参数

**Mooncake 侧**：
- `MC_WORKERS_PER_CTX=2`
- `MC_NUM_CQ_PER_CTX=2`
- `--use_vram=false`（DRAM 模式）

---

## 7. 数据可信度声明

- 同镜像 digest：`0970bdb3...227f2`
- 同 12 tuple 参数空间
- 同 AZ 同 NIC 数
- 同 WRITE + DRAM→DRAM 模式
- ⚠️ `batch` 参数在 Mooncake (per-thread concurrent slices) 与 NIXL (per-xfer descriptor ops) 语义不完全对等
- ⚠️ p5en 未做重复性验证（单轮）
- ⚠️ NCCL 只有单节点 NVLink baseline，不是 EFA 2-node baseline

---

## 8. 原始数据归档

- `results/stage5-p5en/lane-k/20260426T134313Z-p5en-nixl-vs-mooncake-nccl/mc-sweep.csv`
- `results/stage5-p5en/lane-k/20260426T134313Z-p5en-nixl-vs-mooncake-nccl/nixl-sweep.csv`
- `results/stage5-p5en/lane-k/20260426T134313Z-p5en-nixl-vs-mooncake-nccl/nccl-single-node.txt`
- `results/stage5-p5en/lane-k/20260426T111002Z-p5-nixl-vs-mooncake/mc-sweep.csv`
- `results/stage5-p5en/lane-k/20260426T111002Z-p5-nixl-vs-mooncake/nixl-sweep.csv`
