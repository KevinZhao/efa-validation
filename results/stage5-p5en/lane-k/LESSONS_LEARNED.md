# Lane K 测试踩坑与修正步骤（2026-04-26 两轮集中）

> 聚合 `LANE_K_ATTEMPT_LOG.md`（v5 failed attempt）+ `LANE_K_V6_ATTEMPT_LOG.md`（v6 pipeline unlock）+ `20260426T091500Z-nixl-vs-mooncake-partial`（NIXL Spot 中断）三次尝试里发现的真实工程问题 + 修正方法。**下次再启动 Lane K 微基准，按本文 checklist 顺序做可以避开所有已知坑。**

---

## 一、镜像层（image-level）

| # | 症状 | 根因 | 修正 |
|---|---|---|---|
| 1 | `/opt/nixl/bin/nixlbench` 不存在 | v5 镜像只 build `nixl_example` + plugins，没 build `/opt/nixl-src/benchmark/nixlbench/` 子项目 | v6 Dockerfile 加一段独立 meson subproject build：`cd /opt/nixl-src/benchmark/nixlbench && meson setup build --prefix=/opt/nixl -Dwerror=false -Dnixl_path=/opt/nixl -Detcd_inc_path=/usr/local/include -Detcd_lib_path=/usr/local/lib && ninja -C build install` |
| 2 | nixlbench 链接找不到 `libetcd-cpp-api-core.so` | Ubuntu apt 没有 etcd-cpp-apiv3 包，必须源码 build | v6 加一段：`git clone --depth 1 -b v0.15.4 https://github.com/etcd-cpp-apiv3/etcd-cpp-apiv3.git /opt/etcd-cpp-src && cmake -B build -DBUILD_ETCD_CORE_ONLY=ON && ninja install && ldconfig` |
| 3 | `transfer_engine_bench` 即使 `--use_vram=false` 也调用 `cudaPointerGetAttributes` → malloc corruption abort on pods 无 `/dev/nvidia*` | Mooncake `freeMemoryPool()` 在 #ifndef USE_UBSHMEM 分支无条件 call CUDA API | v6 patch：在 `cudaPointerGetAttributes` 前插 `if (!FLAGS_use_vram) { numa_free(addr, size); return; }`（独立 `common/patch-mooncake-bench-v6.py`，COPY + python 执行） |
| 4 | `nvidia-container-runtime` 拒绝注入 `/dev/nvidia*`（host driver 580 超出镜像 `NVIDIA_REQUIRE_CUDA=...driver<576` 白名单） | CUDA 12.6 require_cuda 与 Ohio 节点 driver 不匹配 | v6 加 `ENV NVIDIA_DISABLE_REQUIRE=1`（**不**解决 device 注入，但绕过 require_cuda 检查；**真正的 CPU-mode bench 跑通靠的是上面 #3 的 patch，不靠这条**） |
| 5 | `libnixl.so` 在 pod 内找不到（LD_LIBRARY_PATH 被 subprocess 重置） | 实际 `.so` 在 `/opt/nixl/lib/x86_64-linux-gnu/`，不在 `/opt/nixl/lib` 顶层 | v6 加 `/etc/ld.so.conf.d/nixl.conf` + `ldconfig`：内容两行 `/opt/nixl/lib` + `/opt/nixl/lib/x86_64-linux-gnu` |
| 6 | `nixlbench` 启动失败 `libcuda.so.1: cannot open shared object file` —— 即使 `--initiator_seg_type=DRAM` | nixlbench binary unconditional link libcuda | v6.1 Dockerfile fix（已写入源，需 rebuild）：`ln -sf /usr/local/cuda/lib64/stubs/libcuda.so /usr/lib/x86_64-linux-gnu/libcuda.so.1`（stub 是 no-op lib；真 GPU pod 上 runtime bind-mount 会盖掉它） |
| 7 | `build-image.sh` 空 Dockerfile 上下文，COPY 找不到 `common/patch-*.py` | 原 build-image 只上传 Dockerfile 到 S3，build context 只有 Dockerfile | 加 `--context=repo-rel-path` flag，把附加文件上传 S3 + 下载到 builder 保留目录结构 |

---

## 二、Metadata 层

