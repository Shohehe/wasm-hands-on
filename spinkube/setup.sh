#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== k3d cluster (with Wasm shim + local registry) ==="
k3d cluster create wasm-cluster \
  --image ghcr.io/spinframework/containerd-shim-spin/k3d:v0.22.0 \
  --port "8083:80@loadbalancer" \
  --agents 2 \
  --registry-create myregistry:5050

echo "=== cert-manager ==="
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.3/cert-manager.yaml
kubectl wait --for=condition=available --timeout=300s deployment/cert-manager-webhook -n cert-manager

echo "=== RuntimeClass ==="
kubectl apply -f https://github.com/spinframework/spin-operator/releases/download/v0.6.1/spin-operator.runtime-class.yaml

echo "=== SpinApp CRDs ==="
kubectl apply -f https://github.com/spinframework/spin-operator/releases/download/v0.6.1/spin-operator.crds.yaml

echo "=== Spin Operator ==="
helm install spin-operator \
  --namespace spin-operator \
  --create-namespace \
  --version 0.6.1 \
  --wait \
  oci://ghcr.io/spinframework/charts/spin-operator

echo "=== Shim Executor ==="
kubectl apply -f https://github.com/spinframework/spin-operator/releases/download/v0.6.1/spin-operator.shim-executor.yaml

echo ""
echo "=== Cluster + SpinKube ready ==="
