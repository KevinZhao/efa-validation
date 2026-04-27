# Mooncake 软件全景与架构

**日期**：2026-04-25
**来源**：upstream `kvcache-ai/Mooncake` HEAD + README + `docs/source/design/`
**定位**：Moonshot AI 为 Kimi 生产环境开源的 **"KVCache-centric disaggregated LLM serving"** 平台；现已加入 PyTorch Ecosystem

---

## 1. Mooncake 提供什么功能（一句话）

> **把"LLM 推理的 KV cache"做成一个跨节点/跨介质（DRAM / VRAM / NVMe / SSD）共享的分布式资源池，让 prefill 和 decode 可以在不同机器上分别跑，中间的 KV 搬运靠一个高性能 transport engine（RDMA / EFA / NVLink / TCP / CXL / NVMe-of）零拷贝跨机送过去。**

它不是单个库，而是一套**分层堆栈**：
1. **底层：数据搬运** —— 跨介质高速搬 tensor 的通用 runtime
2. **中层：对象存储** —— 基于搬运层做 KV / checkpoint 的 put/get 分布式 store
3. **上层：推理集成** —— 嵌入 vLLM / SGLang / TRT-LLM / LMCache 等推理框架，做 PD 分离、HiCache、EPD 分离

---

## 2. 总体架构

```
┌─────────────────────────────────────────────────────────────────────────┐
│  LLM 推理框架层（各自集成 Mooncake）                                     │
│  vLLM Disagg Prefill │ SGLang HiCache │ TRT-LLM │ LMCache │ LMDeploy    │
│  vLLM-Omni / EPD     │ Checkpoint-Engine (Kimi-K2 1T 20s) │ xLLM        │
└───────────┬─────────────────────────────────┬───────────────────────────┘
            │                                 │
┌───────────▼──────────┐         ┌────────────▼────────────┐
│  Mooncake Store      │         │  Mooncake P2P Store     │
│  (distributed KV)    │         │  (checkpoint / tensor)  │
│  Master + Client     │         │  全客户端架构，etcd 元  │
│  Put/Get/Remove 语义 │         │  Register/GetReplica    │
└───────────┬──────────┘         └────────────┬────────────┘
            │                                 │
┌───────────▼─────────────────────────────────▼───────────────────────────┐
│  Mooncake Transfer Engine (TE) —— 最底层，其他都依赖它                   │
│                                                                          │
│  统一抽象：Segment (RAM / NVMe-of) + BatchTransfer (Read/Write)          │
│  Topology-aware Path Selection + Multi-NIC 带宽聚合 + 故障转移           │
│                                                                          │
│  Transport 插件（按 proto 名运行时选）：                                 │
│    TcpTransport  RdmaTransport  EfaTransport  NvlinkTransport            │
│    IntraNodeNvlinkTransport  CxlTransport  NVMeoFTransport               │
│    HipTransport  AscendTransport  KunpengUbTransport  BarexTransport    │
│                                                                          │
│  元数据服务（外置，TE 只是 client）：etcd / Redis / HTTP                 │
└─────────────────────────────────────────────────────────────────────────┘
            │
            ├── Mooncake EP   —— DeepEP 兼容的 MoE all-to-all kernel（IBGDA）
            ├── Mooncake PG   —— PyTorch ProcessGroup backend（替 NCCL）
            ├── TENT          —— "Transfer Engine NEXT" 下一代动态多 rail 调度
            └── Mooncake RL   —— Reinforcement-learning / checkpoint 样例
```

---

## 3. 仓库物理结构（HEAD 当前目录）

| 目录 | 角色 | 说明 |
|---|---|---|
| `mooncake-transfer-engine/` | **核心**（C++）| Transfer Engine，所有 transport 插件都在 `src/transport/<xxx>_transport/` |
| `mooncake-store/` | 分布式 KV store（C++ master + client + Go bindings）| `master_service.cpp` 协调；`real_client.cpp` / `dummy_client.cpp` 两种 client |
| `mooncake-p2p-store/` | P2P 对象共享（Go）| BT-seeding 式，Register/GetReplica，Kimi checkpoint 分发用 |
| `mooncake-ep/` | MoE all-to-all kernel（CUDA）| DeepEP 兼容 API，用 IBGDA 做 dispatch/combine |
| `mooncake-pg/` | PyTorch Process-Group backend（CUDA + C++）| `MooncakeBackend : c10d::Backend`，在训练/推理里当 NCCL 替代品 |
| `mooncake-rl/` | RL 样例（Python）| 训练/推理 decouple via Mooncake（TorchSpec / ROLL 合作） |
| `mooncake-integration/` | Python/pybind 薄层 | `transfer_engine/*.cpp` 和 `store/*.cpp` 导给 Python |
| `mooncake-wheel/` | PyPI 打包 | `pip install mooncake-transfer-engine{,-cuda13,-non-cuda}` |
| `mooncake-transfer-engine/tent/` | TENT 下一代 runtime | 动态 backend 选择 + telemetry-driven 调度 |
| `mooncake-common/` | 共享 cmake / utils | |
| `FAST25-release/traces` | FAST'25 论文 traces | Best Paper 奖 |

