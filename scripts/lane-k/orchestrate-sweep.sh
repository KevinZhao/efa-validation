#!/bin/bash
# Lane K orchestrator — runs from the BASTION. Drives the 120-tuple sweep.
#
# For each (nic_count, rails, msg_size, concurrency) tuple:
#   1. NIXL round:
#        - kubectl exec on TARGET: start `nixlbench --role target ... &` in background
#        - kubectl exec on INITIATOR: run `nixlbench --role initiator ...`
#        - capture initiator stdout, parse, append CSV row
#        - kill target-side process
#   2. 5 s cooldown (etcd keys drain)
#   3. Mooncake round: same pattern with `transfer_engine_bench`
#   4. Append CSV row
#
# NOTE: This file is a skeleton — exact CLI flags for nixlbench target/initiator
# pair will be filled in after preflight.sh prints `--help`. DO NOT RUN AS-IS.
# Once preflight output is inspected, edit the two TODO blocks below.
set -euo pipefail

NS=yanxi-validation
TARGET_POD=lane-k-target
INITIATOR_POD=lane-k-initiator
ETCD_EP=http://etcd.yanxi-validation.svc:2379

OUT_DIR=/tmp/lane-k-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$OUT_DIR"
CSV="$OUT_DIR/lane-k-sweep.csv"
echo "run_id,tool,backend,nic_count,rails,msg_size,concurrency,operation,gbps_mean,rtt_us_p50,rtt_us_p99,samples,started_at,duration_s,notes" > "$CSV"

WARMUP_S=${WARMUP_S:-10}
DURATION_S=${DURATION_S:-30}
COOLDOWN_S=${COOLDOWN_S:-5}

# --- Build test tuples: 3 nic/rails × 5 msg × 4 conc = 60 pairs ---
declare -a NIC_RAILS=("16 16" "8 8" "4 4")
declare -a MSGS=(65536 262144 1048576 4194304 16777216)
declare -a CONCS=(1 4 16 64)

TARGET_IP=$(kubectl get pod -n $NS $TARGET_POD -o jsonpath='{.status.hostIP}')
INIT_IP=$(kubectl get pod -n $NS $INITIATOR_POD -o jsonpath='{.status.hostIP}')
echo "TARGET_IP=$TARGET_IP  INIT_IP=$INIT_IP  CSV=$CSV"

build_devs() { local n=$1; local o=""; for ((i=0;i<n;i++)); do o="${o}${o:+,}rdmap${i}s0"; done; echo "$o"; }

append_row() {
  # args: run_id tool backend nic rails msg conc gbps rtt50 rtt99 samples started notes
  echo "$1,$2,$3,$4,$5,$6,$7,write,$8,$9,${10},${11},${12},${DURATION_S},${13}" >> "$CSV"
}

parse_bw()   { grep -Eo 'Bandwidth[: ]+[0-9.]+'      "$1" 2>/dev/null | awk 'END{print $NF}' | head -1; }
parse_p50()  { grep -Eo '(Latency p50|p50)[: ]+[0-9.]+'  "$1" 2>/dev/null | awk 'END{print $NF}' | head -1; }
parse_p99()  { grep -Eo '(Latency p99|p99)[: ]+[0-9.]+'  "$1" 2>/dev/null | awk 'END{print $NF}' | head -1; }
parse_n()    { grep -Eo '(samples|iterations)[: ]+[0-9]+'"$1" 2>/dev/null | awk 'END{print $NF}' | head -1; }

run_nixl() {
  local run_id=$1 nic=$2 rails=$3 msg=$4 conc=$5
  local devs=$(build_devs "$nic")
  local tlog="$OUT_DIR/${run_id}.nixl.target.log"
  local ilog="$OUT_DIR/${run_id}.nixl.init.log"
  local started=$(date -u +%FT%TZ)

  # -------- TODO (after preflight): replace exact CLI for nixlbench target --------
  kubectl exec -n $NS $TARGET_POD -- bash -lc "
    export FI_PROVIDER=efa FI_EFA_USE_DEVICE_RDMA=1 FI_EFA_FORK_SAFE=1 FI_MR_HMEM=1
    export UCX_TLS=rc,cuda_copy UCX_MEMTYPE_CACHE=n UCX_IB_GPU_DIRECT_RDMA=y
    export UCX_NET_DEVICES='$devs' UCX_MAX_RNDV_RAILS=$rails
    nixlbench --mode target --backend LIBFABRIC --etcd_endpoints $ETCD_EP \
      --op write --block_size $msg --num_threads $conc --duration $DURATION_S
  " > "$tlog" 2>&1 &
  local tpid=$!

  sleep 2   # give target etcd-register time

  # -------- TODO (after preflight): replace exact CLI for nixlbench initiator --------
  kubectl exec -n $NS $INITIATOR_POD -- bash -lc "
    export FI_PROVIDER=efa FI_EFA_USE_DEVICE_RDMA=1 FI_EFA_FORK_SAFE=1 FI_MR_HMEM=1
    export UCX_TLS=rc,cuda_copy UCX_MEMTYPE_CACHE=n UCX_IB_GPU_DIRECT_RDMA=y
    export UCX_NET_DEVICES='$devs' UCX_MAX_RNDV_RAILS=$rails
    timeout $((WARMUP_S + DURATION_S + 15)) nixlbench \
      --mode initiator --backend LIBFABRIC --etcd_endpoints $ETCD_EP \
      --op write --block_size $msg --num_threads $conc --duration $DURATION_S \
      --target_ip $TARGET_IP
  " > "$ilog" 2>&1
  local rc=$?

  wait "$tpid" 2>/dev/null || true

  if [ $rc -ne 0 ]; then
    append_row "$run_id" nixlbench LIBFABRIC "$nic" "$rails" "$msg" "$conc" 0 0 0 0 "$started" "FAIL_rc=$rc"
  else
    local bw=$(parse_bw "$ilog"); local p50=$(parse_p50 "$ilog"); local p99=$(parse_p99 "$ilog"); local n=$(parse_n "$ilog")
    append_row "$run_id" nixlbench LIBFABRIC "$nic" "$rails" "$msg" "$conc" "${bw:-0}" "${p50:-0}" "${p99:-0}" "${n:-0}" "$started" "ok"
  fi
}

