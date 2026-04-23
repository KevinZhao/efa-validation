# EFA 多机多卡性能验证方案

**时间**：2026-04
**作者**：AWS Account Team（JD）
**关联文档**：JoyAI_AWS_Report_Final.md 第五章
**编排基线**：`../../eks-cluster-deployment/`（Oregon + Ohio GPU EKS 集群已就绪）

> 目标是在进入欧洲 MaaS 生产部署之前，用最小规模环境把 EFA 上的 MoE 多机多卡通信路径跑通。
> **主路径锁定**：SGLang + Mooncake(EfaTransport) + UCCL-EP（对齐客户生产栈——SGLang PD 分离 1P:1D，Mooncake 管 KV）。vLLM + NixlConnector 仅作对照数据点，NIXL 仅作 Mooncake 的 fallback。

**背景前提**：客户国内机房已稳定运行 SGLang PD 分离（1P:1D）+ Mooncake + DeepEP on **IB**；欧洲 MaaS 是首次把这一套切到 **EFA**，其中 UCCL-EP + EFA + Mooncake-on-EFA 三件套为**首次同时首发**，因此本验证同时承担正确性冒烟与性能基线两类产出。

---

## 一、验证目标

本次验证需要给出主路径的端到端可行性结论与基线数据，以及两条对照/fallback 路径的参考数字：

| 路径 | 定位 | 验证问题 | 产出 |
|------|------|---------|------|
| **SGLang + Mooncake(EFA) + UCCL-EP** | **主路径** | 客户国内 IB 栈整体切到 EFA 后，1P:1D PD 分离端到端是否达 SLA | 1P:1D 下 TTFT / TPOT / OTPS 基线 |
| Mooncake + EFA（KV 层） | 主路径的 KV 子栈 | KV 跨节点传输切 `efa` 协议后吞吐是否达预期 | 跨节点 KV transfer 带宽 / 延迟基线 |
| UCCL-EP on EFA（EP 层） | 主路径的 EP 子栈 | 作为 DeepEP on IB 在 EFA 上的 drop-in，正确性 + 相对 NCCL-EP 兜底的收益 | 数值一致性结论、all-to-all 延迟、端到端 OTPS |
| vLLM + NixlConnector | 对照（reference） | 官方栈基线，给主路径一个外部参照 | NIXL 下的 TTFT / TPOT（单组数据点） |
| NIXL + EFA（KV 层） | Mooncake fallback | Mooncake `EfaTransport` 若不稳，能否顶上 | 等价 payload 下的带宽 / 延迟 |

同时需要摸清 EFA v2 在 MoE 负载下的行为，为后续欧洲 MaaS 的容量与拓扑规划提供依据。

---

## 二、最小测试环境（EKS 编排）

### 2.1 复用现有 EKS 集群

两套生产级集群已由 `eks-cluster-deployment` 部署完毕，直接复用：

| 集群 | Region | VPC | 用途 |
|------|--------|-----|------|
| `gpu-cluster-oregon` | `us-west-2` | `vpc-081ea929da61b21d7` | **主验证**（p5 Spot 容量历史更稳） |
| `gpu-cluster-ohio` | `us-east-2` | `vpc-0bcb622cffd226d26` | **Fallback**（Oregon 容量不足时切这里） |

两个集群已包含：K8s 1.35、VPC CNI、EBS CSI、Cluster Autoscaler、LB Controller、Metrics Server、Pod Identity。控制平面为私有 API，所有操作必须在堡垒机或 VPC 内发起。

### 2.2 GPU 节点组（新建）

用 `scripts/option_install_gpu_nodegroups.sh` 拉起 GPU MNG，该脚本已原生处理：
- EFA + EFA-only 多网卡 Launch Template（p5.48xlarge 1 EFA + 31 EFA-only）
- `vpc.amazonaws.com/efa` 设备插件
- Spot / ODCR / Capacity Block 三种计费模式
- Cluster Placement Group

环境变量：

```bash
# 在堡垒机上执行
cd /home/ec2-user/workspace/eks-cluster-deployment
cp .env.oregon .env                # 先试 Oregon
export GPU_INSTANCE_TYPES=p5.48xlarge
export GPU_NODE_MIN_SIZE=0
export GPU_NODE_MAX_SIZE=4
export GPU_NODE_DESIRED_CAPACITY=2 # 起步 2 节点，需要再上调到 4
export DEPLOY_GPU_SPOT=true        # 默认就是 Spot
export DEPLOY_GPU_OD=false
./scripts/option_install_gpu_nodegroups.sh
```

