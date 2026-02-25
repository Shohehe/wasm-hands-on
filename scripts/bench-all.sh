#!/bin/bash
# =============================================================================
# Full Benchmark - Run all tests with structured result output
# =============================================================================
# Usage: ./scripts/bench-all.sh
#
# Results are saved to results/<timestamp>/ directory with JSON summaries.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_DIR}"

WASM_PORT=9090
CONTAINER_PORT=9091
PF_PIDS=()

# Create timestamped results directory
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
RESULTS_DIR="results/${TIMESTAMP}"
mkdir -p "${RESULTS_DIR}"

log() {
  echo "[$(date '+%H:%M:%S')] $*"
}

cleanup() {
  echo ""
  echo "=== Stopping port-forwards ==="
  for pid in "${PF_PIDS[@]}"; do
    kill "${pid}" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. Start port-forwards
# ---------------------------------------------------------------------------
echo "=== Starting port-forwards ==="
kubectl port-forward -n wasm svc/gateway "${WASM_PORT}:80" &>/dev/null &
PF_PIDS+=($!)
kubectl port-forward -n containers svc/gateway "${CONTAINER_PORT}:80" &>/dev/null &
PF_PIDS+=($!)
sleep 2

# Verify
for url in "http://localhost:${WASM_PORT}/healthz" "http://localhost:${CONTAINER_PORT}/healthz"; do
  if ! curl -sf "${url}" > /dev/null 2>&1; then
    echo "  ERROR: ${url} not reachable"
    exit 1
  fi
done
echo "  Ready (wasm=:${WASM_PORT}, containers=:${CONTAINER_PORT})"
echo "  Results dir: ${RESULTS_DIR}"

# ---------------------------------------------------------------------------
# 2. Error Path Test (validates both implementations handle edge cases)
# ---------------------------------------------------------------------------
echo ""
echo "=== 1/8 Error Path Test (Wasm) ==="
k6 run -e BASE_URL="http://localhost:${WASM_PORT}" \
  -e SUMMARY_JSON="${RESULTS_DIR}/error-wasm.json" \
  tests/error-test.js 2>&1 | tee "${RESULTS_DIR}/error-wasm.txt"

echo ""
echo "=== 2/8 Error Path Test (Container) ==="
k6 run -e BASE_URL="http://localhost:${CONTAINER_PORT}" \
  -e SUMMARY_JSON="${RESULTS_DIR}/error-container.json" \
  tests/error-test.js 2>&1 | tee "${RESULTS_DIR}/error-container.txt"

# ---------------------------------------------------------------------------
# 3. CRUD Load Test
# ---------------------------------------------------------------------------
echo ""
echo "=== 3/8 CRUD Load Test (Wasm) ==="
k6 run -e BASE_URL="http://localhost:${WASM_PORT}" \
  -e SUMMARY_JSON="${RESULTS_DIR}/crud-wasm.json" \
  tests/load-test.js 2>&1 | tee "${RESULTS_DIR}/crud-wasm.txt"

echo ""
echo "=== 4/8 CRUD Load Test (Container) ==="
k6 run -e BASE_URL="http://localhost:${CONTAINER_PORT}" \
  -e SUMMARY_JSON="${RESULTS_DIR}/crud-container.json" \
  tests/load-test.js 2>&1 | tee "${RESULTS_DIR}/crud-container.txt"

# ---------------------------------------------------------------------------
# 4. CPU Bound Test
# ---------------------------------------------------------------------------
echo ""
echo "=== 5/8 CPU Bound Test (Wasm) ==="
k6 run -e BASE_URL="http://localhost:${WASM_PORT}" \
  -e SUMMARY_JSON="${RESULTS_DIR}/cpu-wasm.json" \
  tests/cpu-bound-test.js 2>&1 | tee "${RESULTS_DIR}/cpu-wasm.txt"

echo ""
echo "=== 6/8 CPU Bound Test (Container) ==="
k6 run -e BASE_URL="http://localhost:${CONTAINER_PORT}" \
  -e SUMMARY_JSON="${RESULTS_DIR}/cpu-container.json" \
  tests/cpu-bound-test.js 2>&1 | tee "${RESULTS_DIR}/cpu-container.txt"

# ---------------------------------------------------------------------------
# 5. Scalability Test
# ---------------------------------------------------------------------------
echo ""
echo "=== 7/8 Scalability Test (Wasm) ==="
k6 run -e BASE_URL="http://localhost:${WASM_PORT}" \
  -e SUMMARY_JSON="${RESULTS_DIR}/scale-wasm.json" \
  tests/scale-test.js 2>&1 | tee "${RESULTS_DIR}/scale-wasm.txt"

echo ""
echo "=== 8/8 Scalability Test (Container) ==="
k6 run -e BASE_URL="http://localhost:${CONTAINER_PORT}" \
  -e SUMMARY_JSON="${RESULTS_DIR}/scale-container.json" \
  tests/scale-test.js 2>&1 | tee "${RESULTS_DIR}/scale-container.txt"

# ---------------------------------------------------------------------------
# 6. Availability Test (needs direct kubectl, stop port-forwards)
# ---------------------------------------------------------------------------
cleanup
PF_PIDS=()
trap - EXIT

echo ""
echo "=== Availability Test (Pod Recovery) ==="
echo "--- Wasm ---"
bash tests/availability-test.sh wasm gateway 5 2>&1 | tee "${RESULTS_DIR}/availability-wasm.txt"
echo ""
echo "--- Containers ---"
bash tests/availability-test.sh containers gateway 5 2>&1 | tee "${RESULTS_DIR}/availability-container.txt"

# ---------------------------------------------------------------------------
# 7. Cold Start Test
# ---------------------------------------------------------------------------
echo ""
echo "=== Cold Start Test (Scale 0 -> 1) ==="
echo "--- Wasm ---"
bash tests/coldstart-test.sh wasm gateway 5 2>&1 | tee "${RESULTS_DIR}/coldstart-wasm.txt"
echo ""
echo "--- Containers ---"
bash tests/coldstart-test.sh containers gateway 5 2>&1 | tee "${RESULTS_DIR}/coldstart-container.txt"

# ---------------------------------------------------------------------------
# 8. Resource Test
# ---------------------------------------------------------------------------
echo ""
echo "=== Resource Comparison ==="
bash tests/resource-test.sh 2>&1 | tee "${RESULTS_DIR}/resource-comparison.txt"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " All benchmarks complete"
echo " Results saved to: ${RESULTS_DIR}/"
echo "============================================================"
echo ""
echo "Files:"
ls -1 "${RESULTS_DIR}/"
echo ""

# Generate comparison summary from JSON files
if command -v python3 &>/dev/null; then
  python3 -c "
import json, os, sys

results_dir = '${RESULTS_DIR}'
comparisons = [
    ('CRUD Load', 'crud-wasm.json', 'crud-container.json', 'http_req_duration'),
    ('CPU Bound', 'cpu-wasm.json', 'cpu-container.json', 'http_req_duration'),
    ('Scalability', 'scale-wasm.json', 'scale-container.json', 'http_req_duration'),
]

print('============================================================')
print(' Quick Comparison (p95 latency, ms)')
print('============================================================')
print(f'{\"Test\":<20} {\"Wasm\":>10} {\"Container\":>10} {\"Ratio\":>10}')
print('-' * 52)

for label, wasm_file, container_file, metric in comparisons:
    wasm_path = os.path.join(results_dir, wasm_file)
    container_path = os.path.join(results_dir, container_file)
    if not (os.path.exists(wasm_path) and os.path.exists(container_path)):
        continue
    try:
        with open(wasm_path) as f:
            wasm_data = json.load(f)
        with open(container_path) as f:
            container_data = json.load(f)
        w = wasm_data['metrics'][metric]['values']['p(95)']
        c = container_data['metrics'][metric]['values']['p(95)']
        ratio = w / c if c > 0 else 0
        print(f'{label:<20} {w:>10.2f} {c:>10.2f} {ratio:>9.2f}x')
    except (KeyError, json.JSONDecodeError):
        print(f'{label:<20} {\"N/A\":>10} {\"N/A\":>10}')

print('============================================================')
print()
" 2>/dev/null || true
fi
