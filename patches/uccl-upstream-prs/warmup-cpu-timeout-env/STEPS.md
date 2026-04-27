# Warm-up PR: UCCL_EP_CPU_TIMEOUT_SECS — 执行步骤

**日期**：2026-04-25
**目标**：向 `uccl-project/uccl` 提交首个贡献 PR，建立和维护者的沟通
**分支**：`ep-warmup-cpu-timeout-env` (local)

---

## 已完成

- [x] **2026-04-25**：在本地 `/home/ec2-user/workspace/uccl` HEAD `f1ecbaf7` 基础上创建 branch
- [x] 在 `ep/src/uccl_ep.cc` 加 `get_cpu_timeout_secs()` helper + 替换 2 处调用点
- [x] `clang-format-14 --dry-run --Werror ep/src/uccl_ep.cc` 通过（0 diff）
- [x] `black ep/ --exclude "thirdparty|docs|build" --check` 通过
- [x] Patch 保存到 `patches/uccl-upstream-prs/warmup-cpu-timeout-env/0001-ep-cpu-timeout-env.patch`
- [x] PR body 保存到 `patches/uccl-upstream-prs/warmup-cpu-timeout-env/PR_BODY.md`
- [x] **2026-04-25**：Fork `uccl-project/uccl` → `KevinZhao/uccl`
- [x] **2026-04-25**：Branch push 到 fork，commit `0ce1a22f`
- [x] **2026-04-25**：**PR 已开：https://github.com/uccl-project/uccl/pull/904**
- [x] **2026-04-25**：设计 review 后追加改进 commit `a7eb743e`：
  - Helper 移到 `common.hpp`（对齐 `get_max_inflight_*` 惯例）
  - `atoi` → `strtol` + 明确 warning
  - PR body v2 更新（去掉虚标 build/smoke test，诚实标为 pending）
  - README 文档更新暂不做（等代码 review 定稿后追加）

---

## 待完成

### 1. Fork 和本地 remote 配置（1 个命令）
```bash
# 在 github.com/uccl-project/uccl 点 Fork 到团队账号
# 本地添加 fork remote（替换 <YOUR-FORK>）
cd /home/ec2-user/workspace/uccl
git remote add fork https://github.com/<YOUR-FORK>/uccl.git
git remote -v
```

### 2. Build 验证（需要 GPU 节点）

不能在 CPU-only 的工作机上做，需要 ssh 到 Ohio bastion 再 kubectl exec 到 p5en pod：

```bash
# Ohio bastion
cd /opt/uccl  # 或者 git clone fork
git fetch origin ep-warmup-cpu-timeout-env  # 先推到 fork
git checkout ep-warmup-cpu-timeout-env
bash build.sh cu12 ep --install
python3 -c "import uccl.ep; print('OK')"
UCCL_EP_CPU_TIMEOUT_SECS=600 python3 -c "import uccl.ep; print('env OK')"
```

### 3. 微测试 (p5en 2 节点 EP=16)
```bash
# 确认 test_low_latency.py 在 warm-up patch 下无性能回归
cd /opt/uccl/ep
torchrun --nnodes=2 --nproc_per_node=8 --node_rank=0 \
    --master_addr=<ip0> --master_port=12355 \
    bench/test_low_latency.py --num-tokens=128 --hidden=7168 --num-topk=8 --num-experts=288
# 对比 baseline HEAD f1ecbaf7 的 dispatch/combine latency 是否 noise 级
```

### 4. 推送到 fork
```bash
cd /home/ec2-user/workspace/uccl
git add -A
git commit -m "$(cat <<'EOF'
[EP] Allow runtime override of CPU recv timeout via UCCL_EP_CPU_TIMEOUT_SECS

The CPU recv timeout was a compile-time constant (NUM_CPU_TIMEOUT_SECS),
which false-triggers during long Megatron training steps. Add an env var
override so users can widen the window without rebuilding.

Preserves existing behavior when the env is unset or non-positive.

Addresses #893 (timeout knob request) and #878 (similar symptoms).
EOF
)"
git push fork ep-warmup-cpu-timeout-env
```

### 5. 开 PR
- GitHub UI 点 Compare & pull request
- Title: `[EP] Allow runtime override of CPU recv timeout via UCCL_EP_CPU_TIMEOUT_SECS`
- Body: 粘贴 `PR_BODY.md` 内容
- 请求 reviewer: `@MaoZiming @YangZhou1997`
- 添加 label: 目前无 `bug` 可加，维护者通常会自己加

### 6. 跟进
- 1-3 天内观察 CI 绿 + review comments
- MaoZiming 可能要求补文档 / 改 env 命名 / 加测试
- 目标：3-7 天合入

---

## 成功标准
- [ ] PR merged to `uccl-project/uccl` main
- [ ] Issue #893 的 timeout 部分 resolve
- [ ] 建立和 MaoZiming / YangZhou1997 的沟通渠道（为后续 P0 PR 铺路）
