# Sanitization Report: YanxiInference

**Date:** 2026-04-21
**Auditor:** opensource-sanitizer v1.0.0
**Verdict:** FAIL

---

## Summary

| Category | Status | Findings |
|----------|--------|----------|
| Secrets / Credentials | PASS | 0 findings |
| AWS Account ID (788668107894) | FAIL | 96 occurrences across 60+ files |
| PII — Personal Names | FAIL | 9 named individuals in 1 file |
| PII — Private IPs (10.1.12.x) | FAIL | 30+ occurrences across 5 files |
| Internal Infra — EC2 Instance IDs | FAIL | 3 instance IDs across 4 files |
| Internal Infra — VPC/Subnet/SG/AMI IDs | FAIL | 16+ resource IDs across 2 files + 2 encoded payloads |
| Internal Infra — Node Hostnames | FAIL | 2 hostnames with embedded IPs across 10 files |
| Customer Identity — JD/京东/言犀/JoyAI | FAIL | Pervasive across 3 files |
| Confidentiality Marker | FAIL | "AWS Internal" classification in 1 file |
| Git History | PASS | No git history (0 commits) |
| Dangerous Files | PASS | No .env, .pem, credentials.json, etc. |
| Config Completeness | N/A | No .env.example; project is infra scripts, not an app |

---

## Critical Findings (Must Fix Before Release)

### [1] AWS Account ID — 788668107894

Appears **96 times** across 60+ files as part of ECR image URIs and the S3 bucket name. This is the single highest-density finding. Every file in the list below must have `788668107894` replaced with a placeholder such as `<AWS_ACCOUNT_ID>`.

**ECR URI pattern to replace:**
`788668107894.dkr.ecr.us-east-2.amazonaws.com` → `<AWS_ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com`

**S3 bucket name to replace:**
`yanxi-validation-788668107894` → `yanxi-validation-<AWS_ACCOUNT_ID>`

Selected representative file:line references (full list is every file that contains this string):

- `validation/RUNBOOK.md:50–53` — ECR repo table
- `validation/RUNBOOK.md:59` — S3 bucket
- `validation/scripts/lib.sh:18,24` — hardcoded in shell constants
- `validation/common/Dockerfile.nccl-tests-v2:4` — ARG default
- `validation/common/Dockerfile.uccl-ep:11` — ARG default
- `validation/common/Dockerfile.mooncake-nixl:26` — ARG default
- `validation/common/Dockerfile.sglang-mooncake:17` — ARG default
- `validation/stage1-nccl-tests/mpijob-nccl-tests.yaml:28,136`
- `validation/stage2-uccl-ep/mpijob-correctness.yaml:207,367`
- `validation/stage2-uccl-ep/mpijob-perf-uccl.yaml:45,184`
- `validation/stage2-uccl-ep/mpijob-perf-nccl.yaml:41,180`
- `validation/stage2-uccl-ep/README.md:18`
- `validation/stage2-uccl-ep/mpijob-uccl-upstream.yaml:71,202`
- `validation/stage3-kv/job-mooncake-bench.yaml:48,253`
- `validation/stage3-kv/job-nixl-bench.yaml:54,282`
- `validation/stage3-kv/README.md:38,47,48,87`
- `validation/stage4-e2e/lws-prefill.yaml:51`
- `validation/stage4-e2e/lws-decode.yaml:48`
- `validation/stage4-e2e/lws-baseline-tp8.yaml:38`
- `validation/stage4-e2e/job-bench-serving.yaml:37`
- `validation/stage4-e2e/README.md:38,39`
- `validation/results/stage1/SUMMARY.md:5,54`
- `validation/results/stage2/SUMMARY.md:20,23`
- `validation/results/stage3/SUMMARY.md:38`
- `validation/results/stage4/SUMMARY.md:61`
- `validation/ssm-payloads/push-base-retry.json:4,6,7`
- `validation/ssm-payloads/build-mooncake-nixl-v2.json:9,10`
- `validation/ssm-payloads/build-sglang-mooncake.json:10,11`
- All remaining `ssm-payloads/*.json` files referencing the S3 bucket

**Recommendation:** Replace with environment variable. In Dockerfiles use `ARG AWS_ACCOUNT_ID`. In shell scripts use `${AWS_ACCOUNT_ID}`. In YAML manifests use a kustomize variable or sed substitution at deploy time.

---

### [2] EC2 Instance IDs

Three specific instance IDs for the bastion hosts and builder are hardcoded.