| # | 症状 | 根因 | 修正 |
|---|---|---|---|
| 8 | `transfer_engine_bench --metadata_server=etcd://host:2379` 报 `Unable to find metadata storage plugin etcd` | Mooncake cmake flag `-DWITH_STORE=OFF` 导致 `USE_ETCD=OFF`、`USE_REDIS=OFF`；只有 `USE_HTTP=ON` | **对 Mooncake**：用 `http://HOST:PORT/metadata`；**对 NIXL**：用 etcd（NIXL 不受 Mooncake WITH_STORE 影响，走 `-Detcd_lib_path` 找 etcd-cpp-apiv3） |
| 9 | `--metadata_server=http://HOST:8080` 所有 PUT 返回 404 | mooncake `http_metadata_server.py` 的 aiohttp route 是 `/metadata`，client 直接追加 `?key=...` → 缺 path | URL **必须**带 `/metadata` 后缀：`http://HOST:8080/metadata` |
| 10 | mooncake-meta Deployment pending | Deployment 里硬编码 `nodeName: ip-10-1-12-94...`（旧 node 名） | 改用 `nodeSelector: topology.kubernetes.io/zone=us-east-2b + node.kubernetes.io/instance-type: p5en.48xlarge`，不绑具体 node |
| 11 | bench pod (hostNetwork) 无法访问 ClusterIP Service | VPC CNI 对 hostNetwork pod 路由 ClusterIP 不可靠 | mooncake-meta Deployment 改 `hostNetwork: true`，bench 连 **host node IP**:8080 不是 svc |
| 12 | NIXL etcd `benchmark_group` 重用后 "rank N >= global size M" | etcd keys 不会自动清理；旧 run 的 rank 0 + 新 run 的 rank 1 = 2 个， 第 3 个来的就被拒 | Orchestrator 每次 invocation 用 `group=nxbl-$(date +%s)-${run_id}` |

---

## 三、RPC / 端口层

| # | 症状 | 根因 | 修正 |
|---|---|---|---|
| 13 | Target `Transfer Engine RPC ... listening on 10.1.12.xxx:15XXX`（随机端口），**不是**我们指定的 `--local_server_name=...:13001` | Mooncake 代码 `transfer_engine_impl.cpp:149` `rpc_binding_method = "new RPC mapping"` 下 **强制** `findAvailableTcpPort()` 避免冲突；`P2PHANDSHAKE` mode 下也一样强制 | **必须设 `MC_LEGACY_RPC_PORT_BINDING=1`** 环境变量 + `metadata_server != P2PHANDSHAKE`（后者会强制 findAvailablePort 覆盖这个 env）。即：两者同时满足 → 使用 `legacy/P2P` binding 代码路径，尊重 `--local_server_name` 里的 PORT |
| 14 | 设了 `MC_HANDSHAKE_PORT=13001` 但无效，target 仍随机端口 | `MC_HANDSHAKE_PORT` 控制的是 SocketHandShakePlugin listen，不是 Transfer Engine RPC port | **两个概念不同**。正确 env 是 `MC_LEGACY_RPC_PORT_BINDING=1`（见 #13） |

---

## 四、Bench 参数层

| # | 症状 | 根因 | 修正 |
|---|---|---|---|
| 15 | initiator 大量 `Cannot select device for dest_addr 0x...` → `FAILED` | `efa_transport.cpp:1093`：initiator 用 `slice->rdma.dest_addr` 查 peer segment desc 里的 buffers[]，要求 `buffer.addr ≤ offset` 且 `offset - buffer.addr ≤ buffer.length - length`。**实际 root cause**：`--block_size × --threads × --batch_size > --buffer_size`（default 1 GB），require_size 超出 target segment，dest_addr 落在 segment 外 | **硬约束**：`block × threads × batch ≤ buffer_size`；超过时有两条路：(a) 增大 `--buffer_size`（需两端都改，且要够 HBM/DRAM）；(b) 降低 `threads` 或 `batch`。我们用 (b) 把 sweep 裁剪到 `threads=4`，`batch ∈ {8, 32, 128}`，保证 max require 0.54 GB < 1 GB |
| 16 | Smoke 跑起来 target 崩 `Failed to get pointer attributes ... CUDA driver version insufficient` | `freeMemoryPool` 里的 cudaPointerGetAttributes（见 #3）；即使 `--use_vram=false` 也会调 | 走 v6 patch 修（#3）。**Verify via sentinel**：`head -3 /opt/mooncake/mooncake-transfer-engine/example/transfer_engine_bench.cpp` 应显示 `// v6 patch: skip cuda* when --use_vram=false` |
| 17 | NIXL batch_size 语义 ≠ Mooncake batch_size 语义 | NIXL `--max_batch_size=N` 是"每 xfer descriptor 打包 N 个 ops"；Mooncake `--batch_size=N` 是"每线程 N 个 outstanding concurrent slices" | 做 K_VS_MOONCAKE 对比时，**不能直接对 batch 数字**。需要两边都 batch=1（深度 = threads）或自己标注"有效并发深度 = threads × batch" |

---

## 五、Runtime / SSM 层

