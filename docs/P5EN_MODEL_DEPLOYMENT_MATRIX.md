# p5en 单节点 TP=8 部署矩阵 — 开源大模型覆盖清单

**更新日期**：2026-04-26
**目标读者**：AWS 客户 / Solution Architect / Stage 5 测试规划
**核心结论**：**90%+ 的国内主流开源模型可以在 p5en 单节点 TP=8 直接跑，不需要 EP 跨机、不需要 UCCL-EP、不需要 NIXL。只需要 Mooncake（含 Henan 4 个 EFA PR）做 1P1D / 1PnD 的 KV 传输即可。**

---

## 一、结论速查（给销售 / 客户一句话）

> **如果客户跑 DeepSeek-V3 / V4-Flash、Qwen3.5 / 3.6 全家、GLM-4.6、Hunyuan Hy3、MiniMax-M2 系列、Kimi K2.6 INT4 —— p5en 单节点 TP=8 直接跑，Mooncake 做 PD 分离的 KV transfer，不需要任何 EP 跨机改造。**
>
> **只有跑 DeepSeek-V4-Pro (1.6T)、Kimi K2.6 FP8、Qwen3-Max 这类 1T+ FP8 模型时，才需要跨节点 + EP，这时才触发 UCCL-EP 需求。**

---

## 二、p5en 容量参考线

| 硬件 | 规格 |
|---|---|
| 单节点 GPU | 8 × H200 |
| 单节点 HBM | 8 × 141 GB = **1.128 TB** |
| 节点内互联 | NVLink + NVSwitch（TP 走这条，不走 EFA） |
| 节点间互联 | EFA (SRD)，Mooncake KV transfer 走这条 |

**判定规则**（按模型权重大小 + 留 KV cache 空间）：

| 权重精度 | 单节点可容 | 部署建议 |
|---|---|---|
| FP8 ≤ 500 GB | 🟢 宽松 | TP=8，context 随便开 |
| FP8 500–800 GB | 🟡 可行 | TP=8，注意 KV cache 余量 |
| FP8 800 GB–1 TB | 🟠 紧 | TP=8 可跑，context / batch 要收 |
| FP8 > 1 TB | 🔴 必跨节点 | 2+ 节点 + EP + UCCL-EP |
| **原生 INT4 量化** | 容量翻倍 | 按 0.5 byte/param 重新判定 |

---

## 三、🟢 单节点 TP=8 推荐清单（1P / 1PnD 模式，Mooncake + Henan PR 即可）

### 3.1 Dense 模型（所有 dense 都无脑单节点）

| 模型 | 发布日 | 参数 | FP8 权重 | 备注 |
|---|---|---|---|---|
| Qwen3.6-27B (dense) | 2026-04-22 | 27B | ~27 GB | 轻量 |
| Qwen3.5-27B (dense) | 2026-02-24 | 27B | ~27 GB | |
| Qwen3.5-9B / 4B / 2B / 0.8B | 2026-03-02 | 0.8B–9B | < 10 GB | 小机型也能跑 |
| Qwen2.5-72B / Qwen3-32B | 2024–2025 | 32B–72B | 32–72 GB | 🟢 |
| Yi-34B / InternLM3-20B | — | 20B–34B | 20–34 GB | 🟢 |

### 3.2 MoE 模型（🟢 宽松档）

