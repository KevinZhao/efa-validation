# PR-1 L-03 Bench 执行流水（2026-04-26）

**前提**：
- 2 台 p5en.48xlarge Spot running in us-east-2b（SPS score=9）
- Node 1: `i-0d98298b88efb5d7b` / `10.1.12.228`
- Node 2: `i-0862e9eaf045df342` / `10.1.12.18`
- Bastion: `i-097c86b226a32a128` / `10.1.11.244` (c7g.large AL2023 arm64)
- AMI: EKS-optimized AL2023 + NVIDIA 1.35 v20260415

**目标**：跑 `bench/test_low_latency.py` 对比 baseline vs patched，所有指标 ±1% 噪声内

---

## Phase 0 · SSH 到 bastion

从你的本机（有 VPC 访问的机器）：
```bash
ssh ec2-user@10.1.11.244    # Ohio bastion c7g.large
```

（如果 bastion 需要 SSM-Session-Manager：`aws ssm start-session --target i-097c86b226a32a128 --region us-east-2`）

---

## Phase 1 · 探测节点环境（1 min）

在 **bastion** 上，用 SSM 查询 p5en 节点实际安装了什么：

```bash
# 方案 A: SSM start-session 交互
aws ssm start-session --target i-0d98298b88efb5d7b --region us-east-2

# 然后在 session 里跑：
sudo bash -c '
  echo "=== nvidia ==="; nvidia-smi --query-gpu=name,driver_version --format=csv,noheader | head -3
  echo "=== cuda ==="; which nvcc; ls /usr/local/cuda* 2>/dev/null
  echo "=== efa ==="; ls /opt/amazon/efa/bin/ 2>/dev/null | head -5
  echo "=== docker ==="; which docker; systemctl is-active containerd
  echo "=== disk ==="; df -h / /data /mnt/nvme 2>/dev/null
  echo "=== uname ==="; uname -a
'
```

**期望**：
- nvidia-smi: 8× H200
- nvcc: 不存在（EKS AMI 不带 CUDA toolkit）
- EFA: `/opt/amazon/efa/bin/fi_info` 存在
- containerd: active；**docker 不存在**（EKS 用 containerd 不用 docker daemon）

---

## Phase 2 · 在节点上准备 build 环境（10 min）

**策略**：用 `nvidia/cuda:12.6.2-devel-ubuntu22.04` 容器，挂 uccl 源码进去 build（不装系统级 CUDA）。

在**节点上**（SSM session 里）：

```bash
# 1. 切 root 用 nerdctl（containerd 自带 CLI，兼容 docker 语法）
sudo -i

# 2. 装 git 和基础工具到 host（一次性）
dnf install -y git tmux

# 3. 找个大盘挂载：EKS 节点通常 /data 或 /mnt/nvme
df -h | grep -iE "data|nvme"
# 假设是 /data
cd /data

# 4. clone UCCL fork
git clone https://github.com/KevinZhao/uccl.git
cd uccl
git remote add origin https://github.com/uccl-project/uccl.git
git fetch origin
git checkout origin/main  # detached head on upstream main

# 记录 baseline SHA
git rev-parse HEAD > /data/baseline_sha.txt
cat /data/baseline_sha.txt   # 期待 dd9573dd
```

---

## Phase 3 · Build baseline（在 uccl 容器里）

```bash
cd /data/uccl

# UCCL 官方 build 路径：用 nerdctl 启动 build 容器
# build.sh 自动检测 CONTAINER_ENGINE
CONTAINER_ENGINE=nerdctl bash build.sh cu12 ep --install 2>&1 | tee /data/build-baseline.log
```

**失败 fallback**：如果 containerd/nerdctl 不兼容 build.sh，手动拉 CUDA devel 镜像：

```bash
nerdctl run --rm -it \
  -v /data/uccl:/workspace/uccl \
  -v /opt/amazon/efa:/opt/amazon/efa:ro \
  --network host \
  nvidia/cuda:12.6.2-devel-ubuntu22.04 bash

# 容器内
apt update && apt install -y python3-pip libibverbs-dev
export EFA_HOME=/opt/amazon/efa
cd /workspace/uccl/ep
make -j16 2>&1 | tee /workspace/uccl/build-baseline.log
# 产出 *.so 在 ep/ 下；python binding 装方式：
pip install -e .
```

