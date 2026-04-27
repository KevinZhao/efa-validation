# Lane E · TECH_DELTA — UCCL-EP vs NCCL-EP on EFA

**范围**：纯架构 / 代码静态差异。**不含任何性能数字**（那部分在 `E_VS_NCCL.md`）。
**基线版本**：
- UCCL-EP：OSDI'26 参考实现（commit 待锁，在 `IB_REFERENCE.md` 中记录）
- NCCL：v2.23.4（Stage 4 验证过的 EFA 路径）
- SGLang 0.5.10（`--moe-a2a-backend {none,nccl,uccl}`）
**硬件**：p5en.48xlarge (H200 × 8, EFA v3 × 16 × 200 Gb/s = 3.2 Tbps/node)，libfabric efa provider。
**不做结论**：本表只描述"哪里不一样"，不评"谁更好"。**IB 参考数字仅做趋势标注，不与 EFA 直接对齐**。

---

## 1. 一句话对比

| NCCL-EP | UCCL-EP |
|---|---|
| NCCL 原生 all-to-all（ring/tree/xhier），每 rank 发/收**固定 tensor**（全量 a2a） | 自研 dispatch+combine kernel，**按 top-k routing 稀疏**发送，bypass NCCL coll |
| 成熟、通用、稳定；SGLang 默认路径 | OSDI'26 论文方案；EFA 首发路径（DeepEP 原生为 IB） |
| 无需 proxy kernel | Proxy kernel + RDMA write on libfabric efa |

---

## 2. 维度差异表

| 维度 | NCCL-EP on EFA | UCCL-EP on EFA | 差异性 |
|---|---|---|---|
| **通信 kernel** | NCCL all-to-all collective（ring / tree / xhier），固定 tensor shape | 自定义 `dispatch` + `combine` CUDA kernel；top-k 稀疏打包；不走 NCCL | **显著不同** |
| **下层传输** | libfabric efa（NCCL-OFI plugin） | libfabric efa（UCCL 直调） | 相似（同 libfabric，不同 plugin） |
| **Token 调度模型** | 全量 a2a：每 rank 发所有 experts 的 tokens，哪怕本 rank 不需要 | 稀疏 dispatch：按 `routing` 只发给目标 EP rank；`combine` 做反向聚合 | **显著不同**（核心区别） |
| **内存路径** | NCCL registered buffer + NCCL-OFI MR | UCCL pinned + GPU-direct via libfabric efa; proxy kernel 触发 RDMA write | 相似（都是 pinned+GDR），组织不同 |
| **CPU 侧开销** | NCCL host proxy thread（`NCCL_PROXY_NET`） | UCCL host proxy + kernel launch overhead per dispatch | 类似（都有 host proxy） |
| **SGLang 接入 flag** | `--moe-a2a-backend nccl`（或 `none` 走 NCCL 默认） | `--moe-a2a-backend uccl`（**若 SGLang 已支持**）；未支持时需 patch / env 注入 | **显著不同** |
| **调优旋钮面** | `NCCL_ALGO` / `NCCL_PROTO` / `NCCL_CROSS_NIC` / `NCCL_NVLS_ENABLE` / `NCCL_BUFFSIZE` / `FI_EFA_*` | `UCCL_RDMA_QUEUE_DEPTH` / `UCCL_MAX_INFLIGHT` / `UCCL_EP_TOPK` / UCCL kernel launch params / `FI_EFA_*` | 两组旋钮**几乎不交集** |
| **正确性风险** | 成熟，生产级 | 新路径：dispatch/combine 的 top-k 稀疏路由**必须过 logits diff 闸门**（vs NCCL-EP, max-abs-diff ≤ 1e-3 @ fp16） | UCCL 高 |
| **Kernel launch 数 / step** | 1（NCCL a2a call） | 2（dispatch + combine），每次都要 cudaLaunchKernel | UCCL 多一倍 launch 开销 |
| **Overlap 机会** | 与 FFN compute overlap 受 NCCL 全量 a2a shape 限制 | 稀疏 dispatch 可以更早 overlap（见论文 §4.2） | UCCL 理论上 overlap 更好 |
| **扩展性路径** | NCCL 的 EP world size 随机器数线性增长；全量 a2a 总带宽随 N 平方 | 稀疏 dispatch 带宽随**激活 experts 数**而非机器数增长 | 不同曲线 |
| **DeepEP IB 参考线** | — | DeepEP 原生为 IB；UCCL-EP 是 DeepEP-on-EFA 的等价移植（论文 §5） | IB 数字仅**标注不对齐** |
| **故障恢复** | NCCL communicator 级 reset | UCCL agent 级 reset + proxy kernel restart | 不同 |
| **镜像大小（预估）** | 基线 Stage 4 v2 已含 | +UCCL 运行时 +~50-100 MB | UCCL 略大 |
| **FP8 / FP16 兼容性** | 由 NCCL 数据类型决定（bf16/fp16/fp8 均支持） | 由 UCCL dispatch/combine kernel 决定；论文提 bf16/fp16；FP8 需确认 | **待验证** |

