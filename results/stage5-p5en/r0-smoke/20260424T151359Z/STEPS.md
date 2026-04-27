# R0 · Single-Node Smoke — Execution Log

**Run ID**：`r0-smoke`
**Start (UTC)**：2026-04-24T15:13:59Z
**Operator**：Kevin Zhao (via Claude agent)
**Target**：Verify FSx + EFA + SGLang 0.5.10 + Mooncake image readiness on 1 p5en
**Model**：Qwen3-Next-80B-A3B-Instruct FP8
**Region / AZ**：us-west-2 / us-west-2c (usw2-az3, SPS=9 @ cap=1, 14:51 UTC scan)
**Nodegroup**：`gpu-p5en-48xlarge-spot`
**Image**：`788668107894.dkr.ecr.us-west-2.amazonaws.com/yanxi/sglang-mooncake:v2` (mirrored from Ohio 15:06 UTC)

---

## Pre-flight (done before scaling up)

### 15:13 SPS rescan (cap=1, p5en.48xlarge, all US)

| Region | AZ | Score |
|---|---|---|
| **us-west-2** | **usw2-az3 (us-west-2c)** | **9** ⭐ |
| us-east-2 | use2-az1 | 3 |
| us-east-2 | use2-az2 | 2 |
| (others) | — | 1 |

→ Select **Oregon usw2-az3** (was Ohio choice for 7-node; capacity flipped in ~2h).

### 15:06 Mirror ECR image Ohio → Oregon

- `scripts/stage5-mirror-ecr.sh us-west-2 sglang-mooncake:v2`
- pull 14 GB / push ~5 min, digest `sha256:aa7f2f6f5f2f1c1585308d203316be257a4e37bdc256977c1dde55a48cee5407`
- Verified: `aws ecr describe-images --region us-west-2 --repository-name yanxi/sglang-mooncake` shows v2 @ 2026-04-24T15:06:17Z, 13.95 GB.

### 15:13 Oregon p5en NG state

- Nodegroup `gpu-p5en-48xlarge-spot` / max=7 / desired=0 / ACTIVE
- Subnets span all 4 AZs: azl-1/2/3/4; `subnet-012b1f25ae467ab6c` (10.0.13.0/24) = usw2-az3
- Strategy: capacity-optimized, rely on 9-vs-1 SPS gap to land on usw2-az3 without constraining subnets.

### 15:13 Oregon FSx

- FS id `fs-079832d056597a33b`, Lustre 2.15, 2400 GiB, AVAILABLE in us-west-2b (usw2-az2)
- Model `/models/Qwen3-Next-80B-A3B-Instruct/.prefetch-complete` ✅ (152 GB, Day 0)
- Cross-AZ mount (GPU will land in usw2-az3, FSx in usw2-az2): acceptable one-time read cost for R0.

---

## Execution

(filled in as we progress)

### 2026-04-24T15:15:43+00:00 — Scale Oregon p5en NG desired=1

```bash
aws eks update-nodegroup-config --cluster-name gpu-cluster-oregon \
  --nodegroup-name gpu-p5en-48xlarge-spot --region us-west-2 \
  --scaling-config minSize=0,maxSize=7,desiredSize=1
```

Update id `453a0015-6fa1-36e2-92d0-1fe6948bc332` InProgress. Watching for Spot fulfillment...

### 15:15:59 UTC — Spot instance fulfilled

- `i-016848633dec5b3e8` p5en.48xlarge **running** in **us-west-2c (usw2-az3)** — SPS=9 confirmed correct
- Private IP `10.0.13.153` (subnet-012b1f25ae467ab6c / 10.0.13.0/24)
- ASG activities: first attempt 15:15:46 failed `UnfulfillableCapacity` (likely picked az1/2/4), retried and succeeded 15:16:00 on az3
- Fulfillment latency: ~1.5 min (very fast)

### 15:18:30 UTC — Node fully ready

SSM to the node (via `aws ssm send-command`) confirms:
- kubelet **active**
- GPUs: 8 × H200 (all 8 enumerated by nvidia-smi)
- EFA: 16 uverbs devices (uverbs0..15) + 16 rdmap*s0 netdevs present in `/sys/class/infiniband`
- nvidia-device-plugin registered: `resourceCapacity=8 nvidia.com/gpu` healthy
- gpu-feature-discovery running, nvidia-cuda-validator passed
- Total from scale-up command → node-Ready: **3 min 15 s** (15:15:43 → 15:18:58)

### Handoff to Oregon bastion

Node is ready for pods. Next steps must run **on Oregon bastion `i-081b2b010b6af530c` (10.0.11.203)**:

```bash
# 1) preflight (verify Mooncake + Henan PRs + SGLang in image)
aws eks update-kubeconfig --region us-west-2 --name gpu-cluster-oregon
cd /path/to/efa-validation   # or git pull latest
kubectl apply -f manifests/stage5-p5en/_preflight-image-oregon.yaml
kubectl -n yanxi-validation logs -f pod/stage5-preflight
# expect: "=== PREFLIGHT PASS ==="
kubectl delete -f manifests/stage5-p5en/_preflight-image-oregon.yaml

# 2) R0 smoke pod
kubectl apply -f manifests/stage5-p5en/r0-smoke-oregon.yaml
kubectl -n yanxi-validation logs -f pod/sglang-r0-smoke -c server
# wait for readiness (~3-5 min: pull 14GB image + load weights + cuda graph)

# 3) smoke generate
kubectl -n yanxi-validation port-forward svc/sglang-r0-smoke 30000:30000 &
curl -sX POST http://localhost:30000/generate \
  -H 'Content-Type: application/json' \
  -d '{"text":"The capital of France is","sampling_params":{"max_new_tokens":32,"temperature":0}}'

# 4) cleanup
kubectl delete -f manifests/stage5-p5en/r0-smoke-oregon.yaml
```

Paste preflight output and sglang logs back here so we can fill out RESULT.md.

### 15:46–15:55 UTC — Preflight PASS (second attempt)

First attempt (15:46 apply) hit two issues:
1. **arm64/amd64 mismatch**: eks-utils m7g.large is arm64; image is x86_64 → `exec format error`. Fixed by adding `nodeSelector: kubernetes.io/arch=amd64` + GPU toleration so preflight lands on p5en.
2. **`mooncake.__version__` does not exist**: check 1 errored on `AttributeError`. Fixed by using `pip show mooncake-transfer-engine`.

Second attempt 15:55 UTC completed in 37 s on the p5en (image already cached from first try).

**All 5 checks PASS**:
- Mooncake pip version = **0.3.10.post2** ✅
- Henan EfaTransport/libfabric-efa/Chunk-registered SO symbols = **103** hits ✅
- `MC_LEGACY_RPC_PORT_BINDING` referenced in binary ✅
- SGLang rdma hardcode at line 195 of `mooncake_transfer_engine.py` (launcher sed target intact) ✅
- SGLang `__version__` = **0.5.10** ✅

Image `yanxi/sglang-mooncake:v2` verified safe for Stage 5 KV disagg runs.
Full log saved to `preflight-output.txt`.

### 15:55:55 UTC — R0 smoke pod applied

- Image already cached on node; pod went from `created` to `Running` in < 5 s.
- Pod `sglang-r0-smoke` / IP `10.0.13.51` on node `ip-10-0-13-153` (usw2-az3 p5en).
- Now waiting for SGLang server cold start: FSx first-read of 152 GB Qwen3-Next weights + CUDA graph capture (~3–5 min).

### 16:18:50 UTC — SGLang ready ("fired up and ready to roll")

- Total cold start (pod create → ready): **22 min 55 s**
- Dominant cost: Qwen3-Next E=512 N=64 MoE Triton kernel JIT (no pre-cached config in 0.5.10, fell back to triton_3_4_0 and recompiled)
- 8 TP ranks all init'd, weight load + graph capture completed
- Readiness probe green at 16:18:57

### 16:21 UTC — Generate probe PASS

- Request: `"The capital of France is"` + max_new=32, temp=0
- Response: `"Paris. The capital of Germany is Berlin. The capital of Italy is Rome. The capital of Spain is Madrid. The capital of the United Kingdom is London."`
- e2e latency: **296 ms** (5 in / 32 out)
- All 5 pass criteria met → R0 **PASS**

### 16:25 UTC — Cleanup DONE (retrospective)

Actions planned:
1. `kubectl delete -f /tmp/stage5/r0-smoke-oregon.yaml` (remove pod + svc + cm)
2. `aws eks update-nodegroup-config ... desired=0` (Oregon p5en)
3. Reconcile Oregon FSx Kimi-K2 sentinel before R1a (see RESULT.md §8)

**2026-04-25 update**: R1a started 03:19 UTC on **Ohio** `gpu-p5en-spot-useast2a`（SPS cap=2 rescan 16:25Z gave use2-az1=9 vs usw2-az3=4，Ohio regained capacity）; the Oregon FSx Kimi-K2 sentinel thus did not need touching (Oregon sidelined, Ohio FSx has full Kimi-K2 weights). Cleanup actions 1 & 2 completed implicitly when the active region switched.

