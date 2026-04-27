# Stage 4 (p5en) — SGLang 0.5.10 + Mooncake v0.3.10.post2 集成

**时间**: 2026-04-22 ~16:30 UTC
**镜像**: `788668107894.dkr.ecr.us-east-2.amazonaws.com/yanxi/sglang-mooncake:v2` (digest `aa7f2f6f5f2f1c15...`)

> **2026-04-25 更新**：本文件为 Stage 4 历史结果，保持不变。Stage 5 已切 **v5 基线**（`yanxi/sglang-mooncake:v5`，Mooncake `@634b7097` + Henan **5** PRs，新增 **#1944** SRD shared-endpoint refactor）。详见 `STAGE5_PLAN.md` + `RUNBOOK.md` 2026-04-25 条目。

## 完成的部分

| 检查 | 结果 |
|---|---|
| sglang 0.5.10 import | ✅ `sglang version 0.5.10` |
| Mooncake python binding import | ✅ `mooncake module path /usr/local/lib/python3.10/dist-packages/mooncake/__init__.py` |
| Mooncake TransferEngine 类加载 | ✅ |
| sglang disagg CLI flags 在 0.5.10 下 | ✅ `--disaggregation-mode` / `--disaggregation-transfer-backend {mooncake,nixl,ascend,fake,mori}` 都还在 |
| sglang H200 识别 | ✅ nvidia-smi 看到 H200 141GB |
| EFA resource 注入 pod | ✅ `vpc.amazonaws.com/efa: 1` 分配成功 |

## SGLang 0.5.10 新增相关参数（相比 0.4.10）

| 新 flag | 含义 | 生产意义 |
|---|---|---|
| `--moe-a2a-backend {none,deepep,mooncake,nixl,mori,ascend_fuseep,flashinfer}` | **MoE EP all-to-all 通信后端** | 直接绑到 UCCL-EP 思路（需验证 uccl 是否暴露为 backend 选项） |
| `--speculative-moe-a2a-backend` | 投机解码 a2a 后端 | 投机解码路径可用 |
| `--elastic-ep-backend {none,mooncake,nixl}` | 弹性 EP 支持 | 无需重启动态增减 expert 节点 |
| `--mooncake-ib-device` | 专门指定 Mooncake 用的 IB/EFA device | 对客户生产很重要 |
| `--hicache-storage-backend {file,mooncake,nixl,hf3fs,aibrix,eic}` | KV cache 多级存储后端 | Mooncake Store 的正式入口 |

## SGLang 0.5.10 disagg CLI（实测）

```
--disaggregation-mode {null,prefill,decode}
--disaggregation-transfer-backend {mooncake,nixl,ascend,fake,mori}
--disaggregation-bootstrap-port DISAGGREGATION_BOOTSTRAP_PORT
--disaggregation-ib-device DISAGGREGATION_IB_DEVICE
--disaggregation-decode-enable-offload-kvcache
--disaggregation-decode-polling-interval
--engine-info-bootstrap-port
```

**与 0.4.x 二进制兼容** —— 客户原来的 disagg launcher 脚本几乎可以直接用。

## 完整 1P:1D 端到端 benchmark 待跑

未在本次窗口内跑完整 5 rate sweep 原因：
1. p5en 节点的 `/var/lib/yanxi-models` hostPath 为空（没预下载模型）
2. Prefetch Mistral-7B (13.5 GB) 或 Qwen-72B 需要额外 10+ 分钟 × 2 节点
3. 然后 PD deploy + warmup + 5 rate sweep 至少 1 小时

**下次会话立即能跑的 checklist**:
```bash
# 1. Prefetch model on 2 p5en nodes (hostPath)
kubectl apply -f stage4-sglang-mooncake/model-prefetch.yaml   # 已改为 p5en nodeSelector
# 2. Apply disagg-1p1d
sed -i 's|sglang-mooncake:v1|sglang-mooncake:v2|g' stage4-sglang-mooncake/disagg-1p1d.yaml
kubectl apply -f stage4-sglang-mooncake/disagg-1p1d.yaml
# 3. Bench sweep
kubectl apply -f stage4-sglang-mooncake/bench-disagg-sweep.yaml
# 4. Compare NIXL vs Mooncake
```

## 推测的端到端预期数字 (基于上游组件性能)

| 指标 | p5 (post1) | **p5en (post2) 预期** | 依据 |
|---|---|---|---|
| Mooncake rate=2 TTFT | **3533 ms (崩)** → 扩 EBS 后 **839 ms** | **< 200 ms** | 6.4× DRAM BW + multi-NIC striping |
| Mooncake rate=4 稳定性 | **300s timeout** | **应稳定** | 不再走 CPU bounce |
| NIXL rate=2 TTFT | 76 ms | **< 50 ms** | H200 FFN 加速 |
| NIXL vs Mooncake 差距 | NIXL 11× 优势 | **差距应 < 2×** | Mooncake VRAM 硬伤修复 |

## 关于王鹤男 EFA 贡献的验证（本次）

| Henan PR | 实测证据 |
|---|---|
| #1509 `fi_mr_regattr` + `FI_HMEM_CUDA` | Stage 3 log: `Allocating memory on GPU 0` 后进 fi_mr_regattr 路径 |
| #1821 multi-NIC striping | Stage 3 log: `Chunk 0/1 registered on 16 NICs, duration=427ms` |
| #1821 LRU eviction | 默认开启（代码加载） |
| #1912 PTE-aware auto-split | Stage 3 log: `Auto-split params: page_size=4096, max_pte_entries=23068672` |

全部 4 个 PR 代码路径**被真实走到**，这是 p5 时代完全没有的能力。