| # | 症状 | 根因 | 修正 |
|---|---|---|---|
| 18 | `kubectl exec ... bash -c 'nohup ... &'` 在 SSM 里 hang（invocation 不返回） | `kubectl exec` TTY 连接等待 bash 进程彻底 exit；即使 `nohup &` 后台化，bash wrapper 还会 wait 前台 subprocess | 用 **`setsid bash -c '...' </dev/null & disown`**；或者在**两次独立的 kubectl exec** 里分别起 target + initiator（每个 kubectl exec 只起一个 bench process 并 nohup 后 shell exit） |
| 19 | SSM `StandardOutputContent` 24 KB 截断，多点 sweep 输出只存头几个点 | SSM API 限制 | 每点 orchestrator 里立即写一行 CSV 到 `/out/`（pod-local），最后读 CSV；**不要**依赖 stdout 捕获所有日志 |
| 20 | Spot 回收两台 p5en → pod 进 Terminating 无法 exec，pod-local `/out/` log 全丢 | EC2 Spot 2-min warning → kubelet drain → containerd 挂 | orchestrator 每点完成立即 `kubectl cp ${POD}:/out/nxi.log /tmp/ && aws s3 cp /tmp/nxi.log s3://...`，或者直接让 bench 写到 S3-backed storage |
| 21 | SSM command 显示 InProgress 5+ min 实际 bench 早已跑完 | 顶层 wrapper bash 还在等 child process；即使 `wait` 完了 stdout 要 buffer 刷完 | `timeout 45 kubectl exec ... -- bench ...` 强制截断；或用 bg + 轮询 pod 内 `/out/*.log` 检测完成标记 |

---

## 六、节点 / 基础设施层

| # | 症状 | 根因 | 修正 |
|---|---|---|---|
| 22 | 新起 p5en 上 `/dev/nvidia*` 不注入 bench pod | `gpu-operator` 的 `nvidia-container-toolkit-daemonset` 在节点上还没部署完成（需 ~3-5 min），bench pod 早于 toolkit ready 时启动 | 先 scale NG + wait 3 min → 看 `kubectl get pods -n gpu-operator -o wide \| grep <新 node IP>` 都 Running → 再 apply bench pods。或者 bench pod 加 `initContainers` wait for toolkit |
| 23 | p5en EFA NIC 命名不是连续的 `rdmap0s0..rdmap15s0` | p5en PCI 布局：NIC 名是 `rdmap85, 86, 87, 88, 110-113, 135-138, 160-163`（非连续） | 不要 hardcode NIC 名。用 `fi_info -p efa` 动态枚举，或让 Mooncake/NIXL auto-discovery (`--auto_discovery=true` / `--device_list=all`) |
| 24 | Ohio p5en SPS 从 9 跌到 1（5 min 内） | Spot 容量分钟级波动 | 每次 launch 前重扫 SPS；不够就 Oregon fallback（`us-west-2 az4` 近期 score=6）或 us-east-1 az2=9（需要新起 cluster） |

---

## 七、"正确的启动 checklist"（下次按这个跑）

### 启动前（~1 min）
1. `aws ec2 get-spot-placement-scores --instance-types p5en.48xlarge --target-capacity 2 --single-availability-zone --region-names us-east-2 us-west-2 us-east-1` → 选 score ≥ 5
2. 确认选的 AZ 已有 cluster + NG（Ohio use2-az2 有 `gpu-p5en-spot-useast2b`）
3. 确认镜像 tag（今天要 v6；如果有 libcuda 链接问题要 v6.1）

### 扩容 + 等 GPU operator（~5 min）
4. `aws eks update-nodegroup-config --scaling-config desiredSize=2`
5. 等 EC2 Running（60 s）
6. 等 k8s node Ready（90 s）
7. **等 gpu-operator components 在新 node 上 Running**（3 min）—— 这条之前踩了两次

### 部署 sidecar（~4 min）
8. Apply `etcd-for-nixlbench.yaml`（NIXL 用）
9. Apply `mooncake-http-metadata.yaml`（Mooncake 用）
10. Apply `lane-k-bench-pods.yaml`（image = v6 最新 tag）
11. 等 pods Running；image 14 GB 冷启 3-4 min，cache hit 10 s

### 必跑 preflight（~1 min）
12. `kubectl exec lane-k-target -- ls /dev/nvidia*` → 如果无（CPU-mode）确认 v6 patch 已 ship：`head -1 /opt/mooncake/.../transfer_engine_bench.cpp` 应该有 `// v6 patch:` 开头
13. `kubectl exec lane-k-target -- /opt/nixl/bin/nixlbench --help | head -3` → 验证 nixlbench 可 load（如果缺 libcuda.so.1 → 跑 `libcuda-stub.sh` 临时 fix，标记下次 rebuild v6.1）
14. `kubectl exec lane-k-target -- curl -m 3 http://META_HOST:8080/metadata?key=x` → 404 OK（reachable）
15. `kubectl exec lane-k-target -- curl -m 3 http://ETCD_POD_IP:2379/` → 404 OK（reachable）

