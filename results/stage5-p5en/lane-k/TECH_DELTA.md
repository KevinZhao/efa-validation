# Lane K · TECH_DELTA — NIXL vs Mooncake-EfaTransport

**范围**：纯架构 / 代码静态差异。**不含任何性能数字**（那部分在 `K_VS_MOONCAKE.md`）。
**基线版本（2026-04-25 切 v5 后）**：
- SGLang 0.5.10（hardcoded `protocol="rdma"`，launcher sed → `"efa"`）
- Mooncake upstream @`634b7097`（v0.3.10.post2 tag 之后的 post-SRD-refactor 头）+ 王鹤男 **5** EFA PRs：
  - #1509 AWS EFA transport initial（libfabric `FI_EP_RDM`）
  - #1523 TCP fallback + docs
  - #1821 fi_read + LRU eviction + multi-NIC striping + `FI_MR_HMEM`
  - #1912 PTE-aware auto-split 大 MR registration
  - **#1944 SRD shared-endpoint refactor**（4× cold submit / 15× warmup / 消除 QP 墙 / 修 VRAM preTouch segfault / 移除 per-request `MC_EFA_STRIPING_THRESHOLD`）
- 镜像：`yanxi/sglang-mooncake:v5` ← `yanxi/mooncake-nixl:v5`（详见 `common/Dockerfile.mooncake-nixl` + `results/stage5-p5en/r1a-kimi-k2-1p1d/20260425T033552Z/BUILD_V3.md`）
- NIXL v1.0.1（UCX 后端）
**不做结论**：本表只描述"哪里不一样"，不评"谁更好"。选择权归客户。

---

## 1. 一句话对比

| Mooncake-EfaTransport | NIXL (UCX backend) |
|---|---|
| 直接走 libfabric efa provider（专为 EFA SRD 设计） | 走 UCX，底层可选 libfabric-efa / rc-verbs / cuda_copy TL 组合 |
| Mooncake 生态的 KV transport（原生配 Mooncake master service） | 通用 xfer library，被 vLLM / Dynamo / SGLang 三栈共用 |
| SGLang 通过 `mooncake_transfer_engine.py` bind | SGLang 通过 `nixl_transfer_engine.py` bind |

---

## 2. 维度差异表

