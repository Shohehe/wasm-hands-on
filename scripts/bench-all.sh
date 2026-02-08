#!/bin/bash
# =============================================================================
# Full Benchmark - Run all tests (CRUD, CPU-bound, availability, resource)
# =============================================================================
# Usage: ./scripts/bench-all.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_DIR}"

WASM_PORT=9090
CONTAINER_PORT=9091
PF_PIDS=()

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

# ---------------------------------------------------------------------------
# 2. CRUD Load Test
# ---------------------------------------------------------------------------
echo ""
echo "=== 1/5 CRUD Load Test (Wasm) ==="
k6 run -e BASE_URL="http://localhost:${WASM_PORT}" tests/load-test.js

echo ""
echo "=== 2/5 CRUD Load Test (Container) ==="
k6 run -e BASE_URL="http://localhost:${CONTAINER_PORT}" tests/load-test.js

# ---------------------------------------------------------------------------
# 3. CPU Bound Test
# ---------------------------------------------------------------------------
echo ""
echo "=== 3/5 CPU Bound Test (Wasm) ==="
k6 run -e BASE_URL="http://localhost:${WASM_PORT}" tests/cpu-bound-test.js

echo ""
echo "=== 4/5 CPU Bound Test (Container) ==="
k6 run -e BASE_URL="http://localhost:${CONTAINER_PORT}" tests/cpu-bound-test.js

# ---------------------------------------------------------------------------
# 4. Availability Test
# ---------------------------------------------------------------------------
# Stop port-forwards before availability test (it manages its own)
cleanup
PF_PIDS=()
trap - EXIT

echo ""
echo "=== 5/5 Availability Test ==="
echo "--- Wasm ---"
bash tests/availability-test.sh wasm gateway 80
echo ""
echo "--- Containers ---"
bash tests/availability-test.sh containers gateway 80

# ---------------------------------------------------------------------------
# 5. Resource Test
# ---------------------------------------------------------------------------
echo ""
echo "=== Bonus: Resource Comparison ==="
bash tests/resource-test.sh

echo ""
echo "=== All benchmarks complete ==="
