# Lane K microbench — 2026-04-26 首次尝试日志（未出数据，但路径清）

**状态**：**BLOCKED** at GPU device injection into bench pods.
**GPU 成本**：2 × p5en ≈ 1 h on Spot（10:20–11:20 UTC）= 2 node-hours

## 本次尝试的目的

在 2 × p5en（Ohio use2-az2，同 AZ）上跑 NIXL vs Mooncake EFA microbench 背靠背对照，按 §4.3 规划产出 `K_VS_MOONCAKE.md`。

## 执行路径

1. ✅ `gpu-p5en-spot-useast2b` scale 0→2，2 台 p5en 1 min 内 Running
2. ✅ 2 节点 k8s Ready（使用 v2 LT）
3. ✅ 镜像 `yanxi/mooncake-nixl:v5` pull 成功（含 Mooncake 634b7097 + NIXL v1.0.1 + UCX 1.18）
4. ✅ `lane-k-target` + `lane-k-initiator` pods 双 1/1 Running，hostNetwork + EFA 16 NIC
5. ❌ **Preflight 发现 `nixlbench` binary 不在镜像里** — 只 `/opt/nixl/bin/nixl_example`
6. ⚠️ Pivot 到 Mooncake-only sweep
7. ❌ **metadata plugin 问题**：`USE_ETCD=OFF, USE_REDIS=OFF, USE_HTTP=ON`；`etcd://` 报 "plugin not found"；`http://` 可用但 mooncake 期望 mooncake-specific HTTP API，不是 etcd/plain HTTP
8. ✅ 切到 `--metadata_server=P2PHANDSHAKE` 零外部依赖模式（从 `efa_per_transfer_latency_bench.py` 找到提示）
9. ❌ **GPU 设备 `/dev/nvidia*` 没注入到 pod** — 即使 `NVIDIA_DISABLE_REQUIRE=1` + `NVIDIA_VISIBLE_DEVICES=all` + `NVIDIA_DRIVER_CAPABILITIES=compute,utility` + Pod GPU request = 8
10. ❌ **`transfer_engine_bench` 调 `cudaPointerGetAttributes`** 即使 `--use_vram=false`，无 GPU device → abort (`malloc(): unsorted double linked list corrupted`)

## 重要 fact 记录（无形沉淀）

### A. NIXL v1.0.1 在 v5 image 里的实际覆盖

```
/opt/nixl-src/benchmark/nixlbench/    # 源码存在，meson build 没 build 它
/opt/nixl/bin/nixl_example            # 这是 C++ API demo，不是 bench tool
/opt/nixl/bin/telemetry_reader
/opt/nixl/lib/x86_64-linux-gnu/plugins/
  ├── libplugin_LIBFABRIC.so
  ├── libplugin_UCX.so
  └── libtelemetry_exporter_prometheus.so
/opt/nixl/lib/python3/dist-packages/  # 含 nixl_cu12 module，但 init 有 CUDA 依赖
```

**要跑 NIXL microbench 必须重 build image**：在 Dockerfile 里加一段 `cd /opt/nixl-src/benchmark/nixlbench && meson setup build && ninja -C build install`，也需要装 `etcd-cpp-api` 依赖。预计 +50 MB 镜像 + 5 min build。

### B. Mooncake `transfer_engine_bench` 实际 CLI (634b7097)

```bash
transfer_engine_bench --help
# GFLAGS-style, parses both `-foo` and `--foo`
```

| flag | type | default | 备注 |
|---|---|---|---|
| `--mode` | string | initiator | `initiator` 或 `target` |
| `--metadata_server` | string | 192.168.3.77:2379 | 选 `etcd://` / `redis://` / `http://` / `P2PHANDSHAKE`（zero-dep） |
| `--protocol` | string | rdma | `rdma/barex/tcp/efa/nvlink/nvlink_intra/hip` |
| `--operation` | string | read | `read/write` |
| `--block_size` | uint64 | 65536 | bytes |
| `--batch_size` | int32 | 128 | |
| `--threads` | int32 | 12 | |
| `--duration` | int32 | 10 | seconds |
| `--gpu_id` | int32 | 0 | -1 for all GPU (VRAM bench) |
| `--use_vram` | bool | true | **注意：即使 false，bench 仍 call cudaPointerGetAttributes** |
| `--buffer_size` | uint64 | 1 GB | auto-adjusted if too small |
| `--local_server_name` | string | hostname | advertised ID；实际 listen port 由 `MC_HANDSHAKE_PORT` env 决定 |
| `--segment_id` | string | — | target 的 advertised IP:port |
| `--auto_discovery` | bool | false | NIC 自动发现 |
| `--nic_priority_matrix` | string | — | Advanced: 手动 NIC topology |
| `--report_unit` | string | GB | GB/GiB/Gb/MB/... |

**关键环境变量**：
- `MC_HANDSHAKE_PORT=13001` — 强制 SocketHandShakePlugin listen 到此端口（否则动态分配，对端无法连接）
- `FI_MR_HMEM=1` — 启用 GPU 内存注册（Henan #1821/#1944 要求）
- `MC_WORKERS_PER_CTX=2` / `MC_NUM_CQ_PER_CTX=2` — CPU 饥荒缓解
- `FI_PROVIDER=efa` + `FI_EFA_USE_DEVICE_RDMA=1` + `FI_EFA_FORK_SAFE=1`

### C. P2P handshake 模式

`--metadata_server=P2PHANDSHAKE`（无 scheme prefix）= zero-external-dependency 模式。RPC/handshake 走直接 TCP：
- Target listens on `MC_HANDSHAKE_PORT` (default dynamic, 应设 `MC_HANDSHAKE_PORT=13001`)
- Initiator 主动连 `--segment_id=TARGET_IP:PORT`
- 两端交换 segment descriptors，后续 EFA rdma write/read 直接用 `fi_addr_t`