| 维度 | Mooncake-EfaTransport (@`634b7097` + Henan 5 PRs) | NIXL v1.0.1 (UCX backend) | 差异性 |
|---|---|---|---|
| **Transport 层** | libfabric efa provider 直调（SRD `FI_EP_RDM`）；`FI_PROVIDER=efa`，`FI_EFA_USE_DEVICE_RDMA=1` | UCX → TL（`UCX_TLS=rc,cuda_copy` / `ib,cuda_copy` / `rdma,cuda_copy`）；底层 `libfabric-efa` + `cuda_copy` 二选多 | **显著不同** |
| **Endpoint 模型** | **#1944 起共享 `fid_ep`**：每本地 NIC 1 个 EP，所有 peer 通过 `fi_addr_t` AV index 寻址；消除旧版 per-(local NIC × peer) QP 墙（16 NIC × 48 peer = 768 QP） | `ucp_ep` per peer；`UCX_NUM_EPS` / 背后 TL QP 控制并发 | **显著不同** |
| **多 NIC striping** | **register-time**：#1912 PTE-aware auto-split 把大 buffer 切成 chunks、**所有 NIC 全覆盖**（pte 预算允许时）；**run-time**：**#1944 已移除** per-request `MC_EFA_STRIPING_THRESHOLD`（p5en 实测 >2 MB 时 20× 负优化） | `UCX_MAX_RNDV_RAILS={1,4,8,16}` 控制 rendezvous rail 数；无 register-time NIC 覆盖概念 | **相似（register-time），run-time 取向不同** |
| **内存注册路径** | 显式 pinned + Mooncake 内部 MR cache；#1912 按 /proc/self/smaps 检测页大小做 PTE-aware auto-split（4 KB pages → 88 GB/NIC, 2 MB hugepages → 44 TB/NIC） | UCX managed + memhooks / userfaultfd；`UCX_MEMTYPE_CACHE={n,y}` | 相似（概念），配置面显著不同 |
| **元信息 / 协调 (library path)** | **Mooncake master service**（外置进程），endpoint registry + chunk meta 广播；`MC_MS_AUTO_DISC=1` 自动发现 | NIXL Agent C++ library 支持 peer 直连 handshake（无外置 service，Dynamo 接入场景用此路径） | **显著不同** |
| **元信息 / 协调 (bench tools)** | `transfer_engine_bench` 需外置 `--metadata_server=etcd://IP:2379`（可用 http/etcd/Mooncake master 三种 backend） | `nixlbench` (v1.0.1) network backends (LIBFABRIC/UCX/Mooncake) **强依赖 etcd**；storage backends (GDS/POSIX) 可选。Lane K 实测 **必须起一个 etcd pod** | 两边 bench 工具都吃 etcd — 可共用一个 etcd |
| **依赖组件** | libfabric (≥ 1.22) + Mooncake store + Mooncake master + `efa_nv_peermem`（GPU Direct 必需） | UCX (≥ 1.18) + NIXL plugin + EFA kernel driver；不需要 master service | **显著不同** |
| **SGLang 接入 flag** | `--disaggregation-transfer-backend mooncake` | `--disaggregation-transfer-backend nixl` | 相同（只是 enum 取值） |
| **SGLang 源码入口** | `sglang/srt/distributed/device_communicators/mooncake_transfer_engine.py` | `sglang/srt/distributed/device_communicators/nixl_transfer_engine.py` | 同架构不同文件 |
| **Protocol hardcode** | SGLang 0.5.10 写死 `"rdma"`，EFA 下必须 sed → `"efa"`（launcher 已补丁） | 无 hardcode 问题 | Mooncake 独有坑 |
| **日志关键字** | `[EFA] AWS Elastic Fabric Adapter transport initialized` / `SRD shared endpoint` / `Auto-split params` / `Chunk N/M registered on K NICs` / `warmupSegment` / `Topology discovery` / `MasterService:` | UCX `UCX_LOG_LEVEL=info/debug` → `ucp_ep`、`ucp_tag` 事件；NIXL：`NIXL agent`、`rendezvous` | 完全不同 key 集合 |
| **metrics / counters 出口** | Mooncake store Prometheus endpoint（若开）+ EfaTransport stdout 定时打 | UCX 计数器需 `ucx_perftest` 或 `UCX_STATS_TRIGGER` 导出；NIXL agent 自带 counters | 不同 |
| **冷启动 (first submit)** | **#1944 后**：cold submit #0 = **26 ms**（9.4× 相对旧版 99 ms）；可选 `warmup_efa_segment()` 把 first submit 拍到 ms 级，warmup 本身 ~1.1 s（pre-#1944 17 s 且抖动 9/17/17） | prefill/decode 直接起 → peer handshake → ready；无 master | Mooncake 多一个 master 跳但 submit 更快 |
| **失败恢复语义** | Mooncake: transfer retry + RPC reconnect；master 重启后 endpoint 全重建；**#1944 修 teardown `fi_av_remove` 段错误** | UCX: endpoint 级重建；NIXL agent 级 reconnect；不涉及外部 master | **显著不同** |
| **GPUDirect 开关** | `FI_EFA_USE_DEVICE_RDMA=1`（launcher 已固定）；**#1944 修 `preTouchMemory` 对 VRAM 段错误**（pre-touch 仅在 host mem 路径跑） | `UCX_IB_GPU_DIRECT_RDMA=y` / `n` | 相似但 scope 不同 |
| **kv chunk 分段** | register-time PTE-aware auto-split（#1912）；run-time 不再按请求切 | `UCX_RNDV_THRESH={256KB, 1MB, 4MB}` 控制 rendezvous 触发 | Mooncake 自动，NIXL 需调 |
| **CUDA stream 并发** | Mooncake 每 transfer 一 stream（内部 stream pool） | UCX 由 `UCX_NUM_EPS` × mem-type 决定 | 不同模型 |
| **镜像大小（vs Stage 4 v2 基线）** | `mooncake-nixl:v5` 约 14 GB（同时含 Mooncake + NIXL + UCX 1.18） | 本表比较的是两个 backend，同镜像 | 同镜像 |
| **可观测组件总数** | SGLang × 2 pods + Mooncake master × 1（共 3 类） | SGLang × 2 pods（共 1 类） | NIXL 少一个外挂 |

---

## 3. 不在本表范围内的东西（见其他文件）

