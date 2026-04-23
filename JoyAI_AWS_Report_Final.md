# AWS × 京东云
## GPU MaaS 平台欧洲落地合作汇报

**时间**：2026-04
**密级**：AWS Internal

> 京东云 GPU MaaS 是支撑京东集团内外部大模型推理服务的核心平台，国内千卡规模承载言犀系列（含 750B 旗舰）与 GLM / Kimi 等主流开源模型。本次合作聚焦 **GPU MaaS 欧洲复制落地**，以 JoyBuy 为首要业务线，通过 AWS 欧洲 Region 承接对外推理服务。

---

## 一、业务背景：欧洲模型中台落地

### 1.1 模型中台全景

京东云在国内运营统一的模型中台（GPU MaaS 平台），承载京东集团内部及外部客户的大模型推理服务。集群总规模千卡以上，支持按各模型实时访问量动态扩缩算力占比。

| 维度 | 现状 |
|------|------|
| 服务对象 | 京东集团内部业务线 + 外部商业客户（含 Coding Plans 订阅）|
| 承载模型 | 言犀系列（含 750B 旗舰、Flash 48B-A3B 开源版）+ 主流开源模型（GLM、Kimi、DeepSeek 等）|
| 核心能力 | 多模型共池，GPU 算力按各模型实时访问量动态扩缩，整体利用率最优 |
| Token 份额 | 言犀系列承载京东内部 80% 以上的 token 用量，是中台绝对主力 |

对外商业化上，京东云已通过 Coding Plans 订阅售卖代码生成 / Agent 能力，是当前中台对外付费收入的形态之一。

### 1.2 模型中台的技术特点

| 特征 | 说明 |
|------|------|
| 推理框架多样 | 平台同时支持 vLLM / SGLang |
| 底层算力 | 租用商汤千卡 GPU 集群，IB 网络 |
| 动态算力调度 | 支持弹性伸缩、模型热切换、PD 比例按流量调整 |
| 言犀主导 + 80% token 集中 | 750B MoE 推理效率直接决定中台整体成本，并行通信、PD 分离、KV Cache 复用是核心优化点 |

### 1.3 欧洲模型中台

本次合作中的 AWS GPU 算力承担京东云欧洲模型中台的落地。

| 项 | 内容 |
|----|------|
| 业务方 | 京东云 |
| 部署区域 | 欧洲 AWS Region |
| 服务目标 | 在欧洲复制一份京东云模型中台能力，面向全集团欧洲业务提供 MaaS |
| 首要业务线 | JoyBuy（京东出海电商平台），同时覆盖欧洲其他业务单元 |
| 承载模型 | 与国内中台一致 —— 言犀系列 + GLM / Kimi 等主流开源模型 |

---

## 二、AWS 团队与合作切入

### 2.1 合作背景

| 项目 | 内容 |
|------|------|
| 启动时间 | 2025 年 5 月 |
| 客户触发事件 | DeepSeek R1 论文爆火，京东探索研究院决定在 RL 后训练阶段进行算法创新，打造对标 R1 的深度思考大模型 |
| 客户基座状态 | 预训练已在国内商汤（千卡）完成，进入 RL 后训练关键期 |
| AWS 切入点 | RL 算法共创 + 框架工程共建 |

### 2.2 参与团队

| 侧 | 角色 | 分工 |
|---|---|---|
| AWS | Account Team — Duan Xun（BD） + Zhao Keming（SA） | 客户关系、商务推进、架构设计、HyperPod / FSx 部署与调优、算法共创牵头 |
| AWS | Kaige Yang + Haoran Lv（Applied Scientists） | GRPO / RL 算法落地经验输入、RL 调参、联合论文共创 |
| JD | 探索研究院 | 基座模型团队 + RL 算法团队（Chang Li / Chao Xue / Xiaodong He） |

### 2.3 关键动作

#### (1) DeepSeek R1 论文技术交流会

双方共同识别的关键技术方向：R1 用 GRPO RL 后训练换来了强推理，但显式 CoT 的 token 开销也随之放大，推理成本与延迟压力很大。共创切入点是在潜空间（latent space）实现隐式推理，用分层 RL 的 option 替代逐 token 的显式思维链。

#### (2) 算法共创实质内容（5–6月）

共创产出论文 arXiv:2507.16473（2025-07-22）：

> *Learning Temporal Abstractions via Variational Homomorphisms in Option-Induced Abstract MDPs*
> Chang Li（JD），Yaren Zhang（Carleton），**Haoran Lv（AWS）**，Qiong Cao（JD），Chao Xue（JD），Xiaodong He（JD）

