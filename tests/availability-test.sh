#!/bin/bash
# =============================================================================
# Availability Test - Pod Kill Recovery
# =============================================================================
# Usage: ./availability-test.sh <namespace> <service-name> <port>
#
# Example:
#   ./availability-test.sh wasm gateway 80
#   ./availability-test.sh containers gateway 80
#
# This script:
#   1. Port-forwards the gateway service
#   2. Sends continuous requests recording timestamps
#   3. Kills a pod (kubectl delete pod --force)
#   4. Continues recording until recovery
#   5. Reports: time to first error, downtime duration, time to full recovery
# =============================================================================

set -euo pipefail

NAMESPACE="${1:?Usage: $0 <namespace> <service-name> <port>}"
SERVICE_NAME="${2:?Usage: $0 <namespace> <service-name> <port>}"
SERVICE_PORT="${3:?Usage: $0 <namespace> <service-name> <port>}"
LOCAL_PORT=18080
REQUEST_INTERVAL=0.2  # seconds between requests
PRE_KILL_DURATION=5   # seconds of requests before killing a pod
POST_KILL_DURATION=30 # seconds of requests after killing a pod

RESULTS_DIR="/tmp/availability-test-${NAMESPACE}-$(date +%s)"
mkdir -p "${RESULTS_DIR}"
RESULTS_FILE="${RESULTS_DIR}/results.csv"
SUMMARY_FILE="${RESULTS_DIR}/summary.txt"

echo "timestamp_ms,status,latency_ms" > "${RESULTS_FILE}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# macOS date does not support %N (nanoseconds). Use python3 as fallback.
timestamp_ms() {
  if [[ "$(uname)" == "Darwin" ]]; then
    python3 -c 'import time; print(int(time.time()*1000))'
  else
    date +%s%3N
  fi
}

timestamp_ns() {
  if [[ "$(uname)" == "Darwin" ]]; then
    python3 -c 'import time; print(int(time.time()*1e9))'
  else
    date +%s%N
  fi
}

log() {
  echo "[$(date '+%H:%M:%S')] $*"
}

cleanup() {
  log "Cleaning up..."
  # Kill port-forward process
  if [[ -n "${PF_PID:-}" ]] && kill -0 "${PF_PID}" 2>/dev/null; then
    kill "${PF_PID}" 2>/dev/null || true
    wait "${PF_PID}" 2>/dev/null || true
  fi
  # Kill request loop if still running
  if [[ -n "${REQ_PID:-}" ]] && kill -0 "${REQ_PID}" 2>/dev/null; then
    kill "${REQ_PID}" 2>/dev/null || true
    wait "${REQ_PID}" 2>/dev/null || true
  fi
  log "Done."
}

trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. Start port-forward
# ---------------------------------------------------------------------------

log "Starting port-forward: ${NAMESPACE}/${SERVICE_NAME}:${SERVICE_PORT} -> localhost:${LOCAL_PORT}"
kubectl port-forward -n "${NAMESPACE}" "svc/${SERVICE_NAME}" "${LOCAL_PORT}:${SERVICE_PORT}" &>/dev/null &
PF_PID=$!
sleep 2

# Verify port-forward is working
if ! curl -sf "http://localhost:${LOCAL_PORT}/healthz" > /dev/null 2>&1; then
  log "ERROR: Port-forward not working. Is the service running?"
  exit 1
fi
log "Port-forward established successfully."

# ---------------------------------------------------------------------------
# 2. Continuous request loop (runs in background)
# ---------------------------------------------------------------------------

send_requests() {
  while true; do
    local ts_ms
    ts_ms=$(timestamp_ms)
    local start_ns
    start_ns=$(timestamp_ns)

    local http_code
    http_code=$(curl -sf -o /dev/null -w '%{http_code}' --max-time 2 "http://localhost:${LOCAL_PORT}/healthz" 2>/dev/null || echo "000")

    local end_ns
    end_ns=$(timestamp_ns)
    local latency_ms=$(( (end_ns - start_ns) / 1000000 ))

    echo "${ts_ms},${http_code},${latency_ms}" >> "${RESULTS_FILE}"
    sleep "${REQUEST_INTERVAL}"
  done
}

log "Starting continuous request loop (interval: ${REQUEST_INTERVAL}s)..."
send_requests &
REQ_PID=$!

# ---------------------------------------------------------------------------
# 3. Warm-up: send requests before killing pod
# ---------------------------------------------------------------------------

log "Warming up for ${PRE_KILL_DURATION}s..."
sleep "${PRE_KILL_DURATION}"

# ---------------------------------------------------------------------------
# 4. Kill a pod
# ---------------------------------------------------------------------------

