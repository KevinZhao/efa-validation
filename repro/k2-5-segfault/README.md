# K2.5 segfault 复现环境（p5 H100 + V4-Flash + uccl .3）

## 目的
复现客户现场 segfault：
- 镜像 `public.ecr.aws/n3l4x8f3/sglang-mooncake-uccl:2026.04.28-h200.3`
- PD-disagg 1P1D，rate=4，2K-in / 1K-out，128 prompts

## 相对客户 compose 的最小改动（parser 与模型除外一律 1:1）
1. `image` 保留 `.3`
2. `--model-path` 指向节点 `/data/models/DeepSeek-V4-Flash`（客户原为 `/models/model`，volume 映射后容器内仍是 `/models/model`）
3. `--tool-call-parser deepseekv3`（客户 `kimi_k2`）
4. `--reasoning-parser deepseek-v3`
5. prefill 去掉 `--enable-multimodal --mm-enable-dp-encoder`（V4-Flash 是纯文本）
6. **decode 新增** `--disaggregation-bootstrap-addr <prefill-host>:30081`（sglang PD-disagg 需要）
   — 客户 compose 没写，客户现场肯定有外部编排；我们用 docker-compose 必须显式

## 布局
- P 节点：i-09db88a9ef4b704de / 10.0.11.5 — `prefill/docker-compose.yml`
- D 节点：i-0f93a804d2c034881 / 10.0.11.215 — `decode/docker-compose.yml`
- Router：和 P 共节点（CPU 容器，sglang-router 官方）— `router/docker-compose.yml`
- 入口：http://10.0.11.5:38000 → router → {prefill:30081, decode:30082}

## EFA 差异
客户：p5en 16 rail `rdmap{110-113,135-138,160-163,85-88}s0`
p5 :   8 rail  `rdmap{79-82,96-99}s0`
entrypoint 的 `fi_info -p efa` 自动探测会覆盖默认，用本机 8 rail。

## core dump
节点 `core_pattern=|/usr/lib/systemd/systemd-coredump`，`ulimit -c unlimited`。
容器内 sglang crash → core 捕获到 `/var/lib/systemd/coredump/`。
压测前 `coredumpctl list --since today` 清一次，触发后 `coredumpctl dump <PID>` 取出。

## 压测
```bash
python -m sglang.bench_serving \
  --backend sglang \
  --base-url http://10.0.11.5:38000 \
  --dataset-name random \
  --random-input-len 2048 --random-output-len 1024 \
  --num-prompts 128 --max-concurrency 4 \
  --model /models/model --tokenizer deepseek-ai/DeepSeek-V4-Flash
```