节点跑完后应看到：

```bash
kubectl get nodes -l node.kubernetes.io/instance-type=p5.48xlarge
kubectl describe node <gpu-node> | grep -E 'nvidia.com/gpu|vpc.amazonaws.com/efa'
# 期望：nvidia.com/gpu: 8  vpc.amazonaws.com/efa: 32
```

### 2.3 规模与计费

| 项 | 选型 | 说明 |
|----|------|------|
| 实例类型 | `p5.48xlarge`（8× H100 80GB，3.2 Tbps EFA v2） | 与 2025-05 POC 使用的 p5en 同代，EFA 网卡配置一致 |
| 节点数 | **起步 2 节点（16× H100）**，必要时 Autoscaler 扩到 4 | 2 节点足以覆盖多机多卡 EP 通信 |
| 计费 | Spot（Autoscaler 管理），fallback Capacity Block 1–3 天 | Spot 约 on-demand 40%–60% |
| 放置 | Cluster Placement Group（脚本自动创建） | 保证 EFA 低延迟路径 |

p5 Spot 容量波动较大。若 Oregon 拉不到 2 节点，立刻切 `.env.ohio` 并重跑同样的脚本。如仍失败，切 `DEPLOY_GPU_CB=true` 跑 Capacity Block。

### 2.4 存储

- **共享权重 / 数据集**：FSx for Lustre `SCRATCH_2` 1.2 TB，通过 FSx CSI Driver 挂成 `ReadWriteMany` PVC。模型权重预从 HuggingFace / S3 下载到 FSx。
  - 若 FSx CSI 未安装，用 `scripts/option_install_csi_drivers.sh`。
- **节点本地**：每节点 100 GB LVM 数据卷（系统节点组 SOP 已配置），用于 NCCL 临时文件。

### 2.5 容器与软件栈

镜像基线：`nvcr.io/nvidia/pytorch:24.10-py3` 或 `vllm/vllm-openai:latest`，启动时装入：

| 组件 | 版本 | 用途 |
|------|------|------|
| EFA installer | ≥ 1.47.0 | NIXL + EFA 官方集成最低版本 |
| libfabric | ≥ 1.22 | EFA / SRD 底层 |
| NCCL | ≥ 2.23 | baseline 通信 |
| aws-ofi-nccl | 最新 release | NCCL over EFA |
| vLLM | ≥ 0.7（已集成 NixlConnector） | 推理主引擎 |
| SGLang | 最新 main（已集成 UCCL-EP） | Agent 场景推理 |
| Mooncake | 含 `EfaTransport` 的 release | KV Cache 分层管理 |
| UCCL-EP | OSDI'26 公开版 | MoE EP 通信（DeepEP drop-in） |
| NIXL | ≥ 1.0.0 | KV 传输层 |

容器中要求：`--privileged=false` + `securityContext.capabilities.add: [IPC_LOCK]`，挂 `/dev/infiniband`，申请 `vpc.amazonaws.com/efa: 32` + `nvidia.com/gpu: 8`。

### 2.6 多机作业编排

EKS 原生路径，三选一：

- **K8s Job + pod anti-affinity**（冒烟测试够用）：2 个 Pod，requiredDuringSchedulingIgnoredDuringExecution 分散到不同节点，用 headless Service + DNS 做 rank 发现。
- **MPI Operator**（推荐）：`mpi-operator` v0.5+，NCCL-tests / DeepEP bench 直接用 `MPIJob` CRD，自动处理 hostfile 和 SSH。
- **LeaderWorkerSet（LWS）**：vLLM / SGLang 多机推理官方推荐编排方式，1 leader + N worker，适合阶段 4 端到端。

本方案：阶段 1–3 用 MPIJob，阶段 4 用 LWS。

---

## 三、验证对象（HuggingFace 开源模型）

分三档逐级放大，尽量贴合 JoyAI 750B 的架构特征（MoE + MLA + 大专家数）：