| 模型 | 发布日 | 总参 / 激活 | FP8 权重 | 架构亮点 |
|---|---|---|---|---|
| **Qwen3.6-35B-A3B** ⭐ | 2026-04-16 | 35B / 3B | ~35 GB | Gated DeltaNet + MoE，KV cache 超小 |
| Qwen3.5-35B-A3B | 2026-02-24 | 35B / 3B | ~35 GB | |
| Qwen3.5-122B-A10B | 2026-02-24 | 122B / 10B | ~122 GB | 宽松，多 GPU setups 友好 |
| **MiniMax-M2 / M2.5 / M2.7** ⭐ | 2025-10 / 2026-02 / 2026-04 | 230B / 10B | ~230 GB | Lightning Attention（O(N) 复杂度），长 context 神器 |
| DeepSeek-V2.5 | 2024 | 236B / 21B | ~236 GB | MLA 架构 KV 超省 |
| **Hunyuan Hy3** ⭐ | 2026-04-24 | 295B / 21B | ~295 GB | 腾讯最新旗舰 |
| GLM-4.5 | 2025-07 | 355B / 32B | ~355 GB | |
| GLM-4.6 | 2025-09 | 355B / 32B | ~355 GB | 200K context |
| Hunyuan-Large | 2024-11 | 389B / 52B | ~389 GB | |
| **DeepSeek-V4-Flash** ⭐ | 2026-04-24 | 284B / 13B | ~284 GB | V4 系单机友好版，1M context，CSA+HCA attention |
| **Qwen3.5-397B-A17B / Plus** ⭐ | 2026-02-16 | 397B / 17B | ~400 GB | 线性 attn + MoE，原生多模态，1M context |
| MiniMax-Text-01 | 2025-01 | 456B / 45.9B | ~456 GB | 4M context 外推 |
| Qwen3-235B-A22B | 2025-04 | 235B / 22B | ~235 GB | |
| Qwen3-Coder-480B | 2025 | 480B / 35B | ~480 GB | 专用 coding |

### 3.3 MoE 模型（🟡 紧档 — 能跑但要管 context）

| 模型 | 发布日 | 总参 / 激活 | FP8 权重 | 注意事项 |
|---|---|---|---|---|
| **DeepSeek-V3 / V3.1 / V3.2** | 2024-12 及后续 | 671B / 37B | ~670 GB | MLA 架构 KV cache 极小，长 context 实测能撑 |
| **DeepSeek-R1** | 2025-01 | 671B / 37B | ~670 GB | 同上，推理模型 |
| GLM-5 | 2026-02-11 | 744B / 40B | ~744 GB | 200K context，生产建议 context 收到 64K–128K |
| GLM-5.1 | 2026-04-12 | 754B / 44B | ~754 GB | 8 小时自主运行能力，context 同上 |

### 3.4 特别拯救者（原生 INT4 → 跨档）

| 模型 | 原生精度 | 实际 size | 档位翻转 |
|---|---|---|---|
| **Kimi K2.6 (native INT4 QAT)** ⭐ | INT4 | ~500 GB | 🔴 → 🟡 / 🟢 |

> ⚠️ **Kimi K2.6 关键变化**：官方 spec 明确 "Native INT4 QAT on MoE components"，1T 参数 × 0.5 byte = **~500 GB**，p5en 单节点装得下。这是过去 3 个月最重大的单节点部署新变量。**前提**：SGLang / vLLM 必须支持 K2.6 INT4 kernel。

---

## 四、🔴 必须跨节点 + EP 的清单（这时才需要 UCCL-EP）

| 模型 | 发布日 | 总参 / 激活 | FP8 权重 | 部署要求 |
|---|---|---|---|---|
| **DeepSeek-V4-Pro** ⚠️ | 2026-04-24 | **1.6T / 49B** | **~1.6 TB** | ≥ 2 节点 + EP，单节点必 OOM |
| **Kimi K2.6 (FP8 版本)** | 2026-04-20 | 1T / 32B | ~1 TB | 单节点勉强，长 context 必崩，推荐 2 节点 EP |
| **Kimi K2 (原版 FP8)** | 2025-07 | 1T / 32B | ~1 TB | 同上 |
| **Qwen3-Max / Qwen3.5-Max** | 2025-09 / 2026 | > 1T | > 1 TB | 不开源 / 必须跨节点 |

⚠️ **这是 UCCL-EP 存在的根本原因**：
- 这档模型只能跨节点 + EP
- EP 的 all-to-all 依赖 IBGDA（InfiniBand GPUDirect Async）
- **EFA 不支持 IBGDA**（EFA 是 SRD + libfabric，没有 ibverbs GDA 路径）
- DeepEP 在 EFA 上起不来 → 必须用 **UCCL-EP**（CPU proxy 绕过 GDA）