### Mooncake sweep（~8 min，12 点）
16. 用 `sweep-mooncake-cpu.sh`，参数 `threads=4, batch ∈ {8, 32, 128}`（保证 require ≤ 1 GB）
17. 每点完成立即 `kubectl cp ... /tmp/` + `aws s3 cp s3://...`（防 Spot 回收丢数据）
18. CSV 写 `/out/` 同时也 tail 到 bastion 本地 log

### NIXL sweep（~8 min，同 12 点参数）
19. 用 `nixl-sweep.sh`，每点用 fresh `benchmark_group=nixl-$(date +%s)-p${XX}`
20. Required env：Dockerfile 已包含 `NVIDIA_DISABLE_REQUIRE=1` + libcuda stub symlink；bench pod 里只需 `FI_PROVIDER=efa FI_EFA_USE_DEVICE_RDMA=1 FI_EFA_FORK_SAFE=1`
21. 每点完成立即 S3 备份（同 #17）

### 收尾（~2 min）
22. 产 `K_VS_MOONCAKE.md` Δ% 表（同 `run_id` 对比）
23. Delete workload + `desiredSize=0`
24. Verify 实例 shutting-down

---

## 八、关键数字记录（不要再重新发现）

| 数字 | 值 | 来源 |
|---|---|---|
| v6 image ECR digest | `sha256:6271698d52b3b6c63d265b6255dbdc8193556e6bfcce993d4ce3b50663028403` | 2026-04-26 07:39 UTC build |
| **v6.1 image ECR digest** | `sha256:0970bdb3d70729bc0d34a8f8060c3cf12d7d16bf168428d1ce23946387d227f2` | 2026-04-26 09:47 UTC build，**含 libcuda stub symlink，下次 Lane K 使用这个 tag** |
| Mooncake DRAM→DRAM write peak | **211.08 GB/s** at 16 MB block / threads=4 / batch=8 | MOONCAKE_CPU_SWEEP.md |
| Mooncake EFA 16×200G 理论线速 | 400 GB/s/node | physical |
| Mooncake 实测占线速 | ~53% (CPU-DRAM) | 计算 |
| Stage 4 GPU-VRAM baseline（参考） | 365 GB/s write (~91% line rate) | STAGE1-4_P5EN_SUMMARY.md |
| GPU-VRAM / CPU-DRAM 比值 | ~1.73× | 365/211 |
| NIXL LIBFABRIC 1 MB batch=1 4 threads | 58.5 GB/s (avg lat 17.9 µs) | K_VS_MOONCAKE_PARTIAL.md |
| Mooncake buffer_size default | 1 GB (1073741824) | `transfer_engine_bench --help` |
| Mooncake bench sizing invariant | `block × threads × batch ≤ buffer_size` | efa_transport.cpp:1093 |

---

## 九、后续需要升镜像才能解决的遗留项

| # | 问题 | 解 | 下次 rebuild |
|---|---|---|---|
| L1 | ~~libcuda stub 目前靠 runtime~~ **已在 v6.1 解决** | Dockerfile 里 `ln -sf /usr/local/cuda/lib64/stubs/libcuda.so /usr/lib/x86_64-linux-gnu/libcuda.so.1` 已 baked in | ✅ v6.1 built 2026-04-26 09:47 UTC (digest `0970bdb3...227f2`) |
| L2 | v6 image 里的 Mooncake 还是 `634b7097`（v0.3.10.post2 + 5 Henan PRs），如果 Henan 后续有 PR #1944 后的 follow-up 需要 bump `MOONCAKE_REF` | n/a | 视 upstream |
| L3 | NIXL stuck at v1.0.1；main 后续 commits 有 thread-safety 修复但没打 tag | n/a | 等 NIXL v1.0.2 release |

---

**本文件与三个日志的关系**：

- `LANE_K_ATTEMPT_LOG.md` — v5 镜像首次尝试（GPU-mode 失败的具体 trace）
- `LANE_K_V6_ATTEMPT_LOG.md` — v6 镜像 pipeline 打通过程（metadata URL、RPC port binding、buffer size 三大发现）
- `20260426T091500Z-nixl-vs-mooncake-partial/K_VS_MOONCAKE_PARTIAL.md` — NIXL 首个数据点 + Spot 回收记录
- **本 `LESSONS_LEARNED.md`**（你正在读） — 以上三个的提炼 + 可复用 checklist
