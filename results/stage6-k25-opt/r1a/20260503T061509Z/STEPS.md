# Stage 6 R1a — Step-by-step timeline (UTC)

All operations executed from local operator box via `aws ssm send-command` to bastion `i-081b2b010b6af530c` (private VPC, no SSH).

## Preflight
- `2026-05-03 06:10Z` SPS p5en.48xlarge in us-west-2: usw2-az3=9 (picked), usw2-az4=7, usw2-az2=1, usw2-az1<1.
- Existing NG `gpu-p5en-48xlarge-spot` is DEGRADED (ASG drift to az4 only) → do not reuse.
- S3 weights confirmed: 85 objects / 595 GB at `s3://yanxi-validation-788668107894-oregon/models/moonshotai/Kimi-K2.5/`.
- Namespace `yanxi-validation` empty of running pods; baseline ConfigMaps still exist (informational).
- GO recorded in `PREFLIGHT.md`.

## Step 1 — Create NG
- `06:18:50Z` SSM to bastion: `aws eks create-nodegroup --nodegroup-name gpu-p5en-48xlarge-spot-az3 --subnets subnet-012b1f25ae467ab6c --capacity-type SPOT --scaling-config minSize=0,maxSize=2,desiredSize=2` with LT `lt-0ac44b91768cce758` v3, IAM `GPUNodeRole-gpu-cluster-oregon`, taint `nvidia.com/gpu=true:NO_SCHEDULE`, labels `stage=stage6-r1a`.
- `06:18:54Z` NG created, status=`CREATING`, ARN=`arn:aws:eks:us-west-2:788668107894:nodegroup/gpu-cluster-oregon/gpu-p5en-48xlarge-spot-az3/9acef63e-aede-c5f5-04ce-05aa8c9e20c0`.