---

## 五、架构对比：1P / 1PnD vs. 跨节点 EP

### 5.1 1P / 1PnD 推荐路径（🟢 绝大多数场景）

```
┌─────────────────────────────────────────────┐
│  p5en 节点 1 (Prefill)                      │
│  - TP=8，全部走 NVLink                      │
│  - 模型权重一次性加载在 8× H200             │
│  - SGLang / vLLM 直接部署                   │
└─────────────┬───────────────────────────────┘
              │ Mooncake KV transfer (EFA + Henan PR)
              ↓
┌─────────────────────────────────────────────┐
│  p5en 节点 2-N (Decode)                     │
│  - TP=8，同样 NVLink 内部通信               │
│  - 多个 decode 节点做 1P→nD 分离            │
└─────────────────────────────────────────────┘
```

**所需组件**：
- ✅ **Mooncake v0.3.10.post2**（含 Henan 4 个 EFA PR）
- ✅ SGLang / vLLM 标准版
- ❌ **不需要** UCCL-EP
- ❌ **不需要** NIXL
- ❌ **不需要** DeepEP

**优化机会**：**只要提升 Mooncake 性能，就能提升整条链路**。Henan PR 是唯一的适配工作。

### 5.2 跨节点 EP 路径（🔴 只在必要时）

```
┌───────────────┬───────────────┬───────────────┬───────────────┐
│  节点 1 EP 0  │  节点 2 EP 1  │  节点 3 EP 2  │  节点 4 EP 3  │
└───────┬───────┴───────┬───────┴───────┬───────┴───────┬───────┘
        │               │               │               │
        └───────────────┴─all-to-all────┴───────────────┘
                 (dispatch/combine via EFA)
                          ↓
               需要 UCCL-EP（CPU proxy）
```

**所需组件**：
- ✅ Mooncake (KV) + UCCL-EP (EP all-to-all)
- ✅ 两套适配都要做
- ⚠️ 性能受 EFA 不支持 IBGDA 限制，CPU proxy 有延迟 overhead

---

## 六、给客户的部署决策树

```
客户要跑什么模型？
│
├── Qwen3.5/3.6 全家、DeepSeek-V3/R1/V4-Flash、GLM-4.5/4.6/5/5.1、
│   Hunyuan Hy3、MiniMax-M2/M2.5、Kimi K2.6 INT4
│   → 🟢 p5en 单节点 TP=8 + Mooncake (Henan PR) + 1P1D/1PnD
│   → 不用做 UCCL-EP/NIXL 适配
│
├── DeepSeek-V4-Pro (1.6T) / Kimi K2.6 FP8 / Qwen3-Max
│   → 🔴 必须 ≥ 2 节点 + EP + UCCL-EP
│   → 建议先评估是否换成 V4-Flash 或 K2.6 INT4
│
└── 客户模型不在列表里？
    → 查参数量：FP8 权重 ≤ 800 GB → 🟢
               > 1 TB → 🔴
```

---

## 七、过去 3 个月的关键变化（2026-02 → 2026-04）

| 变化 | 日期 | 对 p5en 部署的影响 |
|---|---|---|
| DeepSeek 双路线：V4-Pro 1.6T + V4-Flash 284B | 2026-04-24 | Flash 单节点友好成为客户默认选项，Pro 才需要 EP |
| Kimi K2.6 原生 INT4 QAT | 2026-04-20 | 从"必跨节点" → "单节点可跑"，**大翻转** |
| Qwen3.5 / 3.6 全系走线性 attention + MoE | 2026-02 / 04 | KV cache 极省，同 HBM 下能撑更长 context |
| GLM-5 / 5.1 替代 GLM-4.6 | 2026-02 / 04 | 744–754B，单节点紧但可行 |
| MiniMax-M2 系列"小而精"路线 | 2026 持续 | 230B / 10B，单节点无压力 |
| Hunyuan Hy3 替代 Hunyuan-Large | 2026-04-24 | 更小 295B vs 389B，单节点更宽松 |

