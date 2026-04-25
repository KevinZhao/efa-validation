#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# stage5-render.sh — generate a disaggregation manifest for a given P:D topology.
#
# Produces <run>.yaml on stdout (or to -o <file>) from a single template.
# All Stage 5 disaggregation manifests (R1a/b/c/d/e, R2, R3, R4, R5) share
# structure: N prefill Deployments + M decode Deployments + 1 LB Deployment,
# all referring to ConfigMap `sglang-stage5-launcher` (apply _launcher.yaml
# first).
#
# Usage:
#   scripts/stage5-render.sh \
#     --run r1b-kimi-k2-1p2d \
#     --model /models/Kimi-K2-Instruct-0905 \
#     --prefill 1 --decode 2 \
#     --tp 8 --ctx 131072 --mem 0.92 --chunked 4096 \
#     [--kv mooncake|nixl] [--image <ecr-url>] [--region us-east-2]
#     [--extra-args "--enable-dp-attention"] \
#     [-o manifests/stage5-p5en/r1b-kimi-k2-1p2d.yaml]
#
# Notes:
#   - Default image derives from --region; pass --image to override.
#   - Each prefill/decode rep gets its own Deployment + Service (so one failing
#     pod can be inspected without affecting peers).
#   - PodAntiAffinity is hostname-scoped so every pod lands on a distinct node.
# -----------------------------------------------------------------------------
set -euo pipefail

RUN=""; MODEL=""; P=1; D=1; TP=8
CTX=131072; MEM=0.92; CHUNKED=4096
KV=mooncake; IMAGE=""; REGION=us-east-2
FP8_BACKEND=cutlass; ATTN=flashinfer
EXTRA_ARGS=""
OUT=""
NS="yanxi-validation"
INSTANCE_TYPE="p5en.48xlarge"

while [ $# -gt 0 ]; do
  case "$1" in
    --run)       RUN="$2"; shift 2;;
    --model)     MODEL="$2"; shift 2;;
    --prefill|-p) P="$2"; shift 2;;
    --decode|-d)  D="$2"; shift 2;;
    --tp)        TP="$2"; shift 2;;
    --ctx)       CTX="$2"; shift 2;;
    --mem)       MEM="$2"; shift 2;;
    --chunked)   CHUNKED="$2"; shift 2;;
    --kv)        KV="$2"; shift 2;;
    --image)     IMAGE="$2"; shift 2;;
    --region)    REGION="$2"; shift 2;;
    --fp8-backend) FP8_BACKEND="$2"; shift 2;;
    --attn)      ATTN="$2"; shift 2;;
    --extra-args) EXTRA_ARGS="$2"; shift 2;;
    --instance-type) INSTANCE_TYPE="$2"; shift 2;;
    -o|--output) OUT="$2"; shift 2;;
    -h|--help)   sed -n '3,30p' "$0" | sed 's/^# \?//'; exit 0;;
    *) echo "unknown flag: $1"; exit 2;;
  esac
done

[ -n "${RUN}" ]   || { echo "--run required"; exit 2; }
[ -n "${MODEL}" ] || { echo "--model required"; exit 2; }
[ -z "${IMAGE}" ] && IMAGE="788668107894.dkr.ecr.${REGION}.amazonaws.com/yanxi/sglang-mooncake:v2"

APP="sglang-${RUN}"

