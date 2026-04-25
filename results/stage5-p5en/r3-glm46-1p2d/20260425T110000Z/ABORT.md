# R3 · GLM-4.6-FP8 1P:2D on 3 × p5 (Oregon) — Cold start PASS, bench warmup FAIL

**Run ID**: `r3-glm46-1p2d`
**Start (UTC)**: 2026-04-25T10:30Z
**Region / AZ**: us-west-2 / usw2-az1 + az2 + az3 (distributed across 3 AZ)
**Model**: `zai-org/GLM-4.6-FP8` (355B MoE, 160 experts top-8, GLM-MoE arch, ~370 GB FP8)
**Image**: `788668107894.dkr.ecr.us-west-2.amazonaws.com/yanxi/sglang-mooncake:v5`
**Weights**: `hostPath: /data/models/GLM-4.6-FP8` on each p5 node (auto-striped `/data` via vg_local LVM from LT userdata)
**Manifest**: `manifests/stage5-p5en/r3-glm46-1p2d-v5-hostpath-oregon.yaml`

## Key facts

### Context: why R3, not R4
R4 (Qwen3-235B-A22B-FP8) was attempted first but failed immediately in sglang 0.5.10:
```
ValueError: The output_size of gate's and up's weight = 192 is not
divisible by weight quantization block_n = 128.
```
Root cause: Qwen3-235B-A22B-FP8 has `moe_intermediate_size=1536`, so per-TP-rank at TP=8 is 192, and 192 % 128 ≠ 0. This is a known mis-alignment in sglang 0.5.10's block-FP8 fused MoE for Qwen3-235B on TP=8. Workarounds would be TP=4 (wastes GPUs) or wait for upstream fix.

Switched to R3 GLM-4.6-FP8 (also `moe_intermediate_size=1536`, but GLM-MoE arch + compressed-tensors FP8 quant — no block alignment constraint).

### Infra discovery (new)
- Oregon cluster `gpu-cluster-oregon` p5 NG Launch Template v4 **already uses the new userdata from `KevinZhao/eks-cluster-deployment`** with `GPU_ENABLE_LOCAL_LVM=true`:
  - 7 × 3.5 TB NVMe instance-store stripped to `vg_local/lv_scratch` → `/data` (27.6 TB xfs) at boot
  - 1 × 3.5 TB (nvme1) taken by `vg_data/lv_containerd` for containerd root
  - No manual `setup-nvme.sh` needed — saved us ~15 min setup
- Memory `reference_eks_gpu_node_deploy_repo.md` now confirmed accurate; Ohio LT `lt-0200be32f4401a715 v1` is still the old variant that needs manual mdadm.

### Prefetch
- `_prefetch-hf-qwen3-235b-oregon.yaml` (before switching) and `_prefetch-hf-glm46-oregon.yaml` both hit parallel HF CDN from 3 Oregon p5 nodes; completed in ~8-10 min.

### Cold start
- All 3 p5 pods reached 1/1 Ready within ~12 min from apply (weight load from local NVMe + Mooncake EFA bringup).
- EFA devices enumerated correctly: `libfabric efa provider (shared endpoint, max_wr=256)`, 16 NICs per pod × 3 pods.
- Used `CompressedTensorsW8A8Fp8MoE` quant kernel — compatible with GLM-4.6-FP8.

### Bench warmup FAIL (3 attempts)
- **Attempt 1** (11:00Z): Warmup single-request failed with `ClientPayloadError: TransferEncodingError: Not enough data to satisfy transfer length header`. At that time, sglang-r3-lb pod had been **evicted** due to node-B ephemeral-storage pressure (`The node was low on resource: ephemeral-storage. Threshold: 5.3 GB, available: 80 Ki`).
- **Attempt 2** (11:08Z): decode-0 pod was also evicted once, re-scheduled and eventually Ready. All 4 pods 1/1 Ready.
- **Attempt 3** (11:26Z): Warmup still failed with same `TransferEncodingError`. LB pod this time is Running, prefill shows it received the first `Prefill batch #new-seq: 1`, but bench client sees connection dropped mid-stream.

### Suspected root causes
1. **Cross-AZ Mooncake KV transport** — 3 pods on 3 different AZs (usw2-az1/2/3). Same Kimi-K2 FSx cross-AZ problem in spirit; untested for in-pod Mooncake KV transfer. The first prefill batch handoff to decode over cross-AZ EFA may be hanging, causing LB to timeout the client.
2. **Ephemeral-storage pressure recurring** — node-B had 80 Ki left at one point. sglang-router pod occasionally pulls `sglang-router==0.3.2` at startup (300 MB pip), plus logs + tmp files, can trigger eviction on slim node root disk. Root disk on p5 LT is 100 GB EBS (`nvme2n1` → `vg_data`), but `/var/log`, `/var/lib/containerd` (image layers), `/tmp`, and pod log files all eat into it.
3. **Readiness probe lies** — getting 1/1 Ready on `/get_model_info` doesn't guarantee the prefill→decode KV path is established. Stage 4 tested 1P:2D with same-AZ p5en, so we never saw cross-AZ breakage.

## What got captured

- `r3-glm46-1p2d-v5-hostpath-oregon.yaml` — deployed manifest (committed)
- `_prefetch-hf-glm46-oregon.yaml` — prefetch Job (committed)
- No valid bench summary produced.

## Next (parked for next session)

1. **Force 3 pods into the same AZ** — set NG subnets to only one subnet (e.g. usw2-az2) → re-bring up 3 p5 → re-apply R3. This replicates Stage 4 topology and should unblock Mooncake KV.
2. **Increase LB pod ephemeral-storage requests** — add `resources.requests.ephemeral-storage: 2Gi` + bake `sglang-router` into the image to avoid the pip install on boot.
3. Alternately, **wait for p5en recovery** (currently SPS=1 everywhere), then restart R1b on p5en (Stage 4-proven same-AZ topology).

## Lessons to memory

- Cross-AZ same-region EFA between pods may work for generic traffic but **Mooncake KV handshake is untested cross-AZ**; default to single-AZ topology for PD-disaggregation runs.
- Ephemeral-storage pressure on GPU nodes is a real eviction source; size requests for the LB pod.
- H100-80GB p5 is fine for models ≤ 340 GB FP8 but **cannot run Kimi-K2 (959 GB)** even at TP=8 (120 GB/rank > 80 GB).
- Qwen3-235B-A22B-FP8 needs sglang ≥ X for TP=8 block-FP8 MoE (need to check upstream fix).
