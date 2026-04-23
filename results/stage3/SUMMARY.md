# Stage 3.1 - Mooncake transfer_engine_bench on EFA

## 结果

**PASS** — Mooncake C++ `transfer_engine_bench` 在 EFA provider 下跑通 2 节点 write，**19.31 GB/s throughput / 60 秒 / 4324 batches**。

| 指标 | 值 |
|---|---|
| Protocol | `efa` (libfabric + efa provider) |
| Operation | `write` (initiator → target) |
| Memory | DRAM → DRAM（`use_vram=false`） |
| Duration | 60.11 s |
| Buffer size | 4 GiB |
| Block size | 4 MiB |
| Batch size | 64 |
| Threads | 12（与 upstream `efa_latency_bench.py` 默认一致） |
| Batch count | 4324 |
| **Throughput** | **19.31 GB/s** |

## 拓扑

```
+---------------------+      +-------------------+      +---------------------+
| initiator p5.48xl  |<-efa->| target p5.48xl    |      | mooncake-metadata    |
| 32 EFA NIC × 400 Gb |      |  32 EFA NIC × 400 |      | (Go gin, :8080)      |
| IP 10.1.12.64       |      | IP 10.1.12.192    |      | ClusterIP Service    |
+---------------------+      +-------------------+      +---------------------+
          |  ^ segment_id=$TARGET_IP:12345                     ^
          +------------------------- metadata PUT / GET --------+
```

- 32 个 EFA device（`rdmap*s0`）全部被 `efa_context.cpp` / `efa_transport.cpp` 正常 init
- 每 worker 一条 EFA connection，共 12 worker × N conn 完成后开始 transfer
- metadata server 用 Mooncake 上游 `example/http-metadata-server`（Go + gin）

## 验证路径

- 镜像：`788668107894.dkr.ecr.us-east-2.amazonaws.com/yanxi/mooncake-nixl:v1`
  （digest `sha256:432ab6dcd6f3d579...762ebb`，size 8.67 GB，内含 Mooncake v0.3.10.post1 + NIXL v1.0.1）
- Manifest：`stage3-mooncake-nixl/mooncake-efa-bench.yaml`
- 完整日志：
  - `results/stage3/mooncake-init.log`（initiator，含结果 `Test completed: duration 60.11, batch count 4324, throughput 19.31 GB/s`）
  - `results/stage3/mooncake-tgt.log`（target，32 EFA device init + 32 CQ polling threads）

## 踩坑

1. **metadata server**：`http-metadata-server-python` 是 `bootstrap_server.py` 库文件，不能直接 `python3 执行`；`http-metadata-server/` 是 Go 源（main.go），需要 `go mod tidy && go build`。选 Go 方案（镜像已装 Go 1.23）。
2. **metadata URL 必须有 `/metadata` 路径**：Mooncake 客户端用 `?key=...` 作 query，但 path 必须是 `/metadata`。错配时 GIN 返回 404，Mooncake `cannot publish segments`，target `Assert failed: xport`。
3. **参数扫**：
   - 初版 `block=1MiB batch=64 threads=8 dur=30` → 只跑 8 batches，0.02 GB/s（建链吃掉了大部分时间）
   - v2 `block=8MiB batch=64 threads=32 dur=60` → `FAILED`（threads=32 撑爆 CQ / CPU）
   - v3 `block=4MiB batch=64 threads=12 dur=60` → **19.31 GB/s** ✅（对齐 upstream `efa_latency_bench.py` 默认）
4. **teardown 报 Error status**：initiator 成功拿到结果后 `Stopped CQ polling worker threads`，pod 状态显示 Error，但不影响结果收集（stdout 已打印）。

## 待办

- [ ] 再扫一组 `block={64K, 512K, 4M, 16M} × operation={read, write}` 看延迟/吞吐曲线（可选，用 `efa_latency_bench.py` 做）
- [ ] Stage 3.2 NIXL nixlbench（NIXL v1.0.1 meson 构建没默认出 `nixlbench` binary，需要单独 meson 配置 `enable_benchmark=true`，留给后续）
