#!/bin/bash
# =============================================================================
# Smoke Test - Verify cluster + SpinKube + apps are working
# =============================================================================
# Usage: ./scripts/smoke.sh
#
# Checks:
#   1. k3d cluster is running
#   2. SpinKube operator is healthy
#   3. Wasm namespace: Gateway responds
#   4. Containers namespace: Gateway responds
# =============================================================================

set -euo pipefail

PASS=0
FAIL=0

check() {
  local name="$1"
  shift
  if "$@" > /dev/null 2>&1; then
    echo "  [PASS] ${name}"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] ${name}"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Smoke Test ==="
echo ""

# 1. Cluster
echo "--- Cluster ---"
check "k3d cluster exists" k3d cluster list wasm-cluster
check "kubectl reachable" kubectl cluster-info

# 2. SpinKube
echo "--- SpinKube ---"
check "spin-operator running" kubectl get deployment spin-operator-controller-manager -n spin-operator -o jsonpath='{.status.availableReplicas}'
check "RuntimeClass exists" kubectl get runtimeclass wasmtime-spin-v2

# 3. Wasm namespace
echo "--- Wasm namespace ---"
check "wasm pods running" kubectl get pods -n wasm --field-selector=status.phase=Running --no-headers
WASM_GW=$(kubectl get svc -n wasm gateway -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
if [[ -n "${WASM_GW}" ]]; then
  check "wasm gateway responds" kubectl run smoke-wasm --rm -i --restart=Never --image=curlimages/curl -- -sf "http://gateway.wasm.svc.cluster.local/customers"
else
  echo "  [SKIP] wasm gateway (service not found)"
fi

# 4. Containers namespace
echo "--- Containers namespace ---"
check "container pods running" kubectl get pods -n containers --field-selector=status.phase=Running --no-headers
CONTAINER_GW=$(kubectl get svc -n containers gateway -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
if [[ -n "${CONTAINER_GW}" ]]; then
  check "container gateway responds" kubectl run smoke-container --rm -i --restart=Never --image=curlimages/curl -- -sf "http://gateway.containers.svc.cluster.local/customers"
else
  echo "  [SKIP] container gateway (service not found)"
fi

# Summary
echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