| 档位 | 模型 | 来源 | 总参 / 激活 | 说明 |
|------|------|------|------------|------|
| 冒烟 | Mixtral-8x7B-Instruct | `mistralai/Mixtral-8x7B-Instruct-v0.1` | 46.7B / 12.9B | 经典 MoE baseline，生态最成熟 |
| 主验证 | **JoyAI-LLM-Flash** | `jdopensource/JoyAI-LLM-Flash` | 48.9B / 2.7B | **与 750B 架构一致**（MLA + 256 Top-8 + 40 层），最有说服力 |
| 扩展 | DeepSeek-V2-Lite / DeepSeek-V3 MoE | `deepseek-ai/...` | 15.7B–671B | 与客户 IB 栈直接对标；V3 需 4 节点以上 |

主验证选 JoyAI-LLM-Flash 的原因：架构与客户生产 750B 一致，数据外推到 750B 生产规模时的风险最小；且客户自己已验证过量化与投机解码效果，可直接对齐。

---

## 四、验证步骤

分四阶段，每阶段有独立入口 / 出口条件，失败可在本阶段闭环，不影响后续阶段排期。所有阶段都以 K8s 资源形式提交。

### 4.1 阶段 1：EFA 基础链路（0.5 天）

**做什么**
- 提交 `MPIJob`：`nccl-tests` 容器，2 节点 × 8 GPU = 16 ranks；
- 跑 `all_reduce_perf` / `all_to_all_perf`，消息大小 8KB–1GB；
- 对比本节点内（NVLink）与跨节点（EFA）带宽曲线。

**关键 YAML 片段**（示意）

```yaml
apiVersion: kubeflow.org/v2beta1
kind: MPIJob
spec:
  slotsPerWorker: 8
  mpiReplicaSpecs:
    Worker:
      replicas: 2
      template:
        spec:
          containers:
          - image: nvcr.io/nvidia/pytorch:24.10-py3-with-nccl-tests
            resources:
              limits:
                nvidia.com/gpu: 8
                vpc.amazonaws.com/efa: 32
            securityContext:
              capabilities: { add: [IPC_LOCK] }
```

**看什么**
- 跨节点 all-reduce 大消息（≥256MB）聚合带宽 ≥ 320 GB/s（名义 3.2 Tbps 的 80%）；
- all-to-all 小消息延迟无异常尖峰；
- `FI_PROVIDER=efa` 生效，`NCCL_DEBUG=INFO` 日志里能看到 `NET/OFI Selected Provider is efa`。

**出口**：EFA 链路达标。否则回查 EFA 设备插件、Launch Template、aws-ofi-nccl 版本。

### 4.2 阶段 2：MoE EP 通信（1.5–2.5 天）

> 因客户国内用的是 DeepEP on IB、欧洲才首次切到 UCCL-EP on EFA，属"栈切换"而非"调参"。性能对比前必须先过一道**正确性冒烟闸门**，否则后续数据无意义。

**4.2.0 正确性冒烟（前置，0.5 天）**
- 固定 seed、固定 routing、固定 token/expert 分布，分别用 NCCL-EP on EFA 与 UCCL-EP on EFA 跑 `dispatch + combine`；
- 对比两者输出张量的数值一致性（max-abs-diff / rel-diff，阈值参考 NCCL 跨实现对比惯例，fp16 量级 1e-3）；
- 额外做一次小规模端到端 sanity：SGLang 跑 Mixtral-8x7B 几十条请求，UCCL-EP vs NCCL-EP logits 对齐。
- **闸门**：不通过则不跑 4.2 性能对比；上 UCCL 团队 issue，阶段 4 临时回退 NCCL-EP。

**4.2.1 性能对比（1–2 天）**
- 用 DeepEP 自带 bench 或 UCCL-EP 提供的同构 bench（MPIJob 提交），跑 `dispatch + combine` all-to-all；
- 三组对比：**UCCL-EP on EFA**（主） vs **NCCL-EP on EFA**（EFA 兜底） vs **DeepEP on IB 参考线**（取客户国内公开/内部数字或 DeepEP 官方数字，仅看趋势，不与 EFA 数据直接混比）；
- 覆盖 hidden=7168、token/expert 分布模拟 Top-8 路由（贴 JoyAI-LLM-Flash 256 Top-8 架构）。

**看什么**
- UCCL-EP on EFA 相较 NCCL-EP on EFA：dispatch 延迟 ↓、有效带宽 ↑；
- 指标方向与 OSDI'26 论文中 SGLang +40% / vLLM TPOT −25% 一致；
- IB 参考线主要用来回答"同样 DeepEP-style 通信，换到 EFA 后相对退化/提升多少"。

**出口**：正确性闸门通过，且 UCCL-EP 在 EFA 上表现与论文口径趋势一致，可作为欧洲 MaaS 的 EP 通信底座。