- `validation/RUNBOOK.md:6` — `i-0341d214635c1ca74` (Ohio bastion, in header prose)
- `validation/RUNBOOK.md:29` — `i-081b2b010b6af530c` (Oregon bastion), `i-0341d214635c1ca74` (Ohio bastion)
- `validation/RUNBOOK.md:38` — `i-0f6dc7baf7825b30f` (yanxi-builder)
- `validation/scripts/lib.sh:11` — `i-0341d214635c1ca74`
- `validation/scripts/lib.sh:12` — `i-081b2b010b6af530c`
- `validation/scripts/lib.sh:13` — `i-0f6dc7baf7825b30f`
- `validation/stage4-e2e/README.md:68` — `i-0341d214635c1ca74`
- `validation/RUNBOOK.md:82` — partial `i-0fbc…`, `i-0114…` (GPU worker node IDs, truncated)

**Recommendation:** Replace with `${OHIO_BASTION}`, `${OREGON_BASTION}`, `${BUILDER_ID}` environment variable references everywhere. Remove the hardcoded defaults from `lib.sh` lines 11–13 and document them in `.env.example` instead.

---

### [3] VPC, Subnet, Security Group, and AMI IDs

- `EFA_Validation_Plan.md:39` — `vpc-081ea929da61b21d7` (Oregon VPC)
- `EFA_Validation_Plan.md:40` — `vpc-0bcb622cffd226d26` (Ohio VPC)
- `validation/RUNBOOK.md:19` — `vpc-0bcb622cffd226d26`
- `validation/RUNBOOK.md:20` — `vpc-081ea929da61b21d7`
- `validation/RUNBOOK.md:21` — `subnet-0c86f1c69e4067890`
- `validation/RUNBOOK.md:23` — `sg-067fb33ae2c309f5f`
- `validation/RUNBOOK.md:42` — `ami-03f272c8e6091aa73`
- `validation/RUNBOOK.md:43` — `subnet-06b9c08e3273826ca`

Additionally, the SSM payload files `bastion-push-env-oregon.json:2` and `bastion-push-env-ohio.json:2` contain base64-encoded `.env` blobs. Decoding them reveals **14 additional subnet IDs** for both Oregon and Ohio clusters:

Oregon subnets (private): `subnet-092ec691f375...`, `subnet-034369617...`, `subnet-012b1f25ae...`, `subnet-0e4dc6ed86...`
Oregon subnets (public): `subnet-013039087...`, `subnet-0500247d3...`, `subnet-05056e200...`, `subnet-09d840716...`
Ohio subnets (private): `subnet-06b9c08e32...`, `subnet-0c86f1c69e...`, `subnet-03eb558ae0...`
Ohio subnets (public): `subnet-0ca4bf3832...`, `subnet-063689af6d...`, `subnet-0907bc9982...`

- `validation/ssm-payloads/bastion-push-env-oregon.json:2` — base64 blob encodes 8 subnet IDs + VPC ID
- `validation/ssm-payloads/bastion-push-env-ohio.json:2` — base64 blob encodes 6 subnet IDs + VPC ID

**Recommendation:** Replace all resource IDs with `<VPC_ID_OHIO>`, `<SUBNET_GPU_OHIO>`, `<SG_GPU>`, `<AMI_BUILDER>` placeholders. The base64-encoded env blobs in the SSM payloads must be regenerated from a sanitized `.env.example` template; do not simply redact the base64 string since the raw IDs are trivially recoverable.

---

### [4] Private IP Addresses (10.1.12.x VPC CIDR)

These are live pod/node IPs from the `10.1.12.0/24` GPU subnet.

- `validation/results/stage1/all_reduce_alltoall_20260421T075000Z.log:193–195` — `10.1.12.60`
- `validation/results/stage2/uccl-upstream-full.log:65,72,77,...` (15+ lines) — `10.1.12.180`, `10.1.12.193`
- `validation/results/stage3/mooncake-init.log:184–202` — `10.1.12.192`, `10.1.12.83`
- `validation/results/stage3/mooncake-tgt.log:182–191` — `10.1.12.83`, `10.1.12.192`
- `validation/results/stage3/SUMMARY.md:26` — `10.1.12.64`, `10.1.12.192`
- `validation/logs/stage0-setup/stage1-full-20260421T075000Z.log:193–195` — `10.1.12.60`
- `validation/RUNBOOK.md:21` — subnet CIDR `10.1.12.0/24`

**Recommendation:** The entire `validation/results/` and `validation/logs/` trees are raw execution logs capturing live infrastructure state. **Consider whether to include these logs at all in the public repo.** If kept for reproducibility, scrub IPs with `sed` substitution: replace `10.1.12.\d+` with `<NODE_IP>` throughout all log files.

---

### [5] Node Hostnames Embedding Private IPs

EKS assigns node hostnames of the form `ip-<private-ip>.region.compute.internal`, directly embedding the private IP.