TARGET_POD=$(kubectl get pods -n "${NAMESPACE}" -l "app=${SERVICE_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
             kubectl get pods -n "${NAMESPACE}" -l "core.spinkube.dev/app-name=${SERVICE_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
             kubectl get pods -n "${NAMESPACE}" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [[ -z "${TARGET_POD}" ]]; then
  log "ERROR: Could not find a pod to kill in namespace ${NAMESPACE}"
  exit 1
fi

KILL_TS=$(timestamp_ms)
log "Killing pod: ${TARGET_POD} at timestamp ${KILL_TS}"
kubectl delete pod -n "${NAMESPACE}" "${TARGET_POD}" --force --grace-period=0 &>/dev/null &

# ---------------------------------------------------------------------------
# 5. Continue recording after kill
# ---------------------------------------------------------------------------

log "Continuing requests for ${POST_KILL_DURATION}s after pod kill..."
sleep "${POST_KILL_DURATION}"

# Stop request loop
kill "${REQ_PID}" 2>/dev/null || true
wait "${REQ_PID}" 2>/dev/null || true
REQ_PID=""

# ---------------------------------------------------------------------------
# 6. Analyze results
# ---------------------------------------------------------------------------

log "Analyzing results..."

{
  echo "============================================================"
  echo " Availability Test Results"
  echo " Namespace: ${NAMESPACE}"
  echo " Service:   ${SERVICE_NAME}"
  echo " Pod killed: ${TARGET_POD}"
  echo " Kill timestamp: ${KILL_TS}"
  echo "============================================================"
  echo ""

  TOTAL_REQUESTS=$(tail -n +2 "${RESULTS_FILE}" | wc -l | tr -d ' ')
  SUCCESS_REQUESTS=$(tail -n +2 "${RESULTS_FILE}" | awk -F',' '$2 == "200" { count++ } END { print count+0 }')
  FAILED_REQUESTS=$(tail -n +2 "${RESULTS_FILE}" | awk -F',' '$2 != "200" { count++ } END { print count+0 }')

  echo "Total requests:    ${TOTAL_REQUESTS}"
  echo "Successful (200):  ${SUCCESS_REQUESTS}"
  echo "Failed:            ${FAILED_REQUESTS}"
  echo ""

  if [[ "${FAILED_REQUESTS}" -gt 0 ]]; then
    # Time to first error (relative to pod kill)
    FIRST_ERROR_TS=$(tail -n +2 "${RESULTS_FILE}" | awk -F',' '$2 != "200" { print $1; exit }')
    LAST_ERROR_TS=$(tail -n +2 "${RESULTS_FILE}" | awk -F',' '$2 != "200" { ts=$1 } END { print ts }')

    # Find the first successful request after the last error
    RECOVERY_TS=$(tail -n +2 "${RESULTS_FILE}" | awk -F',' -v last_err="${LAST_ERROR_TS}" '
      $1 > last_err && $2 == "200" { print $1; exit }
    ')

    TIME_TO_FIRST_ERROR=$(( FIRST_ERROR_TS - KILL_TS ))
    DOWNTIME_DURATION=$(( LAST_ERROR_TS - FIRST_ERROR_TS ))

    echo "Time to first error:   ${TIME_TO_FIRST_ERROR} ms (after pod kill)"
    echo "Downtime duration:     ${DOWNTIME_DURATION} ms"

    if [[ -n "${RECOVERY_TS}" ]]; then
      TIME_TO_RECOVERY=$(( RECOVERY_TS - KILL_TS ))
      echo "Time to full recovery: ${TIME_TO_RECOVERY} ms (after pod kill)"
    else
      echo "Time to full recovery: DID NOT RECOVER within test window"
    fi
  else
    echo "No errors detected - zero downtime!"
  fi

  echo ""
  echo "--- Latency Statistics (successful requests only) ---"
  tail -n +2 "${RESULTS_FILE}" | awk -F',' '
    $2 == "200" {
      sum += $3
      count++
      if (count == 1 || $3 < min) min = $3
      if (count == 1 || $3 > max) max = $3
      latencies[count] = $3
    }
    END {
      if (count > 0) {
        printf "  Count:  %d\n", count
        printf "  Avg:    %.1f ms\n", sum / count
        printf "  Min:    %d ms\n", min
        printf "  Max:    %d ms\n", max
      } else {
        print "  No successful requests"
      }
    }
  '

  echo ""
  echo "Raw data: ${RESULTS_FILE}"
  echo "============================================================"
} | tee "${SUMMARY_FILE}"

log "Summary saved to: ${SUMMARY_FILE}"