---

## 3. UCCL-EP 正确性闸门（必须过，否则跳性能测试）

- 固定 seed、固定 routing、固定 token 分布
- UCCL-EP vs NCCL-EP 跑 `dispatch + combine`
- logits / activation **max-abs-diff ≤ 1e-3**（fp16 量级）
- 小规模端到端：SGLang + Mixtral-8x7B 或 Qwen3-235B 几十条请求，输出 token 一致性
- **不过就不跑性能**；上 issue 到 UCCL 团队；Lane E 性能部分回退到 NCCL-EP 兜底

详细流程见 `CORRECTNESS.md`（Day 5 产出）。

---

## 4. 不在本表范围内的东西（见其他文件）

- **性能 Δ%**（dispatch / combine 延迟 p50/p99、有效带宽、扩展性）→ `E_VS_NCCL.md`
- **每个 UCCL 参数的方向和推荐值** → `UCCL_EP_TUNING.md`
- **正确性报告** → `CORRECTNESS.md`
- **DeepEP on IB 参考数字** → `IB_REFERENCE.md`（仅标注，不对齐）

---

## 5. 可调旋钮清单（预扫维度备忘）

### NCCL-EP（EFA 通用）

| Env / Flag | 候选 |
|---|---|
| `NCCL_ALGO` | `Ring` / `Tree` / `CollnetChain` |
| `NCCL_PROTO` | `Simple` / `LL` / `LL128` |
| `NCCL_CROSS_NIC` | 1（多 NIC） |
| `NCCL_NVLS_ENABLE` | 1（H200 SM 10.0） |
| `NCCL_BUFFSIZE` | 默认 / 4× |
| `FI_EFA_USE_DEVICE_RDMA` | 1 |
| `FI_EFA_FORK_SAFE` | 1 |

### UCCL-EP（EFA，重点调）

| Env / Flag | 候选 |
|---|---|
| `UCCL_RDMA_QUEUE_DEPTH` | 默认 / 扩大 2× / 4× |
| `UCCL_MAX_INFLIGHT` | 扫 |
| `UCCL_EP_TOPK` | 8（模型决定：Kimi-K2 top-8 / DeepSeek-V3 top-8） |
| `UCCL_PROXY_PORT_BASE` | 指定可见端口范围（k8s readiness） |
| `FI_EFA_USE_DEVICE_RDMA` | 1（H200 v3 默认） |
| `FI_EFA_FORK_SAFE` | 1 |
| `FI_EFA_TX_SIZE` / `RX_SIZE` | 默认 / 2× / 4× |
| `FI_EFA_USE_HUGE_PAGE` | 0（Stage 4 遇问题） |
| `FI_MR_CACHE_MONITOR` | memhooks / userfaultfd |

### Microbench 扫描维度（同 STAGE5_PLAN §5.3）

| 维度 | 取值 |
|---|---|
| EP world size | 2 / 4 / 8 / 16 / 32 |
| Hidden dim | 4096 / 7168（Kimi-K2 / DeepSeek）/ 12288 |
| Top-k | 8 |
| Tokens per batch | 512 / 2048 / 8192 |
| NIC 绑定 | 每 GPU 单 NIC / 多 NIC striping |

---

## 6. 客户视角切换成本（**先列事实，不评价**）

**事实**：若客户要从 NCCL-EP 切到 UCCL-EP：

1. SGLang flag：`--moe-a2a-backend nccl` → `uccl`（若 SGLang 已接入，否则需 patch）
2. 镜像：需含 UCCL runtime + proxy kernel（镜像大小 +50-100 MB）
3. 调优面：从 `NCCL_*` env 组改为 `UCCL_*` + `FI_EFA_*` 组；**旋钮集几乎不交集**
4. 正确性回归：每次换模型要过 logits diff 闸门（NCCL-EP 路径视为 reference）
5. 故障观察点：communicator reset → proxy kernel restart；告警规则要重写
6. IB→EFA 迁移：DeepEP on IB 的生产经验**参数不可直接搬**（libfabric vs ibverbs，TL 语义不同）

**不做判断**：以上哪一项对客户是阻塞 / 可接受 / 无感，由客户自行评估。
