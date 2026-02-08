#!/bin/bash
# =============================================================================
# Cleanup - Remove cluster, images, and build artifacts
# =============================================================================
# Usage: ./scripts/cleanup.sh [--all]
#
# Default: Delete k3d cluster + registry + port-forward
# --all:   Also remove Rust build artifacts and Docker images
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_DIR}"

ALL=false
if [[ "${1:-}" == "--all" ]]; then
  ALL=true
fi

# 1. Kill port-forward processes (scoped to wasm-cluster ports)
echo "=== Stopping port-forward processes ==="
pkill -f "kubectl port-forward -n (wasm|containers)" 2>/dev/null && echo "  Stopped" || echo "  None running"

# 2. Delete k3d cluster
echo "=== Deleting k3d cluster ==="
if k3d cluster list wasm-cluster > /dev/null 2>&1; then
  k3d cluster delete wasm-cluster
  echo "  Deleted"
else
  echo "  Cluster not found, skipping"
fi

# 3. Delete k3d registry (created separately via --registry-create)
echo "=== Deleting k3d registry ==="
if docker ps -a --format '{{.Names}}' | grep -q '^k3d-myregistry'; then
  k3d registry delete myregistry.localhost
  echo "  Deleted"
else
  echo "  Registry not found, skipping"
fi

if [[ "${ALL}" == true ]]; then
  # 4. Remove Docker images
  echo "=== Removing Docker images ==="
  for img in axum-crm-gateway axum-crm-customer-service axum-crm-order-service; do
    docker rmi "${img}:latest" 2>/dev/null && echo "  Removed ${img}" || true
  done

  # 5. Remove Rust build artifacts
  echo "=== Removing build artifacts ==="
  find spin-crm axum-crm -name target -type d -exec rm -rf {} + 2>/dev/null
  echo "  Done"
fi

echo ""
echo "=== Cleanup complete ==="
