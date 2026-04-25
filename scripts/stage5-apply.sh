#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# stage5-apply.sh — thin wrapper around kubectl for Stage 5 manifests.
#
# Usage:
#   scripts/stage5-apply.sh <run-id> <region> <verb>
#
#   run-id = r0-smoke | r1a-kimi-k2-1p1d | r1b-... | k-e1-... | e-e1-...
#            (must match manifests/stage5-p5en/<run-id>.yaml)
#   region = us-east-2 | us-west-2
#   verb   = apply | delete | status | logs [component] | wait
#
# Examples:
#   scripts/stage5-apply.sh r0-smoke us-east-2 apply
#   scripts/stage5-apply.sh r0-smoke us-east-2 logs
#   scripts/stage5-apply.sh r1a-kimi-k2-1p1d us-east-2 wait
#   scripts/stage5-apply.sh r1a-kimi-k2-1p1d us-east-2 delete
# -----------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/stage5-lib.sh"

if [ $# -lt 3 ]; then
  sed -n '3,20p' "$0" | sed 's/^# \?//'
  exit 2
fi

RUN="$1"; REGION="$2"; VERB="$3"; shift 3
MANIFEST="${ROOT}/manifests/stage5-p5en/${RUN}.yaml"
[ -f "${MANIFEST}" ] || { echo "manifest not found: ${MANIFEST}"; exit 2; }

stage5_load_region "${REGION}"
stage5_kubeconfig

# Most resources label themselves app=sglang-<run> so we can target them
# without hard-coding per-run pod names.
APP_LABEL_PREFIX="sglang-${RUN%%-*}"   # e.g. "sglang-r0" / "sglang-r1a"
# For r1a we also have *-lb; the broader selector "app in (sglang-r1a,sglang-r1a-lb)"
# is captured via label prefix + partOf matching below.

case "${VERB}" in
  apply)
    kubectl apply -f "${MANIFEST}"
    ;;
  delete)
    kubectl delete --ignore-not-found -f "${MANIFEST}"
    ;;
  status)
    echo "=== pods (namespace ${STAGE5_NS}) ==="
    kubectl -n "${STAGE5_NS}" get pods -o wide | grep -E "NAME|${RUN}" || true
    echo
    echo "=== services ==="
    kubectl -n "${STAGE5_NS}" get svc | grep -E "NAME|${RUN}" || true
    echo
    echo "=== nodegroup ==="
    stage5_ng_status
    ;;
  logs)
    COMP="${1:-}"
    if [ -z "${COMP}" ]; then
      echo "components (pick one):"
      kubectl -n "${STAGE5_NS}" get pods --no-headers -o custom-columns=":metadata.name" \
        | grep -E "${RUN}" || true
      exit 0
    fi
    kubectl -n "${STAGE5_NS}" logs -f "${COMP}" -c server 2>/dev/null \
      || kubectl -n "${STAGE5_NS}" logs -f "${COMP}"
    ;;
  wait)
    echo "[wait] readiness for ${RUN} pods (timeout 30 min)"
    # R0 has a single Pod named sglang-r0-smoke; Deployments have pods from
    # rollouts — use rollout status for Deployments, wait --for for the Pod.
    # We'll just attempt both and ignore mismatches.
    PODS=$(kubectl -n "${STAGE5_NS}" get pods --no-headers -o custom-columns=":metadata.name" | grep -E "${RUN}" || true)
    DEPLOYS=$(kubectl -n "${STAGE5_NS}" get deploy --no-headers -o custom-columns=":metadata.name" | grep -E "${RUN}" || true)
    if [ -n "${DEPLOYS}" ]; then
      for d in ${DEPLOYS}; do
        echo "[wait] rollout ${d}"
        kubectl -n "${STAGE5_NS}" rollout status "deploy/${d}" --timeout=1800s
      done
    fi
    if [ -n "${PODS}" ] && [ -z "${DEPLOYS}" ]; then
      for p in ${PODS}; do
        echo "[wait] pod ${p}"
        kubectl -n "${STAGE5_NS}" wait --for=condition=Ready "pod/${p}" --timeout=1800s
      done
    fi
    echo "[wait] all ready"
    ;;
  *)
    echo "unknown verb: ${VERB} (apply|delete|status|logs|wait)"
    exit 2
    ;;
esac