- `validation/ssm-payloads/ohio-check-node-alloc.json:3` — `ip-10-1-12-160.us-east-2.compute.internal`, `ip-10-1-12-221.us-east-2.compute.internal`
- `validation/ssm-payloads/containerd-config.json:3` — `ip-10-1-12-160.us-east-2.compute.internal`
- `validation/ssm-payloads/s4-nodes-inspect.json:7` — `ip-10-1-12-160.us-east-2.compute.internal`
- `validation/ssm-payloads/s4-debug-160.json:3` — `ip-10-1-12-160.us-east-2.compute.internal`
- `validation/ssm-payloads/s4-check-taint160.json:3,4` — `ip-10-1-12-160.us-east-2.compute.internal`
- `validation/ssm-payloads/s4-untaint-160.json:3` — `ip-10-1-12-160.us-east-2.compute.internal`
- `validation/ssm-payloads/s4-verify-models-221.json:3` — `ip-10-1-12-221.us-east-2.compute.internal`
- `validation/ssm-payloads/s4-cat-index.json:1` — `ip-10-1-12-221.us-east-2.compute.internal`
- `validation/stage4-sglang-mooncake/node-cleanup-160.yaml:15` — `ip-10-1-12-160.us-east-2.compute.internal`

**Recommendation:** Replace with `<GPU_NODE_0>` / `<GPU_NODE_1>` and document that users must substitute their own node names. The `node-cleanup-160.yaml` manifest's `nodeName` field hardcodes a node that does not exist in any other deployment; the file should either be generalized or removed.

---

### [6] Customer Identification — JD / 京东 / 言犀 / JoyAI / JoyBuy

`JoyAI_AWS_Report_Final.md` is an AWS-internal customer engagement briefing document. It explicitly:
- Names the customer (京东 / JD) and their business units (探索研究院, 京东云, 京东零售)
- Discloses non-public technical details: 750B model activated-parameter count (~40B), internal P/D ratio (1:3), internal training cost claims (-70%), infrastructure vendor (商汤 / SenseTime)
- Names six JD employees by full name: `JoyAI_AWS_Report_Final.md:66,79`
- Names four AWS employees by full name: `JoyAI_AWS_Report_Final.md:64,65,79`
- Contains the label `**密级**：AWS Internal` at line 5
- Links to the internal JD API: `docs.jdcloud.com/cn/jdaip/chat` at line 213