#### (3) 最小训练推理环境

- 4× p5en.48xlarge（32× H200）× 1 个月
- SageMaker HyperPod（Slurm 模式）+ FSx for Lustre
- 目标：验证 VMOC 算法在 LLM 规模下的可行性，以及 VeRL 在 MoE 场景的 TP+PP+EP 并行适配

---

## 三、言犀模型技术架构

### 3.1 言犀模型矩阵

2025 年 7 月 WAIC，「言犀」品牌升级为 JoyAI。与本次合作相关的两个规格：

| 规格 | 定位 | 状态 |
|------|------|------|
| 750B | 深度思考旗舰 | 2025-05 发布，闭源 API |
| Flash 48B-A3B | 中型开源版本 | 2026-02 开源 |

### 3.2 750B 关键信息与架构推断

基于与客户的交流，750B 已知信息：

- MoE 架构，**激活参数约 40B**（客户侧披露，未对外公开）
- 上下文窗口 1280K tokens，长文本大海捞针评测近 100%
- 原生支持「深度思考 / 非深度思考」双通道
- 预训练数据 70% 通用 + 30% 京东数智供应链原生数据
- 训练上用了动态分层蒸馏和跨领域数据治理
- 客户口径：相较国内同参数模型，训练成本约 -70%、推理效率约 +30%

**硬件承载影响**：750B 总参数 FP8 量化后约 750 GB，已占满 8×H200 单机 1.2TB HBM；扣除业务 KV Cache 和激活开销，单机可承载的场景非常有限，**生产部署必须走多机分布并行 + PD 分离 + KV 分层存储**路径。

750B 本体未开源、架构细节对外未公开披露，但同系列的 Flash 48B-A3B 已完整开源：

| 指标 | JoyAI-LLM Flash 48B-A3B |
|------|------------------------|
| 架构 | MoE（微架构参考 DeepSeek-V3 + Kimi-K2） |
| 总参数 | 48.9B |
| 激活参数 | 2.7B（含 embedding 3.28B） |
| 总层数 | 40（1 Dense + 39 MoE） |
| 注意力 | MLA（32 头，QK-NoRoPE 64 / QK-RoPE 128 / V 128） |
| 隐藏维 | 2048 |
| 专家 | 256 路由 + 1 共享，Top-8 门控 |
| 单专家中间维 | 768 |
| 上下文 | 128K |
| 预训练数据 | 20T tokens |
| 优化器 | Muon |


---

## 四、训练框架共创：VeRL × TP+PP+EP MoE 适配

### 4.1 硬件环境

- 4× p5en.48xlarge（32× H200）+ SageMaker HyperPod（Slurm）+ FSx for Lustre
- 节点间互联：EFA v2 3.2 Tbps

### 4.2 共创核心

AWS Applied Scientist 团队与京东探索研究院算法团队，围绕 VeRL 在百 B 级 MoE RL 后训练下的并行能力补齐，聚焦 TP + PP + EP 三维并行落地，以 256 细粒度专家为对象完成 actor / rollout 端到端 pipeline 适配。

### 4.3 关键收获

- **VeRL 百 B 级 MoE RL 能力补齐**：TP+PP+EP 三维并行端到端跑通，为言犀系列后续 RL 后训练提供参考架构。
- **AWS EFA v2 对客户训练负载完成基线摸底**：客户已有稳定的专家并行通信实践，本次合作在 32 卡规模对同类通信 pattern 做了一轮基线对齐，通信指标处于客户侧可接受区间，为欧洲推理部署提供了网络基线。
- **联合学术产出**：双方共同发表论文 arXiv:2507.16473，Haoran Lv（AWS）作为共同作者署名，是 AWS × JD 研究院深度算法共创。

---

## 五、推理框架技术细节

### 5.1 推理团队与推理框架

客户侧承接推理的团队分属京东集团下的三个主体：

- 京东集团 · 探索研究院：负责基座模型自研推理栈，最先在这里跑通。
- 京东云 · 模型网关团队：统一接入层，负责 API 网关、多模型路由、鉴权限流、多租户、计费和可观测。
- 京东零售 · 九数平台：搜推和 LLM 推理的生产平台，承载大规模托管、弹性伸缩。

不同场景对应不同框架：vLLM 承担大部分通用生产推理；SGLang 用于 Agent 类复杂场景；探索研究院另有一套自研引擎，用于新架构首发、MTP 投机解码和 MoE 专家并行的定制优化。

### 5.2 PD 分离

