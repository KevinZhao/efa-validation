# Instrumentation PR: EFA device caps dump — 执行步骤

**日期**：2026-04-28
**目标**：加一个 env-gated informational dump 让 UCCL 维护者能拿到 AWS EFA 真实 caps（`max_inline_data`, `device_caps` bitmask 等），为后续 optimization lever 决策提供数据
**分支**：`instrumentation/efa-caps-dump` (local)，从 upstream `4bd57b1e` 起
**优先级**：Phase 0 Day 1，Sprint A 主 PR 的前置

---

## 已完成 (2026-04-28)

- [x] 从 upstream `4bd57b1e` 起分支 `instrumentation/efa-caps-dump`
- [x] `ep/src/rdma.cpp:588-611` 加 24 行 `#ifdef EFA` 块
  - Gate env: `UCCL_EP_EFA_CAPS_DUMP=1` (默认不打印)
  - 打印字段：`max_sq_wr / max_rq_wr / max_sq_sge / max_rq_sge / inline_buf_size / max_rdma_size / device_caps`
  - 失败退化：`efadv_query_device` 非 0 返回码照样打一行 `rc=N`
- [x] `clang-format --dry-run --Werror ep/src/rdma.cpp` 通过（0 diff）
- [x] 本地 CPU-only 机无 libefa，build 验证推迟到 Ohio bastion p5en
- [x] Patch 保存到 `patches/uccl-upstream-prs/efa-caps-dump/0001-ep-efadv-caps-dump.patch`

---

## 待完成

### 1. Ohio bastion build 验证（需 p5en）

```bash
# 在 Ohio bastion 或 p5en pod 里
cd /opt/uccl  # 或 git clone
git remote add fork https://github.com/KevinZhao/uccl.git
git fetch fork instrumentation/efa-caps-dump
git checkout instrumentation/efa-caps-dump
bash build.sh cu12 ep --install
python3 -c "import uccl.ep; print('import OK')"
```

### 2. 在 p5en 上起 buffer 触发 dump（1 node 单跑）

```bash
# 最简路径：直接跑 test_low_latency init 一次
UCCL_EP_EFA_CAPS_DUMP=1 \
  torchrun --nnodes=1 --nproc_per_node=8 \
  bench/test_low_latency.py --num-tokens=128 --hidden=7168 \
  --num-topk=8 --num-experts=288 2>&1 | grep '\[EFA caps\]' \
  | tee p5en-efa-caps-$(date +%Y-%m-%d).txt
```

预期每个 GPU 一行，16 NIC × 8 GPU = 每次 init 多条（具体条数取决于 UCCL 是否每 GPU 只 open 1 NIC 还是 map 多 NIC）。

### 3. Archive

```bash
# 在本机
scp ohio-bastion:p5en-efa-caps-*.txt \
  /home/ec2-user/workspace/efa-validation/results/stage5-p5en/efa_caps/
```

### 4. 开 upstream informational issue

**注意**：**开 Issue 不是 PR**。Issue 更轻量，不求 merge，只求维护者看到数据。

Title: `[EP] AWS EFA device capability dump on p5en (informational)`

Body 参考模板见 `PR_BODY.md`（写好后放这里）。

`cc @MaoZiming @YangZhou1997`

### 5. 可选 · 把代码变更作为 tiny PR 推（follow-up）

先看 MaoZiming 对 issue 的反应：
- 如果他说"能不能 upstream 这个 dump 开关" → 提 PR
- 如果他只是 ack → 保留本地不提 PR，env gate 意味着可持续用

PR title: `[EP] Add optional EFA device caps dump (UCCL_EP_EFA_CAPS_DUMP)`

---

## 成功标准

- [ ] p5en caps dump 文本存在 `results/stage5-p5en/efa_caps/p5en-2026-04-28.txt`
- [ ] 每个 NIC 的 `max_rdma_size` / `inline_buf_size` / `device_caps` bit 明确记下
- [ ] upstream issue 开了，至少 MaoZiming 或 YangZhou1997 看到
- [ ] 解出 `device_caps` bitmask（查 efadv.h 的 `EFADV_DEVICE_ATTR_CAPS_*` 常量）
- [ ] 知道了 `EFADV_SQ_DEPTH_ATTR_INLINE_WRITE` bit 在 p5en 是否支持（决定 L2 lever 是否可走）

---

## 后续 follow-up PR 候选

从 upstream `efadv.h` 看还有两个未用的 API，可作为 Phase 0 后续：
1. `efadv_get_max_sq_depth()` — 返回 `INLINE_WRITE` flag + `max_inline_data` 实际值
2. `efadv_get_max_rq_depth()` — 返回 `max_recv_sge`

两个都可以加到同一 dump 里但**不建议和本 PR 混**：先拿到 `efadv_device_attr` 基础数据，再看维护者是否愿意上 follow-up。