- **性能 Δ%**（Gbps、RTT、TTFT/TPOT、OTPS）→ `K_VS_MOONCAKE.md`（Day 2-3 跑完产出）
- **每个参数的方向和推荐值** → `NIXL_TUNING.md`（microbench 后产出）
- **切换时客户会看到的外部变化** → `SWITCH_OBSERVABLES.md`（Day 3 产出，含故障注入观察）

---

## 4. 静态差异背后的**可调旋钮清单**（预扫维度备忘）

### Mooncake

| Env / Flag | 候选 |
|---|---|
| `MC_MS_AUTO_DISC` | 1（必须） |
| `MC_TRANSFER_SUBMIT_THREADS` | 4 / 8 / 16 |
| `MC_LEGACY_RPC_PORT_BINDING` | 1（Henan PR 要求） |
| `MOONCAKE_PROTOCOL` | 必须 `efa`（sed 补丁） |
| `FI_PROVIDER` | `efa` |
| `FI_EFA_USE_DEVICE_RDMA` | `1` |
| `FI_EFA_FORK_SAFE` | `1` |
| `FI_MR_HMEM` | `1` (**必须**，#1821/#1944 要求，用于 GPU 内存注册；不设会触发 VRAM preTouch path 退化) |
| `MC_EFA_STRIPING_THRESHOLD` | **已废弃**（#1944 移除）；若 env 仍设置会被忽略 |
| `MC_EFA_MAX_PTE_ENTRIES` | 默认 22M；超大 KV pool 才扫 |
| `warmup_efa_segment()` | Python 绑定（#1944 新增）；可选 pre-connect，first submit 从 26 ms 进一步压到 ms 级 |

### NIXL (UCX backend)

| Env / Flag | 候选 |
|---|---|
| Backend | `UCX` / `UCX_MO` |
| `UCX_TLS` | `rc,cuda_copy` / `ib,cuda_copy` / `rc,rdma,cuda_copy` |
| `UCX_NET_DEVICES` | `rdmap*s0` 全 16 / 8 / 4 |
| `UCX_MAX_RNDV_RAILS` | 1 / 4 / 8 / 16 |
| `UCX_RNDV_THRESH` | 256 KB / 1 MB / 4 MB |
| `UCX_IB_GPU_DIRECT_RDMA` | y / n |
| `UCX_MEMTYPE_CACHE` | n / y |
| `UCX_NUM_EPS` | 默认 / 扩大 2× |
| `NIXL_BACKEND` | `UCX` / `UCX_MO` / **`LIBFABRIC`**（v1.0.1 EFA-native，直调 libfabric 绕过 UCX；Lane K 主路径） |

参数调优清单的"方向 + 推荐值"在 `NIXL_TUNING.md`，microbench 数据支撑。

### 关于 Lane K microbench 工具的 backend 选择（2026-04-26 补记）

NIXL v1.0.1 有 `LIBFABRIC` 和 `UCX` 两个 backend 可扫 EFA：

- **`--backend LIBFABRIC`**：NIXL → libfabric (`/opt/amazon/efa`) → EFA provider（SRD）；**跳过 UCX 层**。是 NIXL v1.0.1 新增的 EFA-native 主路径；我们 Lane K 扫描把它作为"主横评对象"，对标 Mooncake `EfaTransport`（两边都直调 libfabric-efa，层级对称）。
- **`--backend UCX`**：NIXL → UCX 1.18.0 → verbs/rdmacm →（`rc,cuda_copy`）→ libfabric/efa；**多一跳**。作为 fallback 参考，只在 rails=16 msg=4M 点扫一组做敏感性。

**结论**（作为 static fact 入表）：Mooncake 无 UCX 路径；NIXL 有 UCX 路径但我们主扫 LIBFABRIC 路径以保持对照公平。

---

## 6. Lane K microbench 执行规范（**2026-04-26 新增，实操细节**）

### 6.1 背靠背采样协议

按计划 §4.3 硬约束"NIXL run 紧接 Mooncake 对照，间隔 ≤ 5 min, 不借用历史数据"：

- 驱动方：**bastion 上一个 orchestrator shell 脚本**（`scripts/lane-k/orchestrate-sweep.sh`），对每个参数点顺序做两次 `kubectl exec`：先 NIXL（target + initiator 各一个 exec），后 Mooncake（同样两端 exec），间隔 5 s cooldown。
- 每个 pod 长期 sleep，bench 二进制每次现场拉起、跑完退出；target 侧后台起进程，initiator 侧前台拿 stdout。
- 扫描顺序：`(nic, rails) → msg → conc` 嵌套；每对外层固定后，内层 msg×conc 连续扫（避免相邻噪声）。

### 6.2 扫描维度裁剪

原 §4.3 维度 14,400 组 → Lane K 实际执行 **60 对（NIXL + Mooncake = 120 次 bench 调用）**：

| 维度 | 计划值 | 裁剪后 |
|---|---|---|
| Transfer backend | UCX / UCX_MO | **LIBFABRIC**（1 个，EFA-native） |
| UCX_TLS | 3 种 | **`rc,cuda_copy`**（EFA 下所有 TLS 最终收敛到 libfabric/efa） |
| GPU Direct RDMA | y/n | **y**（p5en 生产默认） |
| Memory reg | 3 种 | **pinned**（生产默认） |
| CUDA stream | 2 种 | **per-transfer** |
| UCX_MEMTYPE_CACHE | 2 种 | **n**（Stage 5 ref） |
| Operation | read/write | **write**（NIXL vs Mooncake 对称） |
| NIC × Rendezvous rails | 3 × 4 | **coupled: 16×16, 8×8, 4×4**（3 对） |
| Message size | 5 档 | **5 档保留** (64K/256K/1M/4M/16M) |
| Concurrency | 4 档 | **4 档保留** (1/4/16/64) |

= 1 × 1 × 3 × 5 × 4 = **60 对背靠背 = 120 次 bench 调用**
每次 10 s warmup + 30 s measure + 5 s cooldown = 45 s；合计 **~90 min wall clock**。

### 6.3 统一 CSV 格式

两工具 stdout 解析到同一 schema：

```
run_id,tool,backend,nic_count,rails,msg_size,concurrency,operation,gbps_mean,rtt_us_p50,rtt_us_p99,samples,started_at,duration_s,notes
```

同一参数点 NIXL 和 Mooncake 共用 `run_id`（如 `p001-n16r16m1048576c16`）；`K_VS_MOONCAKE.md` 只对同 `run_id` 求 Δ%。

### 6.4 "次优点"定义（K-E1' 判据）

`NIXL_TUNING.md` 里选 Top-2 参数点用 **复合分** = `gbps_mean * (1000 / max(rtt_us_p50, 1))`，而不是单独 Gbps 或单独 RTT（防止低吞吐极低延迟或高吞吐重拖尾的畸点被当次优）。

### 6.5 Bench pod 配置要点

参考 `manifests/lane-k/lane-k-bench-pods.yaml`：

- `hostNetwork: true` + `hostIPC: true`：微基准需裸 wire latency / Gbps，overlay 网络会引入 10-50 us 噪声
- EFA device: `vpc.amazonaws.com/efa: 16`（p5en 全 NIC）+ `IPC_LOCK` + hugepages `5120Mi`
- podAntiAffinity 保证 target+initiator 分布到 2 台不同 p5en 主机
- `/dev/shm: 64Gi`（memory-backed）+ `/out: 10Gi`（emptyDir 保结果 CSV）
- 镜像：`yanxi/mooncake-nixl:v5`（Mooncake `634b7097` + NIXL `v1.0.1` + UCX `v1.18.0` + libfabric via `/opt/amazon/efa`）

---

## 5. 客户视角切换成本（**先列事实，不评价**）

**事实**：若客户要从 `SGLang + Mooncake` 切到 `SGLang + NIXL`：

1. launcher flag：`--disaggregation-transfer-backend mooncake` → `nixl`（一字改）
2. 镜像：需含 UCX 1.17+ 和 NIXL plugin（镜像大小 +150-300 MB，具体见 Day 2 build 产物）
3. 外部组件：**Mooncake master service 不再需要**（可从 pod list / service registry 移除）
4. 日志 grep：key 集合全换；现有告警规则 `grep EfaTransport` 失效
5. metric scraping：Prometheus 抓取端点不同；现有 dashboard 需重画
6. 故障语义：失败点从"master RPC reconnect"改为"UCX endpoint 重建"
7. SGLang 0.5.10 的 `rdma→efa` sed 补丁：**不再需要**（NIXL 路径不受此 hardcode 影响）

**不做判断**：以上哪一项在客户生产栈里是阻塞 / 可接受 / 无感，由客户自行评估。
