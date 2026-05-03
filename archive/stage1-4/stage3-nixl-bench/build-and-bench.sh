#!/bin/bash
# Pod-side bootstrap: install deps, build etcd-cpp-apiv3 + nixlbench, run benchmark.
# Shared by both nodes. Each runs with rank determined by etcd registration order.
set -eux

ROLE="${ROLE:-unknown}"
ETCD_SVC="${ETCD_SVC:-http://nixl-etcd.yanxi-validation.svc:2379}"
BENCH_GROUP="${BENCH_GROUP:-default}"
BLOCK_SIZE_START="${BLOCK_SIZE_START:-65536}"       # 64K
BLOCK_SIZE_MAX="${BLOCK_SIZE_MAX:-268435456}"        # 256M
INITIATOR_SEG="${INITIATOR_SEG:-VRAM}"
TARGET_SEG="${TARGET_SEG:-VRAM}"
DEVICE_LIST="${DEVICE_LIST:-all}"
NUM_THREADS="${NUM_THREADS:-16}"
NUM_ITER="${NUM_ITER:-1008}"
WARMUP_ITER="${WARMUP_ITER:-112}"
OUTLOG="${OUTLOG:-/workspace/out/nixlbench.log}"

mkdir -p "$(dirname "$OUTLOG")"
mkdir -p /workspace/build-cache

# ---- Install apt deps (cpprest + OpenSSL + utils + gflags should already be there) ----
if [ ! -f /workspace/build-cache/.apt-done ]; then
  apt-get update 2>&1 | tail -3
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
      libcpprest-dev libssl-dev uuid-dev libgflags-dev \
      git curl ca-certificates 2>&1 | tail -5
  touch /workspace/build-cache/.apt-done
fi

# ---- Install etcd binary for the target role ----
if [ ! -x /usr/local/bin/etcd ]; then
  cd /workspace
  curl -sSL -o etcd.tar.gz https://github.com/etcd-io/etcd/releases/download/v3.5.13/etcd-v3.5.13-linux-amd64.tar.gz
  tar xzf etcd.tar.gz
  cp etcd-v3.5.13-linux-amd64/etcd /usr/local/bin/etcd
  cp etcd-v3.5.13-linux-amd64/etcdctl /usr/local/bin/etcdctl
  /usr/local/bin/etcd --version
fi

# ---- Build etcd-cpp-apiv3 (install into /usr/local for default discovery) ----
if [ ! -f /usr/local/lib/libetcd-cpp-api.so ]; then
  cd /workspace
  rm -rf etcd-cpp-apiv3
  git clone --depth=1 https://github.com/etcd-cpp-apiv3/etcd-cpp-apiv3.git
  cd etcd-cpp-apiv3
  mkdir build && cd build
  cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DBUILD_ETCD_TESTS=OFF -DBUILD_ETCD_CORE_ONLY=OFF ..  2>&1 | tail -10
  make -j8 2>&1 | tail -5
  make install 2>&1 | tail -5
  ldconfig
fi

# ---- Build nixlbench ----
if [ ! -x /opt/nixl-src/benchmark/nixlbench/build/nixlbench ]; then
  cd /opt/nixl-src/benchmark/nixlbench
  rm -rf build
  meson setup build --wipe \
      -Detcd_inc_path=/usr/local/include -Detcd_lib_path=/usr/local/lib \
      -Dnixl_path=/opt/nixl \
      -Dcudapath_inc=/usr/local/cuda/include -Dcudapath_lib=/usr/local/cuda/lib64 \
      --prefix=/workspace/nixlbench-install 2>&1 | tail -20
  ninja -C build 2>&1 | tail -30
fi

ls -la /opt/nixl-src/benchmark/nixlbench/build/nixlbench
export LD_LIBRARY_PATH="/usr/local/lib:/opt/nixl/lib/x86_64-linux-gnu:/opt/nixl/lib/x86_64-linux-gnu/plugins:/opt/amazon/efa/lib:/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}"
export FI_PROVIDER="${FI_PROVIDER:-efa}"
export FI_EFA_USE_DEVICE_RDMA="${FI_EFA_USE_DEVICE_RDMA:-1}"
export FI_EFA_FORK_SAFE="${FI_EFA_FORK_SAFE:-1}"

# Sanity check
fi_info -p efa 2>&1 | head -20 || echo "(fi_info: no EFA)"
nvidia-smi -L 2>&1 | head -10 || echo "(no nvidia-smi)"
ls /dev/infiniband 2>&1 | head -5 || echo "(no /dev/infiniband)"

if [ "$ROLE" = "etcd" ]; then
  MY_IP=$(hostname -i | awk '{print $1}')
  echo "starting etcd on ${MY_IP}:2379"
  exec /usr/local/bin/etcd \
      --data-dir=/workspace/etcd-data \
      --listen-client-urls=http://0.0.0.0:2379 \
      --advertise-client-urls=http://0.0.0.0:2379 \
      --listen-peer-urls=http://0.0.0.0:2380 \
      --initial-advertise-peer-urls=http://0.0.0.0:2380 \
      --initial-cluster=default=http://0.0.0.0:2380
fi

# ---- bench roles: wait for etcd reachable ----
for i in $(seq 1 120); do
  if /usr/local/bin/etcdctl --endpoints="${ETCD_SVC}" endpoint health 2>&1; then
    echo "etcd ready"; break
  fi
  echo "waiting for etcd ($i)"
  sleep 2
done

# Initiator needs small head-start to register first and be rank 0; target adds 3s delay.
if [ "$ROLE" = "target" ]; then
  sleep 5
fi

set +e
/opt/nixl-src/benchmark/nixlbench/build/nixlbench \
    --etcd_endpoints="${ETCD_SVC}" \
    --backend=LIBFABRIC \
    --worker_type=nixl \
    --benchmark_group="${BENCH_GROUP}" \
    --scheme=pairwise \
    --mode=SG \
    --op_type=WRITE \
    --initiator_seg_type="${INITIATOR_SEG}" \
    --target_seg_type="${TARGET_SEG}" \
    --start_block_size="${BLOCK_SIZE_START}" \
    --max_block_size="${BLOCK_SIZE_MAX}" \
    --start_batch_size=1 \
    --max_batch_size=1 \
    --num_iter="${NUM_ITER}" \
    --warmup_iter="${WARMUP_ITER}" \
    --num_threads="${NUM_THREADS}" \
    --num_initiator_dev=1 \
    --num_target_dev=1 \
    --device_list="${DEVICE_LIST}" \
    --enable_pt \
    --progress_threads=2 \
    2>&1 | tee "${OUTLOG}"
RC=$?
echo "=== nixlbench exit: ${RC} ==="
echo "=== role: ${ROLE} ==="
sleep 10
exit 0
