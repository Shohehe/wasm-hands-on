#!/bin/bash
# =============================================================================
# Availability Test - Pod Recovery Time
# =============================================================================
# Usage: ./availability-test.sh <namespace> <service-name> [runs]
#
# Example:
#   ./availability-test.sh wasm gateway 5
#   ./availability-test.sh containers gateway 5
#
# This script:
#   1. Scales the target to replica 1
#   2. Deletes the pod (--force --grace-period=0)
#   3. Polls Pod Ready condition at 0.1s intervals
#   4. Records delete → Ready time
#   5. Repeats N times and reports statistics
#
# Note: --force --grace-period=0 is for testing only.
#       In production, use normal graceful shutdown.
# =============================================================================

set -euo pipefail

NAMESPACE="${1:?Usage: $0 <namespace> <service-name> [runs]}"
SERVICE_NAME="${2:?Usage: $0 <namespace> <service-name> [runs]}"
RUNS="${3:-5}"
POLL_INTERVAL=0.1  # seconds between Ready condition checks
MAX_POLLS=200      # max polls before timeout
STABILIZE_WAIT=8   # seconds to wait between runs (allow Terminating pods to fully clean up)

log() {
  echo "[$(date '+%H:%M:%S')] $*"
}

# macOS date does not support %N; use python3 for millisecond timestamps
timestamp_ms() {
  python3 -c 'import time; print(int(time.time()*1000))'
}

# ---------------------------------------------------------------------------
# Detect resource type and label selector
# ---------------------------------------------------------------------------

detect_resource() {
  # Check if SpinApp CRD exists for this service
  if kubectl get spinapp "${SERVICE_NAME}" -n "${NAMESPACE}" &>/dev/null; then
    RESOURCE_TYPE="spinapp"
    LABEL_SELECTOR="core.spinkube.dev/app-name=${SERVICE_NAME}"
    log "Detected SpinApp (Wasm)"
  else
    RESOURCE_TYPE="deployment"
    LABEL_SELECTOR="app=${SERVICE_NAME}"
    log "Detected Deployment (Container)"
  fi
}

# ---------------------------------------------------------------------------
# Scale to replica 1
# ---------------------------------------------------------------------------

scale_to_one() {
  if [[ "${RESOURCE_TYPE}" == "spinapp" ]]; then
    kubectl patch spinapp "${SERVICE_NAME}" -n "${NAMESPACE}" \
      --type merge -p '{"spec":{"replicas":1}}' &>/dev/null
  else
    kubectl scale "deploy/${SERVICE_NAME}" -n "${NAMESPACE}" --replicas=1 &>/dev/null
  fi
  sleep 3
  kubectl wait --for=condition=ready pod -l "${LABEL_SELECTOR}" \
    -n "${NAMESPACE}" --timeout=60s &>/dev/null
}

# ---------------------------------------------------------------------------
# Restore original replica count
# ---------------------------------------------------------------------------

restore_replicas() {
  local replicas="${1:-2}"
  if [[ "${RESOURCE_TYPE}" == "spinapp" ]]; then
    kubectl patch spinapp "${SERVICE_NAME}" -n "${NAMESPACE}" \
      --type merge -p "{\"spec\":{\"replicas\":${replicas}}}" &>/dev/null
  else
    kubectl scale "deploy/${SERVICE_NAME}" -n "${NAMESPACE}" \
      --replicas="${replicas}" &>/dev/null
  fi
}

# ---------------------------------------------------------------------------
# Measure single recovery
# ---------------------------------------------------------------------------

wait_no_terminating() {
  # Wait until no Terminating pods remain
  for _ in $(seq 1 60); do
    local terminating
    terminating=$(kubectl get pods -n "${NAMESPACE}" -l "${LABEL_SELECTOR}" -o json 2>/dev/null \
      | jq -r '[.items[] | select(.metadata.deletionTimestamp != null) | .metadata.name] | length')
    if [[ "${terminating}" == "0" ]]; then
      return
    fi
    sleep 1
  done
}

measure_recovery() {
  # Ensure no leftover Terminating pods
  wait_no_terminating

  # Get the active (non-terminating) pod
  local old_pod
  old_pod=$(kubectl get pods -n "${NAMESPACE}" -l "${LABEL_SELECTOR}" -o json 2>/dev/null \
    | jq -r '[.items[] | select(.metadata.deletionTimestamp == null)] | .[0].metadata.name')

  # Record start time, then delete pod
  local start_ms
  start_ms=$(timestamp_ms)

  kubectl delete pod "${old_pod}" -n "${NAMESPACE}" \
    --force --grace-period=0 &>/dev/null

  # Poll until a NEW non-terminating pod is Ready
  for i in $(seq 1 "${MAX_POLLS}"); do
    sleep "${POLL_INTERVAL}"

    # Get first non-terminating pod and its Ready status
    local pod_info
    pod_info=$(kubectl get pods -n "${NAMESPACE}" -l "${LABEL_SELECTOR}" -o json 2>/dev/null \
      | jq -r '[.items[] | select(.metadata.deletionTimestamp == null)] | .[0] | "\(.metadata.name),\(.status.conditions // [] | map(select(.type == "Ready")) | .[0].status // "False")"')

    local current_pod="${pod_info%%,*}"
    local ready="${pod_info##*,}"

    # Skip if no pod, null, or still the old pod
    if [[ -z "${current_pod}" || "${current_pod}" == "null" || "${current_pod}" == "${old_pod}" ]]; then
      continue
    fi

    # New pod is Ready — record actual elapsed time
    if [[ "${ready}" == "True" ]]; then
      local end_ms
      end_ms=$(timestamp_ms)
      echo $(( end_ms - start_ms ))
      return
    fi
  done

  # Timeout
  echo "timeout"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

detect_resource

log "Scaling ${SERVICE_NAME} to replica 1..."
scale_to_one

log "Starting availability test: ${RUNS} runs"
echo ""

RESULTS=()

for run in $(seq 1 "${RUNS}"); do
  # Ensure pod is ready and stable
  kubectl wait --for=condition=ready pod -l "${LABEL_SELECTOR}" \
    -n "${NAMESPACE}" --timeout=60s &>/dev/null
  sleep 3

  duration=$(measure_recovery)
  RESULTS+=("${duration}")
  log "Run ${run}/${RUNS}: ${duration}ms"

  # Wait for recovery before next run
  sleep "${STABILIZE_WAIT}"
done

# ---------------------------------------------------------------------------
# Statistics
# ---------------------------------------------------------------------------

echo ""
echo "============================================================"
echo " Availability Test Results"
echo " Namespace:  ${NAMESPACE}"
echo " Service:    ${SERVICE_NAME}"
echo " Type:       ${RESOURCE_TYPE}"
echo " Runs:       ${RUNS}"
echo " Poll interval: ${POLL_INTERVAL}s"
echo "============================================================"
echo ""
echo "Recovery times (ms): ${RESULTS[*]}"

SUM=0
MIN=999999
MAX=0
for v in "${RESULTS[@]}"; do
  SUM=$((SUM + v))
  [[ "${v}" -lt "${MIN}" ]] && MIN=${v}
  [[ "${v}" -gt "${MAX}" ]] && MAX=${v}
done
AVG=$((SUM / ${#RESULTS[@]}))

echo ""
echo "  Average: ${AVG}ms"
echo "  Min:     ${MIN}ms"
echo "  Max:     ${MAX}ms"
echo "  Count:   ${#RESULTS[@]}"
echo ""
echo "============================================================"

# Restore replicas
log "Restoring replica count to 1..."
restore_replicas 1
log "Done."
