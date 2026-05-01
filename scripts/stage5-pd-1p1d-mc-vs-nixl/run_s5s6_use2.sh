#!/bin/bash
# S5/S6 long-context extension on Ohio (us-east-2a), same stamp as Oregon run
# so raw JSONs flow into the same /root/results tree. Final RESULT.md will note
# S1-S4 were Oregon az4 and S5-S6 were Ohio az1 (same hardware class p5en.48xl,
# same image, same model — only KV transport changes across A/B).

set -u
export KUBECONFIG=/root/.kube/config
export PATH=/usr/local/bin:/usr/bin:/bin

STAMP="${STAMP:-20260501T002853Z}"
RESULTS=/root/results/pd-1p1d-mc-vs-nixl-k25-int4/${STAMP}
MANIFEST=/root/stage5/pd-1p1d-mc-vs-nixl-k25-int4-use2.yaml
NS=yanxi-validation
S3_RESULTS=s3://yanxi-validation-788668107894-ohio/results/pd-1p1d-mc-vs-nixl-k25-int4/${STAMP}
S3_REGION=us-east-2

mkdir -p "$RESULTS"/{raw,logs,summary}
LOG=$RESULTS/STEPS.md
touch "$LOG"

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }
sync_to_s3() { aws s3 sync "$RESULTS" "$S3_RESULTS" --region "$S3_REGION" --quiet 2>&1 | tail -3 >> "$LOG" || true; }

declare -A IN=([S5]=61440  [S6]=122880)
declare -A OUT=([S5]=1024   [S6]=1024)
declare -A CC=([S5]=8      [S6]=4)
declare -A NP=([S5]=60     [S6]=30)
declare -A WU=([S5]=6      [S6]=3)
SCENS=(S5 S6)
ROUNDS=3

get_lb_pod()      { kubectl -n "$NS" get pod -l app=c1p1d-lb -o name 2>/dev/null | head -1; }
get_prefill_pod() { kubectl -n "$NS" get pod -l role=prefill -o name 2>/dev/null | head -1; }

wait_ready() {
    local timeout="${1:-1800}"
    local start=$(date -u +%s)
    log "wait_ready (timeout ${timeout}s)"
    while true; do
        r1=$(kubectl -n "$NS" get deploy c1p1d-prefill -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
        r2=$(kubectl -n "$NS" get deploy c1p1d-decode -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
        r3=$(kubectl -n "$NS" get deploy c1p1d-lb -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
        ts=$(date -u +%H:%M:%SZ)
        log "  [$ts] readiness p=${r1:-0}/1 d=${r2:-0}/1 lb=${r3:-0}/1"
        if [[ "${r1:-0}" == "1" && "${r2:-0}" == "1" && "${r3:-0}" == "1" ]]; then
            lb=$(get_lb_pod)
            if kubectl -n "$NS" exec "$lb" -- python3 -c 'import urllib.request,sys; urllib.request.urlopen("http://localhost:8000/health",timeout=3); sys.exit(0)' >/dev/null 2>&1; then
                log "all Ready + router health ok after $(( $(date -u +%s) - start ))s"
                return 0
            fi
        fi
        if [ $(( $(date -u +%s) - start )) -gt "$timeout" ]; then
            log "TIMEOUT"
            kubectl -n "$NS" get pods -o wide >> "$LOG" 2>&1
            return 1
        fi
        sleep 30
    done
}

run_bench() {
    local tag=$1 inp=$2 out=$3 cc=$4 np=$5 wu=$6
    local runner
    runner=$(get_prefill_pod)
    [[ -z "$runner" ]] && { log "no prefill pod; abort"; return 1; }
    local raw_remote="/tmp/${tag}.json"
    local lg="$RESULTS/logs/${tag}.log"
    log "bench $tag in=$inp out=$out cc=$cc np=$np wu=$wu (runner=$runner)"

    local MODEL_LOCAL=/models/moonshotai/Kimi-K2.5
    local LB_URL="http://c1p1d-lb.${NS}.svc:8000"

    kubectl -n "$NS" exec "$runner" -c server -- env HF_TOKEN="$HF_TOKEN" HUGGING_FACE_HUB_TOKEN="$HF_TOKEN" \
        python3 -m sglang.bench_serving --backend sglang --base-url "$LB_URL" \
        --dataset-name random --random-input-len "$inp" --random-output-len "$out" \
        --num-prompts "$wu" --max-concurrency "$cc" \
        --model "$MODEL_LOCAL" --tokenizer "$MODEL_LOCAL" --disable-tqdm \
        > "$RESULTS/logs/${tag}-warmup.log" 2>&1 || log "warmup $tag non-zero (continuing)"

    kubectl -n "$NS" exec "$runner" -c server -- env HF_TOKEN="$HF_TOKEN" HUGGING_FACE_HUB_TOKEN="$HF_TOKEN" \
        python3 -m sglang.bench_serving --backend sglang --base-url "$LB_URL" \
        --dataset-name random --random-input-len "$inp" --random-output-len "$out" \
        --num-prompts "$np" --max-concurrency "$cc" \
        --model "$MODEL_LOCAL" --tokenizer "$MODEL_LOCAL" --disable-tqdm \
        --output-file "$raw_remote" > "$lg" 2>&1
    ec=$?
    if [[ $ec -ne 0 ]]; then
        log "bench $tag FAILED exit=$ec"
        tail -30 "$lg" >> "$LOG" || true
        return $ec
    fi

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
    wait_ready 1800
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
log "=== S5/S6 OHIO EXTENSION START stamp=$STAMP ==="

teardown_wait
apply_variant mooncake || { log "APPLY mooncake FAILED"; exit 1; }

log "=== FULL mooncake S5/S6 ==="
run_matrix mooncake

log "=== SWITCH to nixl ==="
teardown_wait
apply_variant nixl || { log "APPLY nixl FAILED"; exit 3; }

log "=== FULL nixl S5/S6 ==="
run_matrix nixl

log "=== FINAL teardown ==="
teardown_wait

kubectl -n "$NS" get events --sort-by='.lastTimestamp' > "$RESULTS/logs/events-s5s6.txt" 2>&1 || true

touch "$RESULTS/.complete-s5s6"
log "=== S5/S6 OHIO EXTENSION COMPLETE ==="
sync_to_s3