---

## 4. 核心抽象（读 `transfer_engine.h` 出来的）

### 4.1 `TransferEngine`（顶层 API）

```cpp
class TransferEngine {
    int init(metadata_conn_string, local_server_name, ip, port);
    Transport* installTransport(proto, args);    // 按名装载 transport 插件
    SegmentHandle openSegment(segment_name);     // 拿到远端 segment 引用
    int registerLocalMemory(addr, len, location, remote_accessible, ...);
    Status submitTransfer(batch_id, entries);    // 提交批量 READ/WRITE
    Status getTransferStatus(batch_id, status);  // 异步查询完成情况
};
```

### 4.2 两个核心概念

- **Segment**：一段可被远端寻址的连续/非连续虚拟内存（DRAM/VRAM）或持久 NVMe-of 区；每进程自动有一个以 `local_server_name` 为名的 segment
- **BatchTransfer**：一次性提交一组 READ/WRITE 请求，每条给 `(source, target_id, target_offset, length, opcode)`；底层自动切 slice（>64KB 分块）到多 NIC

### 4.3 Transport 插件接口（以 EFA 为例）

`Transport` 是纯虚基类：
- `install(local_server_name, metadata, topology)`
- `registerLocalMemory` / `unregisterLocalMemory`
- `submitTransferTask(task_list)` —— 最热路径
- `getTransferStatus(batch_id, status)`

每个 proto 一个子目录 + 一个子类实现（`EfaTransport`、`RdmaTransport`、`TcpTransport`...）。运行时通过 `installTransport("efa", args)` 装。

---

## 5. 五大价值点（区别于 NCCL / Gloo / Redis 等）

| 维度 | Mooncake | 常见替代 |
|---|---|---|
| **多介质抽象** | DRAM / VRAM / NVMe / CXL / Ascend 统一 Segment | NCCL 只 GPU，Redis 只 DRAM |
| **多 NIC 带宽聚合** | 单次 >64KB 切 slice 分发到多张 RDMA/EFA NIC | NCCL 每 job 一张，不聚合 |
| **Topology-aware 路径选择** | 按 NUMA / PCIe switch / GPU 归属选最优 NIC | 基本靠用户配置 |
| **容错 / retry** | NIC 失败自动换路；endpoint 池化 + SIEVE 淘汰 | NCCL 失败整 comm 崩 |
| **Disagg-native** | 设计时就是 PD 分离 / HiCache / xPyD | 都是事后改的 |

---

## 6. 主要产品形态

### 6.1 Transfer Engine（最常单独使用的）
- `pip install mooncake-transfer-engine` 即可
- 提供 C++ / Python / Rust / Go 绑定
- 独立可用：有 `transfer_engine_bench` 做 benchmark
- 已集成到：**vLLM v1（KV Connector）**、**SGLang disagg prefill**、**TensorRT-LLM KV transmission**、**NIXL（作为 backend plugin）**、**vLLM-Ascend**、**LMDeploy**

### 6.2 Mooncake Store（分布式 KV）
- Master Service（有 HA 模式，etcd 选主）+ Client（可嵌入或独立服务）
- 多副本、强一致（put 之后 immutable 直到 remove）
- 支持 SSD offload（多层存储）
- 用户：**SGLang HiCache（L3 backend）**、**vLLM-Ascend KV Pool**、**LMCache remote connector**、**FlexKV**、**xLLM**

