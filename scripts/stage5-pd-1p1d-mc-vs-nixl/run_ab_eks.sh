#!/bin/bash
# Unattended A/B orchestrator (v2) — runs bench via kubectl exec into LB pod.
# The LB pod already has sglang.bench_serving installed, and `localhost:8000`
# inside the LB pod hits the sglang-router that bridges prefill+decode.
#
# Results go under /root/results/pd-1p1d-mc-vs-nixl-k25-int4/<STAMP>/ and also
# mirrored to S3 on each bench completion so nothing is lost if bastion reboots.

set -u
export KUBECONFIG=/root/.kube/config
export PATH=/usr/local/bin:/usr/bin:/bin

STAMP="${STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"
RESULTS=/root/results/pd-1p1d-mc-vs-nixl-k25-int4/${STAMP}
MANIFEST=/root/stage5/pd-1p1d-mc-vs-nixl-k25-int4-usw2.yaml
NS=yanxi-validation
S3_RESULTS=s3://yanxi-validation-788668107894-oregon/results/pd-1p1d-mc-vs-nixl-k25-int4/${STAMP}
S3_REGION=us-west-2

mkdir -p "$RESULTS"/{raw,logs,summary}
LOG=$RESULTS/STEPS.md
touch "$LOG"

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }
sync_to_s3() { aws s3 sync "$RESULTS" "$S3_RESULTS" --region "$S3_REGION" --quiet 2>&1 | tail -3 >> "$LOG" || true; }

# --- scenarios (kept modest to fit one unattended run in ~3-4h) ---
declare -A IN=([S1]=2048 [S2]=8192 [S3]=32768 [S4]=4096)
declare -A OUT=([S1]=512 [S2]=1024 [S3]=1024 [S4]=512)
declare -A CC=([S1]=32 [S2]=64 [S3]=16 [S4]=128)
declare -A NP=([S1]=200 [S2]=200 [S3]=100 [S4]=200)
declare -A WU=([S1]=20 [S2]=20 [S3]=10 [S4]=20)
SCENS=(S1 S2 S3 S4)
ROUNDS=3

get_lb_pod() {
    kubectl -n "$NS" get pod -l app=c1p1d-lb -o name 2>/dev/null | head -1
}
get_prefill_pod() {
    # Use prefill pod for bench: it has /models mounted (LB pod does not).
    # Bench target is still LB's ClusterIP service (same-namespace DNS).
    kubectl -n "$NS" get pod -l role=prefill -o name 2>/dev/null | head -1
}