**趋势观察**：开源社区 2026 明显分成两条路线：
- **"小而精"档（230B–500B）**：刻意让单机能跑 → p5en 1P/1PnD 理想场景
- **"超大 1T+"档**：冲顶峰性能 → 必然需要跨节点 + EP

---

## 八、Stage 5 测试建议

### 8.1 优先级高（覆盖 80% 客户）
- [x] DeepSeek-V3/R1 671B on p5en TP=8 + Mooncake 1P1D → **Henan PR 验证场景**
- [ ] DeepSeek-V4-Flash 284B on p5en TP=8 + Mooncake 1P1D → 新主力
- [ ] Kimi K2.6 INT4 on p5en TP=8 → 验证 "1T → 单节点" 的新路径
- [ ] Qwen3.5-397B-A17B on p5en TP=8 → 旗舰单节点验证

### 8.2 优先级中（覆盖 15% 客户）
- [ ] GLM-5 744B on p5en TP=8（紧档压力测试）
- [ ] Hunyuan Hy3 295B on p5en TP=8
- [ ] MiniMax-M2 230B on p5en TP=8（lightning attention 特殊路径）

### 8.3 优先级低 / 只在必要时（覆盖 5% 客户）
- [ ] DeepSeek-V4-Pro 1.6T on 2× p5en + UCCL-EP → 跨节点场景
- [ ] Kimi K2.6 FP8 on 2× p5en + UCCL-EP

---

## 九、给客户的销售话术

> **"AWS p5en 8×H200 的单节点 HBM 容量是 1.128 TB。这个容量设计刚好覆盖国内开源社区 90%+ 的主流模型 —— 从 DeepSeek-V3/V4-Flash、Qwen3.5 全家、GLM-4.6 到 Hunyuan Hy3、MiniMax-M2，全部都能单节点 TP=8 跑，不需要跨机 EP 改造。**
>
> **我们推荐 `1P+nD`（一个 prefill 节点带多个 decode 节点）的架构，prefill/decode 之间通过 Mooncake 做 KV transfer，Mooncake 已经有针对 AWS EFA 的专项优化（Henan PR 4 个），导入即用。**
>
> **这条路径的好处：**
> 1. **不需要 UCCL-EP 适配** —— 每个节点内部 TP=8 走 NVLink，根本不碰 EFA all-to-all
> 2. **不需要 NIXL 适配** —— Mooncake 已经处理所有跨节点 KV 传输
> 3. **性能优化聚焦 Mooncake** —— 优化投入 1 个方向，全场景受益
>
> **只有跑 DeepSeek-V4-Pro (1.6T)、Kimi K2.6 FP8 这类 1T+ 模型时，才进入跨节点 + EP 场景，这时才需要 UCCL-EP。这是少数情况，我们有完整方案。"**

---

## 附录 A — Mooncake Henan PR 清单

见 `results/STAGE1-4_P5EN_SUMMARY.md` 和 `docs/HENAN_PR_QUALITY_REVIEW.md`。

**核心 PR**（4 个必要 + 1 个 RDMA→EFA 补丁）：
- Mooncake upstream 原生只支持 IB/RoCE verbs
- 必须用含 Henan EFA PR 的 `v0.3.10.post2` 版本
- 镜像：`mooncake-nixl:v6.1`（Ohio + Oregon ECR 都有）

## 附录 B — 参考文献

- DeepSeek V4 release: https://api-docs.deepseek.com/news/news260424
- Qwen3.5 release: Alibaba 2026-02-16 官方发布
- Qwen3.6-35B-A3B: 2026-04-16 HF 发布
- Kimi K2.6: https://kimi-k2.org/blog/24-kimi-k2-6-release
- GLM-5 / 5.1: Z.AI / Zhipu 发布页
- MiniMax-M2: https://github.com/MiniMax-AI/MiniMax-M2
- Hunyuan Hy3: Tencent 2026-04-24 发布