### 6.3 P2P Store（checkpoint 分发）
- 纯 client 架构 + etcd 元数据
- BT-style 种子：`Register` 只发元数据，`GetReplica` 从任意持有者拉
- 开源高性能版叫 [**checkpoint-engine**](https://github.com/MoonshotAI/checkpoint-engine) —— Kimi-K2 1T 参数 20s 内在千卡上更新

### 6.4 Mooncake EP（MoE all-to-all）
- DeepEP 兼容 API（dispatch / combine）
- 用 IBGDA（InfiniBand GPU Direct Async）做 a2a
- 集成进 SGLang 的 elastic expert parallel（PR [sglang#11657](https://github.com/sgl-project/sglang/pull/11657)）

### 6.5 Mooncake PG（PyTorch backend）
- 实现 `c10d::Backend`，可以 `torch.distributed.init_process_group(backend="mooncake", ...)`
- 目的：训练 / 推理场景下当 NCCL 的容错替代（elastic expert parallelism 的 backbone）

### 6.6 TENT（下一代）
- Transfer Engine NEXT，和 TE 并存但定位不同：**把 transport 选择从"静态绑定"变成"运行时动态选"**
- 核心能力：dynamic transport selection、fine-grained scheduling with telemetry、in-runtime failure handling
- 给 heterogeneous / dynamic topology 准备（比如一个集群里 NVLink + RDMA + host-memory 混合）
- 还不稳定，当前生产主要靠 TE

---

## 7. 我们关心的 EFA 路径在全景图中的位置

```
SGLang 0.5.10 (PD disagg mode)
    │
    │ mooncake_protocol: "efa"
    ▼
Mooncake Python bindings  (mooncake-integration/transfer_engine/*.cpp)
    │
    ▼
TransferEngine::submitTransfer(batch_id, entries)
    │
    ▼
EfaTransport::submitTransferTask(task_list)   ← #1944 新增的共享 fid_ep 路径
    │
    │  per-NIC fid_ep (shared)、peer 用 fi_addr_t AV 索引
    │  每 slice 切到对应 NIC，多 NIC 并发 fi_write
    ▼
libfabric EFA provider → AWS EFA NIC → 对端 p5en / p6-b200
```

**我们在 Stage 5 实际碰到的 Mooncake 组件**：
- `mooncake-transfer-engine`（**直接使用**）
- `mooncake-integration/transfer_engine/*.cpp`（Python bindings + 给 SGLang 的 launcher）
- `mooncake-store` / `mooncake-ep` / `mooncake-pg` / `mooncake-p2p-store` —— 当前 Stage 5 **不触达**

**没触达但值得了解**：
- **Mooncake Store**：如果之后做"跨机跨 P/D 共享 KV 池"就会上；现在 SGLang 的 HiCache 已经支持
- **Mooncake PG**：elastic EP 想做 fault-tolerant 训练推理时会上
- **TENT**：如果 EFA + NVLink 混合（p5en intra-node NVLink + inter-node EFA）想 unified path selection 时会上

---

## 8. 元数据服务依赖（容易踩坑）

`TransferEngine::init(metadata_conn_string, ...)` 需要一个**外置**元数据服务（etcd / Redis / HTTP），这是拓扑 / segment 注册信息的全局真相源：

| 选项 | 用途 |
|---|---|
| `etcd://host:2379` | 默认，Mooncake Store HA 模式**必需** etcd |
| `redis://host:6379` | 轻量 |
| `http://host:8080` | 示例 go 服务在 `mooncake-transfer-engine/example/http-metadata-server/` |

**我们的 Stage 5 里**：launcher 拉了 HTTP metadata server（Ohio 跳板 + EKS pod 内）。

---

## 9. 性能基线（upstream 文档声明）

| 场景 | 配置 | 带宽 |
|---|---|---|
| TE on RoCE 4×200 Gbps | 40GB KV（= LLaMA3-70B @ 128k tokens）| **87 GB/s** |
| TE on RoCE 8×400 Gbps | 同上 | **190 GB/s** |
| 对比 TCP | | 2.4–4.6× 加速 |
| **我们 Stage 5 实测** | p5en 16×200 Gbps EFA + #1944 | **Write 365 GB/s / Read 304 GB/s**（91% 线速）|
| Mooncake PD Kimi-K2 | 128 H200 SGLang | **224k tok/s prefill / 288k tok/s decode**（LMSys blog 2025-07-20）|

**vLLM PD-disagg 对照**：TTFT 降低 25%（Mean 1057ms vs 1414ms，P99 4007ms vs 6035ms）。

---

## 10. 总结：Mooncake 在做的事

Mooncake 实质上回答了一个问题：**在 LLM serving 里，KV cache 是头等资源，它既不适合留在单机 GPU，也不适合扔进通用存储——怎么办？**

它的回答是：
1. **把网络搬运做好**（Transfer Engine，类似 NCCL 但 multi-proto / multi-NIC / topology-aware / 容错）
2. **把 KV 当成分布式对象**（Mooncake Store，类似 Redis 但 RDMA zero-copy、多副本、SSD offload）
3. **把调度模型改成 PD-disagg**（prefill / decode 分集群，KV 走 Transfer Engine 跨机）
4. **做成 ecosystem**，让 vLLM/SGLang/TRT-LLM 等都能接入

EFA transport 只是 **Transfer Engine** 这一层的一个 backend plugin，在完整产品家族里只是 `mooncake-transfer-engine/src/transport/efa_transport/` 一个子目录 ~2500 行代码。