run_mooncake() {
  local run_id=$1 nic=$2 rails=$3 msg=$4 conc=$5
  local tlog="$OUT_DIR/${run_id}.mc.target.log"
  local ilog="$OUT_DIR/${run_id}.mc.init.log"
  local started=$(date -u +%FT%TZ)

  # -------- TODO (after preflight): replace exact CLI for mooncake target --------
  kubectl exec -n $NS $TARGET_POD -- bash -lc "
    export FI_PROVIDER=efa FI_EFA_USE_DEVICE_RDMA=1 FI_EFA_FORK_SAFE=1 FI_MR_HMEM=1
    export MC_WORKERS_PER_CTX=2 MC_NUM_CQ_PER_CTX=2
    transfer_engine_bench --mode target \
      --metadata_server etcd://${ETCD_EP#http://} \
      --protocol efa --auto_discovery true \
      --local_server_name $TARGET_IP:13001
  " > "$tlog" 2>&1 &
  local tpid=$!
  sleep 2

  # -------- TODO (after preflight): replace exact CLI for mooncake initiator --------
  kubectl exec -n $NS $INITIATOR_POD -- bash -lc "
    export FI_PROVIDER=efa FI_EFA_USE_DEVICE_RDMA=1 FI_EFA_FORK_SAFE=1 FI_MR_HMEM=1
    export MC_WORKERS_PER_CTX=2 MC_NUM_CQ_PER_CTX=2
    timeout $((WARMUP_S + DURATION_S + 15)) transfer_engine_bench \
      --mode initiator \
      --metadata_server etcd://${ETCD_EP#http://} \
      --protocol efa --auto_discovery true \
      --operation write --block_size $msg --threads $conc --duration $DURATION_S \
      --segment_id $TARGET_IP \
      --local_server_name $INIT_IP:13002 \
      --report_unit GB
  " > "$ilog" 2>&1
  local rc=$?

  wait "$tpid" 2>/dev/null || kubectl exec -n $NS $TARGET_POD -- pkill -x transfer_engine_bench 2>/dev/null || true

  if [ $rc -ne 0 ]; then
    append_row "$run_id" transfer_engine_bench EfaTransport "$nic" "$rails" "$msg" "$conc" 0 0 0 0 "$started" "FAIL_rc=$rc"
  else
    local bw=$(parse_bw "$ilog"); local p50=$(parse_p50 "$ilog"); local p99=$(parse_p99 "$ilog"); local n=$(parse_n "$ilog")
    append_row "$run_id" transfer_engine_bench EfaTransport "$nic" "$rails" "$msg" "$conc" "${bw:-0}" "${p50:-0}" "${p99:-0}" "${n:-0}" "$started" "ok"
  fi
}

POINT=0
for nr in "${NIC_RAILS[@]}"; do
  read nic rails <<<"$nr"
  for msg in "${MSGS[@]}"; do
    for conc in "${CONCS[@]}"; do
      POINT=$((POINT+1))
      RUN_ID="p$(printf '%03d' $POINT)-n${nic}r${rails}m${msg}c${conc}"
      echo "=============================================="
      echo "[${POINT}/60] $RUN_ID"
      echo "=============================================="
      run_nixl     "$RUN_ID" "$nic" "$rails" "$msg" "$conc" || echo "WARN: NIXL point failed"
      sleep "$COOLDOWN_S"
      run_mooncake "$RUN_ID" "$nic" "$rails" "$msg" "$conc" || echo "WARN: Mooncake point failed"
      sleep "$COOLDOWN_S"
    done
  done
done

echo "Sweep complete. CSV at $CSV"
ls "$OUT_DIR"