render_pod_spec() {
  local role="$1" idx="$2"
  local name="${APP}-${role}"
  [ "${idx}" != "-" ] && name="${name}-${idx}"
  cat <<EOF
---
apiVersion: v1
kind: Service
metadata:
  name: ${name}
  namespace: ${NS}
spec:
  selector: { app: ${APP}, role: ${role}, idx: "${idx}" }
  ports:
    - { name: http, port: 30000, targetPort: 30000 }
    - { name: bootstrap, port: 8998, targetPort: 8998 }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
  namespace: ${NS}
  labels: { app: ${APP}, role: ${role}, idx: "${idx}" }
spec:
  replicas: 1
  selector: { matchLabels: { app: ${APP}, role: ${role}, idx: "${idx}" } }
  template:
    metadata:
      labels: { app: ${APP}, role: ${role}, idx: "${idx}" }
    spec:
      tolerations:
        - { key: nvidia.com/gpu, operator: Equal, value: "true", effect: NoSchedule }
      nodeSelector: { node.kubernetes.io/instance-type: ${INSTANCE_TYPE} }
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector: { matchLabels: { app: ${APP} } }
              topologyKey: kubernetes.io/hostname
      containers:
        - name: server
          image: ${IMAGE}
          imagePullPolicy: IfNotPresent
          env:
            - { name: ROLE, value: "${role}" }
            - { name: MODEL_PATH, value: "${MODEL}" }
            - { name: TP, value: "${TP}" }
            - { name: CONTEXT_LEN, value: "${CTX}" }
            - { name: MEM_FRAC_STATIC, value: "${MEM}" }
            - { name: CHUNKED_PREFILL, value: "${CHUNKED}" }
            - { name: FP8_BACKEND, value: "${FP8_BACKEND}" }
            - { name: ATTENTION_BACKEND, value: "${ATTN}" }
            - { name: KV_TRANSPORT_BACKEND, value: "${KV}" }
            - { name: EXTRA_ARGS, value: "${EXTRA_ARGS}" }
          command: ["/bin/bash", "-lc"]
          args: ["exec /scripts/sglang-launcher.sh"]
          readinessProbe:
            httpGet: { path: /get_model_info, port: 30000 }
            initialDelaySeconds: 240
            periodSeconds: 10
            failureThreshold: 180
          ports:
            - { containerPort: 30000, name: http }
            - { containerPort: 8998, name: bootstrap }
          securityContext: { capabilities: { add: [IPC_LOCK] } }
          resources:
            limits:   { nvidia.com/gpu: 8, vpc.amazonaws.com/efa: 16, hugepages-2Mi: 5120Mi, memory: 500Gi }
            requests: { nvidia.com/gpu: 8, vpc.amazonaws.com/efa: 16, hugepages-2Mi: 5120Mi, memory: 500Gi }
          volumeMounts:
            - { name: models, mountPath: /models }
            - { name: shm,    mountPath: /dev/shm }
            - { name: scripts, mountPath: /scripts }
      volumes:
        - name: models
          persistentVolumeClaim: { claimName: yanxi-model-cache }
        - name: shm
          emptyDir: { medium: Memory, sizeLimit: 64Gi }
        - name: scripts
          configMap: { name: sglang-stage5-launcher, defaultMode: 0755 }
EOF
}

render_lb() {
  local prefill_urls decode_urls
  prefill_urls=$(for i in $(seq 0 $((P-1))); do
    printf "http://${APP}-prefill-%d.%s.svc:30000," "$i" "${NS}"
  done | sed 's/,$//')
  decode_urls=$(for i in $(seq 0 $((D-1))); do
    printf "http://${APP}-decode-%d.%s.svc:30000," "$i" "${NS}"
  done | sed 's/,$//')
  cat <<EOF
---
apiVersion: v1
kind: Service
metadata:
  name: ${APP}-lb
  namespace: ${NS}
spec:
  selector: { app: ${APP}-lb }
  ports:
    - { name: http, port: 8000, targetPort: 8000 }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP}-lb
  namespace: ${NS}
  labels: { app: ${APP}-lb }
spec:
  replicas: 1
  selector: { matchLabels: { app: ${APP}-lb } }
  template:
    metadata:
      labels: { app: ${APP}-lb }
    spec:
      tolerations:
        - { key: nvidia.com/gpu, operator: Equal, value: "true", effect: NoSchedule }
      containers:
        - name: lb
          image: ${IMAGE}
          imagePullPolicy: IfNotPresent
          env:
            - { name: ROLE, value: "lb" }
            - { name: PREFILL_URL, value: "${prefill_urls}" }
            - { name: DECODE_URL,  value: "${decode_urls}" }
          command: ["/bin/bash", "-lc"]
          args: ["exec /scripts/sglang-launcher.sh"]
          ports:
            - { containerPort: 8000, name: http }
          readinessProbe:
            httpGet: { path: /health, port: 8000 }
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 30
          volumeMounts:
            - { name: scripts, mountPath: /scripts }
      volumes:
        - name: scripts
          configMap: { name: sglang-stage5-launcher, defaultMode: 0755 }
EOF
}

{
  cat <<EOF
# Auto-generated by scripts/stage5-render.sh — DO NOT edit by hand.
# run=${RUN} topology=${P}P:${D}D tp=${TP} ctx=${CTX} mem=${MEM} chunked=${CHUNKED}
# model=${MODEL} kv=${KV} image=${IMAGE}
# Apply the shared launcher first: kubectl apply -f manifests/stage5-p5en/_launcher.yaml
EOF
  for i in $(seq 0 $((P-1))); do render_pod_spec prefill "$i"; done
  for i in $(seq 0 $((D-1))); do render_pod_spec decode  "$i"; done
  render_lb
} > "${OUT:-/dev/stdout}"

[ -n "${OUT}" ] && echo "wrote ${OUT}" >&2 || true