**成功标志**：`build-baseline.log` 末尾有 `.so` 文件路径，无 ERROR / warning。

---

## Phase 4 · 运行 Baseline Bench（核心）

### 4.1 选定双节点 master/worker 模式

```bash
# Node 1 (Master): 10.1.12.228
# Node 2 (Worker): 10.1.12.18
# 先在 Node 1 上把 uccl 目录用 rsync 推到 Node 2（通过 bastion SSM）

# 更简单：Node 2 上也做同样的 clone + build
ssh or SSM to Node 2, repeat Phase 2 + 3
```

**但简化**：先单独查 `bench/test_low_latency.py` 的 multi-node 启动方式，看用 torchrun 还是 mpirun：

```bash
cat /data/uccl/ep/bench/test_low_latency.py | head -50
```

### 4.2 运行（假设 torchrun）

在 Node 1 (Master):
```bash
cd /data/uccl/ep
export UCCL_IB_HCA=''  # 让 UCCL auto-detect
export GLOO_SOCKET_IFNAME=eth0
export NCCL_SOCKET_IFNAME=eth0
export MASTER_ADDR=10.1.12.228
export MASTER_PORT=29500

# 双节点共 16 GPU
torchrun --nproc_per_node=8 --nnodes=2 --node_rank=0 \
  --master_addr=10.1.12.228 --master_port=29500 \
  bench/test_low_latency.py \
    --num-tokens 128 --hidden 7168 --num-topk 8 --num-experts 288 \
  2>&1 | tee /data/bench-baseline-1.log
```

在 Node 2 (Worker):
```bash
cd /data/uccl/ep
export UCCL_IB_HCA=''
export GLOO_SOCKET_IFNAME=eth0
export NCCL_SOCKET_IFNAME=eth0
export MASTER_ADDR=10.1.12.228
export MASTER_PORT=29500

torchrun --nproc_per_node=8 --nnodes=2 --node_rank=1 \
  --master_addr=10.1.12.228 --master_port=29500 \
  bench/test_low_latency.py \
    --num-tokens 128 --hidden 7168 --num-topk 8 --num-experts 288 \
  2>&1 | tee /data/bench-baseline-1.log
```

**跑 3 次**（baseline-1 / baseline-2 / baseline-3），取中位数防单次抖动。

### 4.3 提取关键指标

```bash
grep -E "Dispatch both|Combine both|Dispatch BW|Combine BW" /data/bench-baseline-*.log
```

期望看到类似：
```
Dispatch both: p50=174.9us p99=xxx us
Combine both:  p50=326.7us p99=xxx us
Dispatch BW: 42.88 GB/s
Combine BW: 17.xx GB/s
```

---

## Phase 5 · 应用 PR-1 Patch

```bash
cd /data/uccl
git checkout -b pr/ep-complete-pr552-vector-pool

# 用 sed 应用最小 diff
python3 <<'EOF'
with open('ep/src/proxy.cpp', 'r') as f:
    content = f.read()

old = '''void Proxy::post_gpu_commands_mixed(
    std::vector<uint64_t> const& wrs_to_post,
    std::vector<TransferCmd> const& cmds_to_post) {
  // Separate atomic operations from regular RDMA writes
  std::vector<uint64_t> rdma_wrs, atomic_wrs, quiet_wrs, barrier_wrs;
  std::vector<TransferCmd> rdma_cmds, atomic_cmds, quiet_cmds, barrier_cmds;'''

new = '''void Proxy::post_gpu_commands_mixed(
    std::vector<uint64_t> const& wrs_to_post,
    std::vector<TransferCmd> const& cmds_to_post) {
  // Separate atomic operations from regular RDMA writes.
  // Reuse member vectors (declared in proxy.hpp) to avoid per-call heap
  // allocations (completes the refactor started in #552).
  rdma_wrs.clear();
  atomic_wrs.clear();
  quiet_wrs.clear();
  barrier_wrs.clear();
  rdma_cmds.clear();
  atomic_cmds.clear();
  quiet_cmds.clear();
  barrier_cmds.clear();'''

assert old in content, 'old block not found'
assert content.count(old) == 1, 'multiple matches!'
content = content.replace(old, new)

with open('ep/src/proxy.cpp', 'w') as f:
    f.write(content)
print('patch applied')
EOF

# 验证 diff
git diff ep/src/proxy.cpp
```

