#!/bin/bash
# =============================================================================
# Full Setup - Cluster creation, build, deploy, and smoke test
# =============================================================================
# Usage: ./scripts/setup-all.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_DIR}"

REGISTRY="k3d-myregistry.localhost:5050"

# 1. k3d cluster + SpinKube
echo "=== 1/6 Cluster + SpinKube ==="
if k3d cluster list wasm-cluster > /dev/null 2>&1; then
  echo "  ERROR: Cluster 'wasm-cluster' already exists."
  echo "  Run './scripts/cleanup.sh' first, then re-run this script."
  exit 1
fi
bash spinkube/setup.sh

# 2. PostgreSQL
echo ""
echo "=== 2/6 PostgreSQL ==="
kubectl apply -f k8s/postgres.yaml
kubectl wait --for=condition=ready pod -l app=postgres -n db --timeout=60s

# 3. Spin (Wasm) build & push
echo ""
echo "=== 3/6 Spin build & push ==="
for svc in gateway customer-service order-service; do
  echo "--- spin-crm/${svc} ---"
  (cd "spin-crm/${svc}" && spin build && spin registry push "${REGISTRY}/spin-crm-${svc}:latest" --insecure)
done

# 4. Axum (Container) build & import
echo ""
echo "=== 4/6 Axum build & import ==="
for svc in gateway customer-service order-service; do
  echo "--- axum-crm/${svc} ---"
  docker build -t "axum-crm-${svc}:latest" "axum-crm/${svc}/"
done
k3d image import axum-crm-gateway:latest axum-crm-customer-service:latest axum-crm-order-service:latest -c wasm-cluster

# 5. Deploy
echo ""
echo "=== 5/6 Deploy ==="
kubectl create namespace wasm --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n wasm -f https://github.com/spinframework/spin-operator/releases/download/v0.6.1/spin-operator.shim-executor.yaml
kubectl apply -f k8s/wasm/
kubectl apply -f k8s/containers/

# Wait for pods to be ready
echo "  Waiting for wasm pods..."
kubectl wait --for=condition=ready pod --all -n wasm --timeout=120s
echo "  Waiting for container pods..."
kubectl wait --for=condition=ready pod --all -n containers --timeout=120s

# 6. Smoke test
echo ""
echo "=== 6/6 Smoke test ==="
bash scripts/smoke.sh

echo ""
echo "=== All done ==="