### 4.3 阶段 3：KV Cache 跨节点传输（1 天）

**做什么**
- Mooncake Transfer Engine 切 `efa` 协议，2 节点跨机 put/get 微基准（K8s Job，2 Pod + Service）；
- NIXL + EFA 做等价场景对比（同样 payload 大小、同样 fanout）。

**看什么**
- Mooncake 8× EFA 单节点聚合吞吐 ≈ 170 GB/s（与官方口径对齐）；
- NIXL 在同负载下的带宽 / 延迟相对位置。

**出口**：Mooncake 可作为短期生产 KV 管理，NIXL 数据可支撑"下一步引导"决策。

### 4.4 阶段 4：端到端推理（2–3 天）

**编排**：`LeaderWorkerSet`（LWS）部署 SGLang 为主；vLLM 仅作对照。ClusterIP Service 暴露 OpenAI 兼容接口，`kubectl port-forward` 或内部 LB 发压。

**做什么**
- 主模型：JoyAI-LLM-Flash 48B-A3B（架构与生产 750B 一致）；
- 部署形态（锁 **1P:1D**，对齐客户生产）：
  - **(a) SGLang 单机 TP=8**（对照基线，1 节点）：1 个 Pod，建立吞吐 / TTFT / TPOT 单机基线，用于计算 PD 分离的相对开销；
  - **(b) SGLang 跨机 PD 分离 1P:1D**（**主路径**，2 节点）：1 个 Prefill LWS + 1 个 Decode LWS，各 TP=8 占一个 p5.48xlarge；KV 层走 **Mooncake `EfaTransport`**；此形态是欧洲 MaaS 目标形态；
  - **(c) SGLang 跨机 EP**（可选扩展，2 节点起）：EP=16，TP=2，走 **UCCL-EP on EFA**；仅当 (b) 中 Decode 侧出现 MoE all-to-all 瓶颈时触发；
  - **(d) vLLM + NixlConnector（对照，单组数据点，2 节点）**：只跑一组与 (b) 等价负载，给主路径一个外部参照；不作为交付物主轴。
- 负载：ShareGPT / LongBench 混合，覆盖短 prompt（贴京东稳态）与长 prompt；
- 发压工具：SGLang `bench_serving` 或 `genai-perf`，每组 500+ 请求，P50 / P95 / P99 都要记录。

**看什么**
- **(b) 1P:1D** 的 TTFT / TPOT / OTPS 是否达到 SLA 假设，且相对 (a) 单机 TP=8 的退化幅度（目标 ≤ 1.3×）；
- KV 传输路径上是否出现长尾（主看 Mooncake；NIXL 作为 fallback 对照）；
- 若触发 (c)，UCCL-EP 路径端到端 OTPS 相对 NCCL-EP 兜底的绝对提升；
- (d) vLLM + NIXL 的相对位置，仅用于识别 SGLang 主路径是否存在明显反常。

**出口**：产出 1P:1D 主路径的可直接写入欧洲 MaaS 生产部署方案的基线数据表。

### 4.5 可选阶段 5：训练侧复核（视时间窗口）

- VeRL + TP+PP+EP 三维并行在 Mixtral 8x7B 上的端到端可跑通性（MPIJob）；
- 不追指标，只复核 2025-05 POC 的结论在新 EFA/NCCL 版本上仍成立。

---

## 五、成功判据

| 维度 | 判据 | 如果不达 |
|------|------|----------|
| EFA 链路 | all-reduce 带宽 ≥ 名义值 80% | 升级 EFA installer、重建 placement group、确认 aws-ofi-nccl |
| UCCL-EP 正确性 | UCCL-EP vs NCCL-EP on EFA 数值一致性通过（fp16 max-abs-diff ~1e-3 量级）；Mixtral 小规模 logits 对齐 | 上 issue 到 UCCL 团队，阶段 4 回退 NCCL-EP 兜底跑 |
| UCCL-EP 性能 | 在 EFA 上 dispatch 延迟显著优于 NCCL-EP，趋势与 OSDI'26 一致 | 备 pplx-kernels 作为过渡，短期结论按 NCCL-EP 兜底记录 |
| Mooncake efa | 单节点聚合吞吐 ≥ 150 GB/s（目标 ≈ 170 GB/s） | 先排查 SRD / libfabric 配置，若仍差距大向 Mooncake 上游反馈，端到端切 NIXL fallback |
| **端到端推理（1P:1D 主路径）** | **SGLang 1P:1D（跨 2 节点）的 TTFT / TPOT ≤ 单机 TP=8 同配置的 1.3×**，OTPS 达 SLA 假设 | 先定位 KV 传输长尾（Mooncake vs NIXL），再看 Prefill↔Decode 调度 |