wait_ready() {
    local timeout="${1:-1500}"
    local start=$(date -u +%s)
    log "wait_ready (timeout ${timeout}s)"
    while true; do
        r1=$(kubectl -n "$NS" get deploy c1p1d-prefill -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
        r2=$(kubectl -n "$NS" get deploy c1p1d-decode -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
        r3=$(kubectl -n "$NS" get deploy c1p1d-lb -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
        ts=$(date -u +%H:%M:%SZ)
        log "  [$ts] readiness p=${r1:-0}/1 d=${r2:-0}/1 lb=${r3:-0}/1"
        if [[ "${r1:-0}" == "1" && "${r2:-0}" == "1" && "${r3:-0}" == "1" ]]; then
            # extra sanity: router /health via python (container lacks curl)
            lb=$(get_lb_pod)
            if kubectl -n "$NS" exec "$lb" -- python3 -c 'import urllib.request,sys; urllib.request.urlopen("http://localhost:8000/health",timeout=3); sys.exit(0)' >/dev/null 2>&1; then
                log "all Ready + router health ok after $(( $(date -u +%s) - start ))s"
                return 0
            fi
        fi
        if [ $(( $(date -u +%s) - start )) -gt "$timeout" ]; then
            log "TIMEOUT"
            kubectl -n "$NS" get pods -o wide >> "$LOG" 2>&1
            for p in $(kubectl -n "$NS" get pods -l 'app in (c1p1d,c1p1d-lb)' -o name 2>/dev/null); do
                log "--- $p server logs (last 50) ---"
                kubectl -n "$NS" logs "$p" -c server --tail=50 >> "$LOG" 2>&1 || true
                kubectl -n "$NS" logs "$p" --tail=50 >> "$LOG" 2>&1 || true
            done
            return 1
        fi
        sleep 30
    done
}

run_bench() {
    # args: tag in out cc np wu
    local tag=$1 inp=$2 out=$3 cc=$4 np=$5 wu=$6
    local runner  # pod we exec bench_serving inside
    runner=$(get_prefill_pod)
    [[ -z "$runner" ]] && { log "no prefill pod; abort"; return 1; }
    local raw_remote="/tmp/${tag}.json"
    local lg="$RESULTS/logs/${tag}.log"
    log "bench $tag in=$inp out=$out cc=$cc np=$np wu=$wu (runner=$runner)"

    local MODEL_LOCAL=/models/moonshotai/Kimi-K2.5
    local LB_URL="http://c1p1d-lb.${NS}.svc:8000"

    # warmup (no output file)
    kubectl -n "$NS" exec "$runner" -c server -- env HF_TOKEN="$HF_TOKEN" HUGGING_FACE_HUB_TOKEN="$HF_TOKEN" \
        python3 -m sglang.bench_serving \
        --backend sglang \
        --base-url "$LB_URL" \
        --dataset-name random \
        --random-input-len "$inp" --random-output-len "$out" \
        --num-prompts "$wu" --max-concurrency "$cc" \
        --model "$MODEL_LOCAL" \
        --tokenizer "$MODEL_LOCAL" \
        --disable-tqdm \
        > "$RESULTS/logs/${tag}-warmup.log" 2>&1 || log "warmup $tag non-zero (continuing)"

    # measurement
    kubectl -n "$NS" exec "$runner" -c server -- env HF_TOKEN="$HF_TOKEN" HUGGING_FACE_HUB_TOKEN="$HF_TOKEN" \
        python3 -m sglang.bench_serving \
        --backend sglang \
        --base-url "$LB_URL" \
        --dataset-name random \
        --random-input-len "$inp" --random-output-len "$out" \
        --num-prompts "$np" --max-concurrency "$cc" \
        --model "$MODEL_LOCAL" \
        --tokenizer "$MODEL_LOCAL" \
        --disable-tqdm \
        --output-file "$raw_remote" > "$lg" 2>&1
    ec=$?
    if [[ $ec -ne 0 ]]; then
        log "bench $tag FAILED exit=$ec"
        tail -30 "$lg" >> "$LOG" || true
        return $ec
    fi

    # copy result JSON back to bastion
    kubectl -n "$NS" cp "${runner#pod/}:$raw_remote" "$RESULTS/raw/${tag}.json" -c server 2>/dev/null \
        || kubectl -n "$NS" exec "$runner" -c server -- cat "$raw_remote" > "$RESULTS/raw/${tag}.json" 2>/dev/null
    if [[ -s "$RESULTS/raw/${tag}.json" ]]; then
        log "bench $tag OK raw=$(stat -c %s "$RESULTS/raw/${tag}.json") bytes"
    else
        log "bench $tag: result file empty — check logs"
    fi
    sync_to_s3
}

teardown_wait() {
    log "teardown all deploys"
    kubectl -n "$NS" delete deploy --all --wait=false 2>&1 | tee -a "$LOG"
    local start=$(date -u +%s)
    while true; do
        n=$(kubectl -n "$NS" get pods -l 'app in (c1p1d,c1p1d-lb)' -o name 2>/dev/null | wc -l)
        [[ "$n" == "0" ]] && { log "pods gone in $(( $(date -u +%s) - start ))s"; return 0; }
        if [ $(( $(date -u +%s) - start )) -gt 600 ]; then
            log "force delete"
            kubectl -n "$NS" delete pods --all --force --grace-period=0 2>/dev/null
            sleep 10
            return 0
        fi
        sleep 10
    done
}

apply_variant() {
    local backend=$1
    log "apply variant backend=$backend"
    KV_BACKEND="$backend" envsubst '$KV_BACKEND' < "$MANIFEST" | kubectl apply -f -
    wait_ready 1500
}

run_matrix() {
    local backend=$1
    for sc in "${SCENS[@]}"; do
        for r in $(seq 1 $ROUNDS); do
            local tag="${sc,,}-${backend}-r${r}"
            run_bench "$tag" "${IN[$sc]}" "${OUT[$sc]}" "${CC[$sc]}" "${NP[$sc]}" "${WU[$sc]}" || log "bench $tag failed (continuing)"
        done
    done
}

# ============= MAIN =============
log "=== UNATTENDED A/B START stamp=$STAMP ==="

# Allow SKIP_INITIAL_APPLY=1 to reuse already-deployed mooncake pods (saves
# ~10 min of weight reload when only the bench script itself needs rerunning).
if [[ "${SKIP_INITIAL_APPLY:-0}" == "1" ]]; then
    current=$(kubectl -n "$NS" get deploy c1p1d-prefill -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="KV_BACKEND")].value}' 2>/dev/null || true)
    log "SKIP_INITIAL_APPLY=1; current deployed backend='$current'"
    if [[ "$current" != "mooncake" ]]; then
        log "expected mooncake already deployed; fixing"
        teardown_wait
        apply_variant mooncake || { log "APPLY mooncake FAILED"; exit 1; }
    else
        wait_ready 600 || { log "existing mooncake not Ready in 10min"; exit 1; }
    fi
else
    # Always start clean with mooncake variant (deterministic state).
    teardown_wait
    apply_variant mooncake || { log "APPLY mooncake FAILED"; exit 1; }
fi

log "=== SMOKE mooncake ==="
run_bench "smoke-mooncake" 2048 256 8 15 3 || log "smoke mooncake failed"

log "=== FULL mooncake ==="
run_matrix mooncake

log "=== SWITCH to nixl ==="
teardown_wait
apply_variant nixl || { log "APPLY nixl FAILED"; exit 3; }

log "=== SMOKE nixl ==="
run_bench "smoke-nixl" 2048 256 8 15 3 || log "smoke nixl failed"

log "=== FULL nixl ==="
run_matrix nixl

log "=== FINAL teardown ==="
teardown_wait

kubectl -n "$NS" get events --sort-by='.lastTimestamp' > "$RESULTS/logs/events.txt" 2>&1 || true

touch "$RESULTS/.complete"
log "=== A/B COMPLETE ==="
sync_to_s3