### D. EFA 16 NIC 列表（p5en on Ohio use2-az2）

```
rdmap85s0, rdmap86s0, rdmap87s0, rdmap88s0,
rdmap110s0, rdmap111s0, rdmap112s0, rdmap113s0,
rdmap135s0, rdmap136s0, rdmap137s0, rdmap138s0,
rdmap160s0, rdmap161s0, rdmap162s0, rdmap163s0
```

**非连续命名**（p5en PCI 布局）。我们之前的 `build_devs` 函数假设 `rdmap0s0..rdmapNs0` 是错误的；需要用 `fi_info -p efa` 动态枚举 或 直接让 auto-discovery 处理。

Fabric 类型：`efa-direct` provider=efa version=204.0 — NIXL v1.0.1 的 #901 PR 改动涉及 `efa-direct` vs `efa` fabric，**非 GDR instance 可能走 efa fabric fallback**。

### E. GPU device injection 问题 — 根因与修复路径

**观察**：
- host node driver 580.126.09 (CUDA 13)
- image `NVIDIA_REQUIRE_CUDA=cuda>=13.0 brand=...driver<576...`（旧 whitelist）
- host GPU operator + nvidia-container-toolkit-daemonset 两节点都 Running
- pod 声明 `nvidia.com/gpu: 8` + `nvidia-container-runtime` 应注入 `/dev/nvidia*`
- 实际 pod 内无 `/dev/nvidia*`，但 `nvidia-smi` 偶尔能跑（CLI injection partial）

**推测根因**：**nvidia-container-toolkit 版本与 driver 580 不兼容**，或 nvidia device plugin 在 pod 启动时没正确调 NVML。设 `NVIDIA_DISABLE_REQUIRE=1` 可以绕过 require_cuda 检查，但 **不影响实际 device file 创建**（那是 container-cli prestart hook 做的）。

**修复路径选择**（以可行性排序）：

1. **绕过 CUDA path（推荐）**：给 `transfer_engine_bench` 打个小补丁，`--use_vram=false` 路径下跳过 `cudaPointerGetAttributes`。修 1 行源码 + 重新编译 Mooncake，20-30 min，产出新镜像 tag `mooncake-nixl:v5-nocuda` 或 `v5.1`。
2. **升级 nvidia-container-toolkit**：cluster 层面修复，影响其他 run，改动面大。
3. **host-level bench**：通过 SSM 在 p5en host 上 `docker run` 镜像（host 的 containerd 有 nvidia-container-runtime），需要开 SSH/SSM 访问 + 手写 host-level orchestration。脱离 k8s 轨道。

### F. 时间投入 vs 产出

- 起 NG + apply pods：15 min ✅
- Preflight + CLI 检视：10 min ✅
- metadata plugin 调试（etcd/http/p2p）：25 min ⚠️
- GPU device 问题：30+ min ❌ 最终没 workaround
- 总 2 node × 1 h Spot：**无 microbench 数据输出**

## 下次 Lane K 启动前必须做的 3 件事

1. **镜像修复**：
   - 加 `NVIDIA_DISABLE_REQUIRE=1` 到 Dockerfile ENV
   - 加 `cd /opt/nixl-src/benchmark/nixlbench && meson setup build && ninja -C build install` 构建 nixlbench 二进制
   - 考虑给 Mooncake `transfer_engine_bench.cpp` 加 `--skip_cuda_check` flag 或 `USE_VRAM=OFF` 下 skip `cudaPointerGetAttributes`

2. **Preflight 流程**：在 apply bench pods 后先做 `ls /dev/nvidia* && transfer_engine_bench --mode=target --protocol=tcp --duration=1 --metadata_server=P2PHANDSHAKE` 冒烟，验证 GPU device + bench startup **再**开始 sweep

3. **metadata 就绪清单**：确认用 `P2PHANDSHAKE`（推荐）或 build mooncake with `USE_ETCD=ON` + 单独 etcd Deployment

## 已落地制品（保留复用）

| 文件 | 价值 |
|---|---|
| `manifests/lane-k/lane-k-bench-pods.yaml` | 2 pod 模板（hostNetwork + EFA + podAntiAffinity + NVIDIA_* env）|
| `manifests/lane-k/mooncake-http-metadata.yaml` | HTTP metadata server（本次发现其非 etcd-等价，但保留供未来 mooncake store 路径）|
| `manifests/lane-k/etcd-for-nixlbench.yaml` | 若未来 build nixlbench 需要 etcd，直接 apply |
| `scripts/lane-k/orchestrate-sweep.sh` | 60 pair 驱动（NIXL + Mooncake 背靠背），需要 build 完 nixlbench 后再调 |
| `scripts/lane-k/preflight.sh` | 启动 sweep 前的 CLI dump，**已验证有效**，下次务必先跑 |
| `scripts/lane-k/scan-matrix.yaml` | 60 组参数空间（裁剪自 14,400）|
| `results/stage5-p5en/lane-k/TECH_DELTA.md` | 静态差异表 + §6 执行规范（本次 review 已固化）|

## 下次开始点

1. Update Dockerfile + rebuild `yanxi/mooncake-nixl:v5.1`
2. Apply 本次保留的 manifests + scripts
3. Run smoke test (5 min)
4. Run 60-point sweep (~90 min)
5. Produce K_VS_MOONCAKE.md

---

**2026-04-26 UTC 11:30 暂停**：资源释放，下一个 session 开始点见上。
