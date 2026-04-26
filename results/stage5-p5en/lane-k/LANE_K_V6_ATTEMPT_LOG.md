# Lane K v6 bench attempt — 2026-04-26 second try with `mooncake-nixl:v6`

**Status**: **BLOCKED** at Mooncake EFA transport NIC selection for CPU DRAM addrs.
**GPU cost**: 2 × p5en × ~1 h = 2 node-hours.

## What v6 fixed (vs v5 attempt)

1. ✅ **`/opt/nixl/bin/nixlbench` binary now present** (601 KB) — v5 只 build `nixl_example`.
2. ✅ **`transfer_engine_bench` v6 CPU-mode patch sentinel** 在 `freeMemoryPool()` — 不再因 `cudaPointerGetAttributes` crash.
3. ✅ **`etcd-cpp-apiv3 v0.15.4`** 装上（nixlbench 后续跑要用）.
4. ✅ **`NVIDIA_DISABLE_REQUIRE=1`** 在镜像 ENV（虽然没直接解决 `/dev/nvidia*` 注入，但绕过 require_cuda 检查）.
5. ✅ **`ld.so.conf.d/nixl.conf` + `ldconfig`** 让 `libnixl.so` 全局可见.

## What v6 still can't do (not an image problem)

6. ❌ `/dev/nvidia*` injection into bench pods. Same root cause as v5 attempt — gpu-operator + nvidia-container-toolkit mismatch on new p5en nodes. Unaffected by `NVIDIA_DISABLE_REQUIRE=1`.
   - **Workaround available**: `--use_vram=false` CPU-mode thanks to v6 patch.

## New discoveries this round

### A. P2PHANDSHAKE 不支持 fixed RPC port — 必须用 metadata server

Source trace (`transfer_engine_impl.cpp` L132 & L149):

```cpp
if (metadata_conn_string == P2PHANDSHAKE) {
    rpc_binding_method = "P2P handshake";
    desc.rpc_port = findAvailableTcpPort(desc.sockfd);   // random port!
}
```

- `MC_HANDSHAKE_PORT=13001` env 无效（它控制的是 SocketHandShakePlugin listen，不是 RPC port）
- 只有 `metadata_conn_string != P2PHANDSHAKE` + `MC_LEGACY_RPC_PORT_BINDING=1` 才能绑到 `--local_server_name` 的 PORT
- **Correct invocation pattern**:
  ```
  metadata_server=http://HOST:8080/metadata
  local_server_name=IP:PORT
  MC_LEGACY_RPC_PORT_BINDING=1
  ```

### B. mooncake http_metadata_server URL 必须带 `/metadata` 后缀

`http_metadata_server.py` 的 aiohttp route: `'/metadata'`。
Mooncake bench client 会直接对 conn_string 做 HTTP PUT，把 `?key=...` 附加后面：
- ❌ `metadata_server=http://HOST:8080` → client PUT `http://HOST:8080?key=mooncake%2F...` → 404
- ✅ `metadata_server=http://HOST:8080/metadata` → client PUT `http://HOST:8080/metadata?key=...` → 200

**这条是个静默的 API 契约**，upstream 文档没明说。

### C. v6 patch (freeMemoryPool 下 cudaPointerGetAttributes skip) 生效，但 bench 新错误 on CPU DRAM

当 `--use_vram=false`:
- `allocateMemoryPool()` 走 `numa_alloc_onnode()` ✅
- `freeMemoryPool()` 走 v6 patched `numa_free()` ✅
- Mooncake EFA transport `efa_context.cpp:625` 报 **`Cannot select device for dest_addr 0x...`** 大量重复
- Bench 在 `transfer_engine_bench.cpp:397` 打印 `FAILED` 后退出

**推测根因**: `FI_MR_HMEM=1` 环境下，Mooncake 期望 target 的 buffer 是 HMEM-registered (通常意味着 VRAM/CUDA managed)。CPU DRAM buffer 注册到 EFA MR 时 hmem type 判定错误，导致 initiator 端查找 dest_addr 的 NIC 时找不到匹配。

**下一步的 workaround 路径**:
- **Option 1**: 取消 `FI_MR_HMEM=1`，改用传统 host-only MR（需要源码确认 EfaTransport 支持）
- **Option 2**: 强制 use_vram=true + 修复 `/dev/nvidia*` injection (真正去解决 gpu-operator 的问题)
- **Option 3**: 不用 mooncake `transfer_engine_bench`，改写一个最小的 python script 直接调 mooncake python binding 做 DRAM→DRAM over EFA（完全跳过 bench 的 NIC selection 路径）

## Full runtime env that got furthest

```bash
# Target
FI_PROVIDER=efa
FI_EFA_USE_DEVICE_RDMA=1
FI_EFA_FORK_SAFE=1
FI_MR_HMEM=1                              # ⚠️ may need to try =0 next time
MC_WORKERS_PER_CTX=2
MC_NUM_CQ_PER_CTX=2
MC_LEGACY_RPC_PORT_BINDING=1              # REQUIRED for fixed RPC port

transfer_engine_bench \
  --mode=target --protocol=efa \
  --metadata_server=http://META_IP:8080/metadata \   # /metadata suffix REQUIRED
  --local_server_name=TARGET_IP:13001 \
  --duration=90 --use_vram=false
```

target side got: `listening on 10.1.12.238:13001` ✅, `Chunk 0/1 registered on 16 NICs` ✅, idle waiting for initiator.

initiator side got: EFA init ✅, Chunk registered ✅, metadata PUT 200 ✅, then **`Cannot select device for dest_addr`** × many → `FAILED`.

## Artifacts updated

- `manifests/lane-k/lane-k-bench-pods.yaml` — image bumped to `:v6`
- `manifests/lane-k/mooncake-http-metadata.yaml` — removed hardcoded `nodeName`, replaced with `nodeSelector: topology.kubernetes.io/zone=us-east-2b`
- `scripts/lane-k/t3v*.sh` — smoke test scripts, v4 is the winning recipe (metadata server + legacy RPC port binding + detached 2-step invocation)

## Summary: do we have Lane K data?

**No microbench numbers captured this round**. We now have the correct recipe to drive the bench up to **FAIL at NIC selection**, which is one step further than the v5 attempt (which crashed at cudaPointerGetAttributes).

## What to try next

Ranked by expected success probability and cost:

1. **`FI_MR_HMEM=0`** (5 min, just another smoke run) — if this works, all subsequent sweep is unblocked.
2. **Fix `/dev/nvidia*` injection at gpu-operator level** (15-30 min debug + possible node reboot) — then use `--use_vram=true` which is the supported path.
3. **Use NIXL nixlbench directly** — we have the binary now; NIXL doesn't use Mooncake's hmem-aware NIC selection. Start fresh with `nixlbench --backend LIBFABRIC --etcd_endpoints http://IP:2379`.
4. **Rewrite minimal python bench with mooncake python binding** — bypass bench's NIC selection logic.

## Files to look at next session

- `/opt/mooncake/mooncake-transfer-engine/src/transport/efa_transport/efa_context.cpp:625` — the "Cannot select device" source
- `/opt/mooncake/mooncake-transfer-engine/src/transport/efa_transport/efa_transport.cpp` (around `registerLocalMemory`, `preTouchMemory`) — where hmem type is decided