---

## Phase 6 · Build Patched

```bash
cd /data/uccl
CONTAINER_ENGINE=nerdctl bash build.sh cu12 ep --install 2>&1 | tee /data/build-patched.log
```

---

## Phase 7 · 运行 Patched Bench

同 Phase 4，只是输出改成 `/data/bench-patched-{1,2,3}.log`。**3 次**取中位数。

---

## Phase 8 · 对比 + 结果整理

```bash
# 回 controller 机（本机）
scp bastion:/data/bench-baseline-*.log ~/workspace/efa-validation/results/stage5-p5en/uccl-ep-pr1-l03/baseline/
scp bastion:/data/bench-patched-*.log ~/workspace/efa-validation/results/stage5-p5en/uccl-ep-pr1-l03/patched/

# 或 SSM 拉文件（aws ssm start-session 里 base64 编码文件出来也行）
```

生成对比表（模板在 `docs/PR1_L03_REVIEW.md` §5）。

---

## Phase 9 · 收尾（关节点 or 保留）

选 1：
- **关掉 Spot**（省钱，约 $100/h）：
  ```bash
  aws eks update-nodegroup-config --region us-east-2 \
    --cluster-name gpu-cluster-ohio \
    --nodegroup-name gpu-p5en-spot-useast2b \
    --scaling-config minSize=0,maxSize=4,desiredSize=0
  ```
- **保留** 准备 PR-2/3/4/5/6 并行 bench

---

## 用户须知 · 我没能 SSM 过去

本机发 SSM `send-command` 给 p5en 节点一直 **Pending**（agent online 但不执行）。两种可能：
1. IAM role 缺权限（unlikely，eks-xxx profile 应该够）
2. 节点刚起 20 min，agent bootstrap 还没完

**绕开**：你 SSH 到 bastion 后，用 `aws ssm start-session --target i-0d98298b88efb5d7b` 交互式进节点——这走的是 SSM 的另一个 channel，不依赖 `send-command`。

---

## 预期总时间

| Phase | 时间 |
|---|---|
| 0 SSH + Phase 1 探测 | 5 min |
| 2+3 Clone + baseline build | 20-40 min（首次拉 Docker 镜像最慢）|
| 4 Baseline bench 3 次 | 5-10 min（每次 1-3 min）|
| 5+6 Patch + 增量 build | 5 min（cached build）|
| 7 Patched bench 3 次 | 5-10 min |
| 8 对比 + 写 PR body | 15 min |
| **合计** | **~60-90 min** |

---

## 风险 / 抛出

1. **`bench/test_low_latency.py` 的实际 CLI 参数**我没在节点上看过；假设沿用 PR #745 的 `--num-tokens 128 --hidden 7168 --num-topk 8 --num-experts 288`——**到节点上先 `--help` 一下**
2. **EKS AMI 没 nvcc** 是大概率，但也可能 `/usr/local/cuda` 存在——**Phase 1 探测结果决定 build 路径走 A 还是 B**
3. **`CONTAINER_ENGINE=nerdctl` 兼容 build.sh**——未验证；如果不行 fallback 到手动 Docker run
4. **2 节点同步 uccl 源码 + build**：最佳是用 bastion 做中转 scp；或者两个节点上都 git clone（保证 SHA 一致）
5. **Spot 回收风险**：memory `feedback_spot_reclaim_wipes_nvme` 说 Spot 回收会擦 nvme。**bench 结果跑完立即 scp 到 bastion 或本地**，不要留节点
