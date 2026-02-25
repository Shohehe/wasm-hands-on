#!/bin/bash
# =============================================================================
# Cold Start Test - Scale 0 → 1 startup time measurement
# =============================================================================
# Usage: ./coldstart-test.sh <namespace> <service-name> [runs]
#
# Example:
#   ./coldstart-test.sh wasm gateway 5
#   ./coldstart-test.sh containers gateway 5
#
# This script:
#   1. Scales the target to 0 replicas
#   2. Waits for pod termination
#   3. Scales to 1 replica and measures time to Ready
#   4. Repeats N times and reports statistics
#
# This measures true cold start — no warm pods, no cached connections.
# =============================================================================

set -euo pipefail

NAMESPACE="${1:?Usage: $0 <namespace> <service-name> [runs]}"
SERVICE_NAME="${2:?Usage: $0 <namespace> <service-name> [runs]}"
RUNS="${3:-5}"
POLL_INTERVAL=0.1
MAX_POLLS=600  # 60 seconds max wait

log() {
  echo "[$(date '+%H:%M:%S')] $*"
}

timestamp_ms() {
  python3 -c 'import time; print(int(time.time()*1000))'
}

# ---------------------------------------------------------------------------
# Detect resource type
# ---------------------------------------------------------------------------

detect_resource() {
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
# Scale helpers
# ---------------------------------------------------------------------------

scale_to() {
  local replicas="$1"
  if [[ "${RESOURCE_TYPE}" == "spinapp" ]]; then
    kubectl patch spinapp "${SERVICE_NAME}" -n "${NAMESPACE}" \
      --type merge -p "{\"spec\":{\"replicas\":${replicas}}}" &>/dev/null
  else
    kubectl scale "deploy/${SERVICE_NAME}" -n "${NAMESPACE}" --replicas="${replicas}" &>/dev/null
  fi
}

wait_no_pods() {
  for _ in $(seq 1 120); do
    local count
    count=$(kubectl get pods -n "${NAMESPACE}" -l "${LABEL_SELECTOR}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${count}" == "0" ]]; then
      return
    fi
    sleep 0.5
  done
  log "WARNING: Timed out waiting for pods to terminate"
}

# ---------------------------------------------------------------------------
# Measure single cold start
# ---------------------------------------------------------------------------

measure_coldstart() {
  # Scale to 0 and wait for full termination
  scale_to 0
  wait_no_pods

  # Record start time, then scale to 1
  local start_ms
  start_ms=$(timestamp_ms)
  scale_to 1

  # Poll until pod is Ready
  for _ in $(seq 1 "${MAX_POLLS}"); do
    sleep "${POLL_INTERVAL}"

    local ready
    ready=$(kubectl get pods -n "${NAMESPACE}" -l "${LABEL_SELECTOR}" -o json 2>/dev/null \
      | jq -r '[.items[] | select(.metadata.deletionTimestamp == null)] | .[0].status.conditions // [] | map(select(.type == "Ready")) | .[0].status // "False"')

    if [[ "${ready}" == "True" ]]; then
      local end_ms
      end_ms=$(timestamp_ms)
      echo $(( end_ms - start_ms ))
      return
    fi
  done

  echo "timeout"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

detect_resource

log "Starting cold start test: ${RUNS} runs (scale 0 -> 1)"
echo ""

RESULTS=()

for run in $(seq 1 "${RUNS}"); do
  duration=$(measure_coldstart)
  RESULTS+=("${duration}")
  log "Run ${run}/${RUNS}: ${duration}ms"
done

# ---------------------------------------------------------------------------
# Statistics
# ---------------------------------------------------------------------------

echo ""
echo "============================================================"
echo " Cold Start Test Results"
echo " Namespace:  ${NAMESPACE}"
echo " Service:    ${SERVICE_NAME}"
echo " Type:       ${RESOURCE_TYPE}"
echo " Runs:       ${RUNS}"
echo "============================================================"
echo ""
echo "Cold start times (ms): ${RESULTS[*]}"

SUM=0
MIN=999999
MAX=0
for v in "${RESULTS[@]}"; do
  if [[ "${v}" == "timeout" ]]; then
    log "WARNING: Timeout detected, skipping in statistics"
    continue
  fi
  SUM=$((SUM + v))
  [[ "${v}" -lt "${MIN}" ]] && MIN=${v}
  [[ "${v}" -gt "${MAX}" ]] && MAX=${v}
done

COUNT=0
for v in "${RESULTS[@]}"; do
  [[ "${v}" != "timeout" ]] && COUNT=$((COUNT + 1))
done

if [[ "${COUNT}" -gt 0 ]]; then
  AVG=$((SUM / COUNT))
  echo ""
  echo "  Average: ${AVG}ms"
  echo "  Min:     ${MIN}ms"
  echo "  Max:     ${MAX}ms"
  echo "  Count:   ${COUNT}"
fi

echo ""
echo "============================================================"

# Restore to 1 replica
scale_to 1
kubectl wait --for=condition=ready pod -l "${LABEL_SELECTOR}" \
  -n "${NAMESPACE}" --timeout=120s &>/dev/null
log "Restored to 1 replica. Done."