`EFA_Validation_Plan.md` also:
- Identifies JoyAI-LLM-Flash as the test model and references the 750B production architecture in detail
- References `jdopensource/JoyAI-LLM-Flash` as the validation model directly tied to the customer
- References `/home/ec2-user/workspace/eks-cluster-deployment` (AWS SA's local machine path) at line 56

**Files:**
- `JoyAI_AWS_Report_Final.md` — entire file; classified AWS Internal
- `EFA_Validation_Plan.md:4,124,129,132,221,300`
- `validation/RUNBOOK.md:1,4,5`
- `validation/stage4-e2e/lws-prefill.yaml:65,189`
- `validation/stage4-e2e/lws-decode.yaml:60,186`
- `validation/stage4-e2e/lws-baseline-tp8.yaml:48,140`
- `validation/stage4-e2e/job-bench-serving.yaml:47`
- `validation/stage4-e2e/README.md:48,55`
- `validation/stage4-sglang-mooncake/README.md:15`

**Recommendation:**
- `JoyAI_AWS_Report_Final.md`: **Do not publish.** This is an AWS-internal engagement summary. It contains non-public customer financial and architectural information, named individuals on both sides, and a confidentiality classification. Remove entirely from the public repo.
- `EFA_Validation_Plan.md` and validation manifests: Customer references can be neutralized by replacing `JoyAI-LLM-Flash` / `jdopensource/JoyAI-LLM-Flash` with a generic `<MODEL_ID>` or an openly available equivalent model reference. References to "客户" (customer) in prose are acceptable for context but mentions of specific customer names (京东/JD/言犀) should be evaluated.
- `validation/RUNBOOK.md:4`: Replace "AWS Account Team (JD)" with generic text.
- The local machine path `/home/ec2-user/workspace/eks-cluster-deployment` at `EFA_Validation_Plan.md:56` reveals the AWS SA's home directory layout; replace with a relative path or a documented environment variable.

---

### [7] Named Individuals (PII)

`JoyAI_AWS_Report_Final.md:64–66,79,147` names nine individuals with employer affiliations:
- AWS employees: Duan Xun (BD), Zhao Keming (SA), Kaige Yang (AS), Haoran Lv (AS)
- JD employees: Chang Li, Chao Xue, Xiaodong He, Qiong Cao
- Third party: Yaren Zhang (Carleton)

The arxiv paper `arXiv:2507.16473` is a public record and the author list there is already public. However, the internal role descriptions (BD, SA) and internal team names for AWS employees are not public.

**Recommendation:** Remove `JoyAI_AWS_Report_Final.md` entirely (see finding [6]). If any other document needs to credit contributors, use GitHub usernames or first-name-only with explicit consent.

---

### [8] AWS Nodegroup Update ID

`validation/RUNBOOK.md:81` — `4d281993-…` — a partial AWS EKS nodegroup update ID. Low risk but still an internal AWS resource identifier.

**Recommendation:** Redact to `<NODEGROUP_UPDATE_ID>`.

---

## Warnings (Review Before Release)

### [W1] EKS Cluster Names

`gpu-cluster-ohio` and `gpu-cluster-oregon` appear throughout many files. These are not secret but they are specific customer-environment names that, combined with the account ID and region, directly identify the infrastructure.

**Recommendation:** Replace with `<EKS_CLUSTER_NAME>` or a generic example name.

### [W2] Reference to Sibling Repo `eks-cluster-deployment`

`EFA_Validation_Plan.md:6,35,56,296` and several other files reference `../../eks-cluster-deployment/` and specific scripts within it. This implies a sibling repository that may or may not be published simultaneously.

**Recommendation:** Clarify in README whether `eks-cluster-deployment` will be published alongside this repo. If not, replace relative paths with documentation links or notes.

### [W3] ArXiv Paper ID `arXiv:2507.16473`

`JoyAI_AWS_Report_Final.md:76,147,209` references the joint AWS × JD paper. The paper itself is public. However, in the context of this repo the reference links the infrastructure code back to the customer relationship.

**Recommendation:** If `JoyAI_AWS_Report_Final.md` is removed (strongly recommended), this warning is moot. If any other file references the paper, that is acceptable since it is public.

### [W4] Raw Validation Logs in `validation/logs/` and `validation/results/`

The log files contain detailed internal execution traces including NCCL debug output, private IPs (see finding [4]), pod scheduling events, and infrastructure error messages. While technically not secrets, they narrow the attack surface for anyone trying to fingerprint the environment.

**Recommendation:** Consider omitting raw log files from the public repo entirely (add to `.gitignore`). Publish only the `SUMMARY.md` result files after scrubbing IPs.

### [W5] `.cid` Files in `validation/logs/stage0-setup/`

Thirteen `.cid` files contain SSM command IDs. These are opaque identifiers that link back to the AWS account's SSM command history.

- `validation/logs/stage0-setup/build-base-cuda-efa-20260421T043643Z.cid` (and 12 others)

**Recommendation:** Remove all `.cid` files. Add `validation/logs/stage0-setup/*.cid` to `.gitignore`.

---

## .env.example Audit

No `.env.example` file exists. The project is infrastructure scripts rather than a deployable application, but variables that must be supplied by users are currently hardcoded (account ID, region, cluster names, instance IDs). A `.env.example` should be created listing at minimum:

```
AWS_ACCOUNT_ID=<your-12-digit-aws-account-id>
AWS_REGION_PRIMARY=us-east-2
AWS_REGION_FALLBACK=us-west-2
OHIO_BASTION=<i-xxxxxxxxxxxxxxxxx>
OREGON_BASTION=<i-xxxxxxxxxxxxxxxxx>
BUILDER_ID=<i-xxxxxxxxxxxxxxxxx>
OHIO_CLUSTER=<cluster-name>
OREGON_CLUSTER=<cluster-name>
S3_BUCKET=<bucket-name>
```

---

## Recommendation

**Fix the 8 critical findings listed above before any public release.** The minimum required actions are:

1. **Remove `JoyAI_AWS_Report_Final.md` entirely.** It is an AWS-internal document with a confidentiality classification, named individuals, and non-public customer details. It has no place in a public repo.
2. **Replace all 96 occurrences of `788668107894`** with an `${AWS_ACCOUNT_ID}` variable reference.
3. **Replace the 3 hardcoded EC2 instance IDs** with environment variable references; remove them from `lib.sh` defaults.
4. **Replace all VPC/subnet/SG/AMI IDs** with placeholder variables.
5. **Regenerate or remove the base64-encoded env blobs** in `bastion-push-env-ohio.json` and `bastion-push-env-oregon.json`; the current blobs encode the full subnet topology.
6. **Scrub or remove raw log files** containing `10.1.12.x` private IPs.
7. **Replace node hostnames** (`ip-10-1-12-xxx.us-east-2.compute.internal`) with `<GPU_NODE_N>` placeholders.
8. **Remove the `.cid` files** under `validation/logs/stage0-setup/`.

After these changes, re-run the sanitizer to verify all critical findings are resolved.