---

## 六、预算与排期

**时间**：整体 2 周（3 天环境搭建 + 1.5 周执行验证）。EKS 控制平面已存在，省掉 1 周集群搭建。

**容量规划**：**2 节点 p5.48xlarge 已覆盖主路径**——SGLang 1P:1D 本身就是 1 Prefill 节点 + 1 Decode 节点，与最小环境天然匹配。只有在触发阶段 4(c) 的 EP=16 扩展或阶段 4.5 的训练复核（Mixtral TP+PP+EP）时才需扩到 4 节点。

**算力预算**（2 节点 p5.48xlarge Spot，覆盖阶段 1–4 主路径）：

| 项 | 估算 |
|----|------|
| p5 Spot × 2 节点 × ~60 小时有效机时 | $3.5k – $7k |
| FSx Lustre SCRATCH_2 1.2TB × 2 周 | ~$300 |
| EKS 控制平面（已存在） | $0（增量） |
| S3 / 数据传输 | ~$100 |
| **合计（主路径）** | **~$4k – $7.5k** |

扩展项（按需追加）：4 节点跑 EP=16 或 DeepSeek-V3，再追加同量级预算。

---

## 七、风险与应急

| 风险 | 应急 |
|------|------|
| Oregon p5 Spot 容量不足 | 切 `.env.ohio` 重跑 `option_install_gpu_nodegroups.sh`；若仍失败切 `DEPLOY_GPU_CB=true` |
| EFA 设备插件未生效 | 检查 `kubectl get ds -n kube-system` 中的 EFA DaemonSet；参考 `option_install_gpu_nodegroups.sh` 日志 |
| **UCCL-EP 首次 on EFA 的正确性风险**（国内用 DeepEP on IB，欧洲 UCCL-EP + EFA + Mooncake-on-EFA 三件套同时首发） | 4.2.0 正确性冒烟闸门提前拦截；不过则上 issue 到 UCCL 团队（OSDI'26 作者侧），阶段 4 回退 NCCL-EP on EFA 兜底，保证 1P:1D 主路径数据仍能产出 |
| UCCL-EP 性能未达论文口径 | 备 pplx-kernels 作为过渡；结论按 NCCL-EP 兜底记录，不阻塞 4.4(b) 主路径 |
| Mooncake `EfaTransport` 兼容性问题 | 切 NIXL + EFA 作为主 KV 传输；Mooncake 结论推迟，但 1P:1D 主路径仍要跑出数据 |
| FSx 吞吐不够导致权重加载慢 | 预拉到本地 NVMe（100GB LVM 数据卷），FSx 只放共享中间产物 |
| 私有 API 访问限制 | 所有 kubectl 命令在堡垒机上执行，参考 `docs/DEPLOYMENT_SOP.md` |

---

## 八、交付物

- 验证报告（含四阶段数据表、对比图、结论）；
- 可复用的 K8s 清单集合（MPIJob / LWS / Service / PVC），放入团队内部 repo 作为欧洲 MaaS 部署蓝本；
- 欧洲 MaaS 生产部署建议（PD 配比、EP 通信栈选型、KV 管理栈选型）；
- 对 UCCL-EP / Mooncake / NIXL 上游的问题清单（若有）。

---

## 附录：参考

- 基础设施：`../../eks-cluster-deployment/`（`README.md`、`docs/DEPLOYMENT_SOP.md`、`scripts/option_install_gpu_nodegroups.sh`）
- Mooncake EFA 支持：kvcache-ai.github.io/Mooncake/getting_started/supported-protocols.html
- AWS NIXL with EFA：aws.amazon.com/about-aws/whats-new/2026/03/aws-support-nixl-with-efa/
- UCCL-EP（OSDI'26）：uccl 项目页
- JoyAI-LLM-Flash：huggingface.co/jdopensource/JoyAI-LLM-Flash
- DeepEP：github.com/deepseek-ai/DeepEP
- MPI Operator：github.com/kubeflow/mpi-operator
- LeaderWorkerSet：github.com/kubernetes-sigs/lws