## Step 2 — Wait NG ACTIVE + 2 Ready
- Polled every ~60s via SSM.
- `06:21:40Z` NG status=`ACTIVE`, both nodes Ready (3 min wallclock). Nodes:
  - `ip-10-0-13-158.us-west-2.compute.internal` (aws://us-west-2c/`i-07fbeaa8eeb68df00`)
  - `ip-10-0-13-56.us-west-2.compute.internal`  (aws://us-west-2c/`i-019c908531879f537`)
- Both in `us-west-2c` (= usw2-az3). Same-AZ requirement met.

## Step 3 — Prefetch weights + image (parallel on both nodes)
- `06:22:38Z` Launched `s5cmd cp` (concurrency 64) + background `nerdctl -n k8s.io pull` on each node via SSM (async, nohup).
- `06:34:00Z` Both nodes: `s5cmd` exited cleanly (263 lines in `/var/log/stage6/prefetch.log`), 85 files / 555 GB present. However the `touch $SENT` never ran (shell-quoting issue inside nested SSM `"commands=[]"`).
- Node `i-019c908531879f537`: first `nerdctl pull` attempted at 06:22 failed with `containerd.sock connection refused` (containerd not fully up at userdata stage). Re-triggered at `06:35:45Z`; completed at `06:39:19Z`.
- `06:35:45Z` Manually `touch /data/models/moonshotai/Kimi-K2.5/.s3-prefetch-done` on both nodes after confirming S3 = 87 non-sentinel keys and local = 85 files (2 trivial non-load-bearing items missing: `.cache/` empty dir + `.gitattributes` which is tiny; actually re-pulled `.gitattributes` in the same fixup step).
- `06:39:19Z` Both nodes have image `public.ecr.aws/n3l4x8f3/sglang-mooncake-uccl:2026.05.02-h200.dp16` (`e49aacc84685`, 11.19 GB compressed / 22.48 GB on disk) and sentinel written. Idempotent for R1b.

## Step 4 — Apply R1a manifest
- `06:19:15Z` (pre-staged during Step 2 wait) Shipped `k25-1p1d-r1a-opt.yaml` to bastion `/root/stage6/` via base64+SSM. SHA256 verified identical to local (`26eb152a44af926b9731a0ce8f7e9eb8be48d599235933433b6794fb963eb1c2`).
- `06:39:47Z` `kubectl apply` on bastion created: ConfigMap `k25-r1a-opt-launcher`, Services `k25-r1a-prefill / -decode / -lb`, Deployments `k25-r1a-prefill / -decode / -lb` (all 1 replica).
- Pods scheduled: prefill+LB on `ip-10-0-13-56`, decode on `ip-10-0-13-158` (podAntiAffinity only guards the `app=k25-r1a` group, so LB is free to co-locate with prefill).

## Step 5 — Wait pods Ready
- Polled every ~30s via SSM.
- `06:51Z` Prefill + LB `1/1 Running`.
- `06:59:43Z` Decode app startup complete (8 tokenizer workers + main server).
- `07:00:17Z` All three pods `1/1 Running Ready`. Coldstart ~20 min (matches expected 15-20 min).

## Step 6 — Smoke prime (2K/256)
- `07:01:23Z` `python3 -m sglang.bench_serving --random-input-len 2048 --random-output-len 256 --num-prompts 8 --max-concurrency 4 --warmup-requests 2` exec'd via prefill pod against `http://k25-r1a-lb.yanxi-validation.svc:8000`.
- `07:02:25Z` PASSED. 8/8 complete. TTFT mean=718.65 ms, median=705.64 ms. ITL mean=11.78 ms. Router primed.

## Step 7 — S2 bench, 3 rounds
- Each round: `--random-input-len 8192 --random-output-len 1024 --num-prompts 200 --max-concurrency 64 --warmup-requests 20`. Same pod exec pattern.
- R1 `07:02:46 → 07:06:03Z` (duration 183.97 s, 200/200, TTFT mean 3537.59 ms, ITL mean 103.11 ms, out 538.8 tok/s). SSM command exit=Failed due to stdout truncation past limit and/or trailing `kubectl cp` failing, but the bench itself completed; JSON `/tmp/s2-r1a-r1.json` (1407 bytes) is intact inside the prefill pod.
- R2 `07:06:34 → 07:10:12Z` (duration 183.85 s, 200/200, TTFT mean 3241.31 ms, ITL mean 103.50 ms, out 539.2 tok/s). Same SSM truncation pattern.
- R3 `07:10:22 → 07:14:00Z` (duration 186.13 s, 200/200, TTFT mean 3210.13 ms, ITL mean 105.15 ms, out 532.6 tok/s).
- `07:16Z` Recovered all 3 JSONs from the pod via `kubectl exec P -- cat /tmp/s2-r1a-r{1,2,3}.json` on the bastion, parsed locally into `raw/s2-r1a-r{1,2,3}.json` + `raw/summary.json`.

## Step 8 — Write RESULT.md / STEPS.md + S3 mirror
- Local: `results/stage6-k25-opt/r1a/20260503T061509Z/{RESULT.md,STEPS.md,raw/*,logs/*,ssm/*}`.
- S3 mirror: (to be run in same step) `aws s3 sync results/stage6-k25-opt/r1a/20260503T061509Z/ s3://yanxi-validation-788668107894-oregon/results/stage6-k25-opt/r1a/20260503T061509Z/`.

## Step 9 — Leave cluster alive
- NG `gpu-p5en-48xlarge-spot-az3` kept at desired=2.
- Deployments `k25-r1a-*` kept Running.
- ConfigMap + Services kept.
- Ready for R1b (apply its own manifest in the same namespace with distinct names, as the R1a manifest header advertises: R1a and R1b coexist).

## SSM command cheat-sheet (for audit)

All SSM commands are `aws ssm send-command --document-name AWS-RunShellScript --instance-ids <bastion-or-node>`.

| Step | Command IDs (short) | Target | Comment |
|---|---|---|---|
| 1 | `ce627ac4` | bastion | create-nodegroup |
| 2 | (many, 1-3) | bastion | poll describe-nodegroup + kubectl get nodes |
| 3 | `93d6991c` / `1eb4a866` | nodes | prefetch launch (async) |
| 3 fixup | `763da776` / `a01af071` | nodes | sentinel + image re-pull |
| 4 pre-stage | `0eafb8c9` | bastion | ship manifest base64 |
| 4 apply | (inline) | bastion | kubectl apply |
| 5 | (many poll) | bastion | kubectl get pods |
| 6 | `02369d6a` | bastion | 2K/256 smoke |
| 7 R1/R2/R3 | `d1fde23e` / `cf4e7403` / `5ae1fab1` | bastion | 8K/1K × 200 @ cc=64 |
| 7 extract | (final) | bastion | kubectl exec -- cat JSON |

All raw SSM stdout/stderr captured under `ssm/` and `logs/`.

---

## R1a0 sub-run (L5 ablation on top of R1a)

**Goal**: remove `SGLANG_MOONCAKE_CUSTOM_MEM_POOL`, `FI_EFA_ENABLE_SHM_TRANSFER`, `FI_EFA_FORK_SAFE` from `k25-r1a-prefill` and `k25-r1a-decode`. Keep every other env + same image + same nodes. Rerun S2 × 3.

### Step R1a0.1 — Verify state (07:20Z)

SSM `8862de13...` returned all 3 pods Running, 2 nodes Ready (us-west-2c). Proceed.

### Step R1a0.2 — Dump + filter deployments (07:24Z)

SSM `414013ed...` ran a small bash/python script on the bastion that:
1. `kubectl get deploy ... -o yaml` to `/root/stage6/r1a0/<deploy>-current.yaml`
2. Python filter removed 3 env names from container[0].env, stripped `status`/`resourceVersion`/`uid`/`generation`/`creationTimestamp`/`managedFields`
3. `kubectl apply -f <deploy>-noL5.yaml` — both returned `deployment.apps/<name> configured`
4. env count dropped 33 → 30 per container for both prefill and decode; removed list = `['SGLANG_MOONCAKE_CUSTOM_MEM_POOL', 'FI_EFA_ENABLE_SHM_TRANSFER', 'FI_EFA_FORK_SAFE']`

### Step R1a0.3 — Switch rollout strategy to Recreate (07:26Z)

Initial rolling update stuck at `Waiting for 1 old replicas are pending termination` — the new pod couldn't be scheduled because the old pod held all 8 GPUs on each node (no spare GPU room on this 2-node cluster). SSM `81481f97...` patched `spec.strategy` to `Recreate`. Old pods terminated; new pods scheduled on the same nodes (hostPath cache + image cache → no re-prefetch, no re-pull).

### Step R1a0.4 — Wait pod Ready

- Prefill Ready at ~07:36:40Z (11 min coldstart).
- Decode Ready at 07:41:32Z (16 min; the longer decode side is consistent with R1a's 20-min decode coldstart).

SSM polls `eef718cb...` + `471e8dee...` confirmed 1/1 Ready for both, pod IDs changed (as expected from Recreate).

### Step R1a0.5 — Env sanity + smoke prime + 3× S2 bench (07:42-08:04Z)

Launched a single nohup bench script via SSM `30124864...`:
```
/tmp/r1a0-bench.sh >/root/stage6/r1a0/bench-run.log
```
The script:
1. Grepped `env | grep -E "MOONCAKE_CUSTOM_MEM_POOL|FI_EFA_ENABLE_SHM|FORK_SAFE"` inside prefill pod → empty (confirmed removal).
2. Smoke 2K/256 × 8 @ cc=4 → TTFT mean 775.53 ms, ITL mean 9.51 ms. Pass.
3. R1 S2 8K/1K × 200 @ cc=64 warmup=20 → 401.85s duration.
4. R2 → 402.24s.
5. R3 → 401.22s.

All 3 rounds saved JSON to `/tmp/s2-r1a0-r{1,2,3}.json` inside prefill pod, then `kubectl exec -- cat` pulled them to bastion `/root/stage6/r1a0/raw/`.

### Step R1a0.6 — Ship artifacts to local + S3

`aws s3 sync /root/stage6/r1a0/ s3://yanxi-validation-788668107894-oregon/tmp/r1a0-transit/` on bastion → `aws s3 cp` specific files back to local workstation into `results/stage6-k25-opt/r1a/20260503T061509Z/{raw,logs,ssm}/`.

### Step R1a0.7 — Analyze

Python inline computed 3-round means. Appended a new "R1a0" section to RESULT.md with three-way comparison table (Stage 5 baseline / R1a / R1a0) and verdict. See RESULT.md § "R1a0 — L5 ablation".

### Step R1a0.8 — Cluster left alive

- Deployments `k25-r1a-prefill / -decode / -lb` still Running with 30-env (no-L5) config. `Recreate` strategy retained (safe for R1b which uses a different deployment name).
- NG `gpu-p5en-48xlarge-spot-az3` still at desired=2, both nodes Ready.
- Weights + image still cached on both nodes → R1b coldstart will reuse.

**Caveat for R1b**: current running pods have `Recreate` + no L5 envs. If R1b reuses these pods or stacks on top of the same manifest, it inherits the L5-off state. Since R1a0 shows L5 is protective, R1b should re-enable L5 (revert to the original R1a manifest) OR apply R1b's own manifest which per MEMORY has its own naming (`k25-r1-*`) so coexists and carries its own env config.

### SSM command IDs for R1a0

| Step | Command ID | Purpose |
|---|---|---|
| verify | `8862de13-0748-463a-b89b-4977e941ad94` | pods + nodes |
| env list | `1315ea6e-4b01-4b78-b84c-c332ee2d3d3c` | count env vars |
| patch | `414013ed-54d9-4766-9663-b2f18cb0595d` | remove L5 + apply |
| strategy | `81481f97-d3af-4b36-bfd5-fd3acacab17e` | Recreate |
| rollout wait | `80162e90-3617-41c1-91c4-2f65e6a85bc0` | (timeout 20m each) |
| pod checks | `eef718cb...`, `471e8dee...` | readiness polls |
| bench | `30124864-1ec5-49d6-9a7c-d90cb71d03a5` | nohup full run |
| progress | `4b68fd80...`, `e8c43795...`, `2e379df8...`, `703b78fa...`, `cee1e77c...` | tail reads |
| JSON pull | `22be71f9...` | cat JSONs |
| S3 sync | `aeea8990-9d2a-40d7-933b-c1251427b2c0` | /root/stage6/r1a0 → s3://.../tmp/r1a0-transit |