750B 推理采用 PD 分离。Prefill 计算密集、Decode 带宽密集，两者放在同一节点会互相干扰、SLA 难以同时达标，拆开后各自选各自的最优配置。

研究院发布 750B 时给出两档典型配比：4 台集群用 1P+3D，6 台集群用 2P+4D。京东云 GPU MaaS 的实际生产中，平台支持 P/D 算力实时调控，长期稳态大致落在 1:3，与研究院推荐的 4 台方案一致。

也能看出，客户内部主要是短 prompt 场景（客服、导购、轻量问答），长 prompt 深度思考类请求占比有限——否则稳态会更靠近 2:4。欧洲规划可以以 1:3 作为初始基线。

### 5.3 GPU MaaS 平台的适配路径

京东云 GPU MaaS 在平台层统一管理 KV Cache，底层采用 Mooncake。主要能力是 HBM / DRAM / 远端 KV Store 三级缓存、跨请求 Prefix 复用，以及与 PD 分离的协同——Prefill 节点产出的 KV 直接进共享 KV Store，Decode 节点按需拉取。750B 的 1280K 长上下文依赖这套分层存储才能在可接受的成本下提供服务。

#### 现状：Mooncake 已原生支持 EFA

Mooncake Transfer Engine 官方文档把 `efa` 和 `rdma`、`tcp` 并列为 primary 传输协议，代码里有专门的 `EfaTransport`，底层走 libfabric + EFA SRD，适配 p5en / p5e / p6-b200 / p4d 等实例。社区测试数据 8 块 EFA 调优后吞吐约 170 GB/s，大致是 RoCE RDMA 的 88%。协议参数从 `rdma` 切到 `efa` 即可，KV 管理层不需要替换、运维工具链沿用。Kimi 在生产上也在使用 Mooncake，EFA 纳入其官方 primary 协议。

#### 下一步：引导客户到 NIXL + EFA

Mooncake 能跑起来之后，计划把客户引导到 NVIDIA 的 NIXL（NVIDIA Inference Xfer Library）。2026-03 AWS 发布了 "NIXL with EFA" 官方集成（EFA installer 1.47.0+ / NIXL 1.0.0+），底层可走 UCX 或 LIBFABRIC，上游 vLLM、SGLang、NVIDIA Dynamo、TensorRT-LLM 都已原生支持。

几个考虑：

- NIXL + EFA 是 AWS 官方推荐的路径，稳定性和未来兼容性比第三方方案更有保障，客户留在官方主路径对后续合作也更顺。
- 客户已经在用 vLLM 和 SGLang，这两个框架已经集成 NixlConnector，切换成本很低，顺势引导。
- 节奏上先用 Mooncake 把欧洲生产跑稳，再推 NIXL，不强推替换。

#### MoE EP 通信：引导客户用 UCCL-EP 替代 DeepEP

客户国内训练和推理在 IB 网络上使用 DeepEP 做 MoE 专家并行的 all-to-all 通信。AWS EFA 因为走 SRD 协议、不支持 IBGDA，原生 DeepEP 无法直接运行；如果退回到 NCCL-EP 兜底，decode 端延迟会明显抬高，直接拉低 OTPS。

推荐客户的替代路径是 **UCCL-EP**（OSDI'26，AWS 联合研发，Apache-2.0 开源）：

- **API 与 DeepEP 完全兼容**，drop-in replacement，客户现有 DeepEP 代码无需改动
- 在 NVIDIA + IB 环境下与原生 DeepEP 性能相当；在 EFA 环境下相较 NCCL，SGLang 吞吐 +40%、vLLM TPOT 降 25%，把 decode 侧的 OTPS 差距基本补回
- 已被 DeepSeek 官方 README 列入 Community Forks，生态认可度较高

整体思路：短期用 Mooncake 锁定欧洲 MaaS 落地，同步验证 UCCL-EP（替代 DeepEP）、NIXL + EFA、以及 NIXL + Dynamo 这几条替代路径，再决定长期主路径。

---

## 附录

### 参考资料

| 资料 | 链接 |
|------|------|
| AWS × JD 联合论文 | arXiv:2507.16473 |
| Mooncake 官方文档（含 EFA 支持） | kvcache-ai.github.io/Mooncake/getting_started/supported-protocols.html |
| AWS NIXL with EFA 公告 | aws.amazon.com/about-aws/whats-new/2026/03/aws-support-nixl-with-efa/ |
| JoyAI 开源 | huggingface.co/jdopensource/JoyAI-LLM-Flash |
| JoyAI API | docs.jdcloud.com/cn/jdaip/chat |
