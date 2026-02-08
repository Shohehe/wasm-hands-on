#!/bin/bash
# =============================================================================
# Resource Comparison Test - Wasm vs Containers
# =============================================================================
# Usage: ./resource-test.sh [namespace]
#
# Examples:
#   ./resource-test.sh              # Compare both namespaces
#   ./resource-test.sh wasm         # Show only wasm namespace
#   ./resource-test.sh containers   # Show only containers namespace
#
# This script:
#   1. Collects kubectl top pods, pod count, resource requests/limits
#   2. Compares memory and CPU usage between wasm and container namespaces
#   3. Shows how many pods fit in a given resource budget
# =============================================================================

set -euo pipefail

TARGET_NS="${1:-all}"

# Resource budget for comparison (adjust as needed)
BUDGET_CPU_MILLICORES=1000    # 1 vCPU
BUDGET_MEMORY_MI=512          # 512 MiB

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
  echo "[$(date '+%H:%M:%S')] $*"
}

hr() {
  echo "------------------------------------------------------------"
}

collect_namespace_data() {
  local ns="$1"

  echo ""
  echo "============================================================"
  echo " Namespace: ${ns}"
  echo "============================================================"
  echo ""

  # --- Pod Count ---
  local pod_count
  pod_count=$(kubectl get pods -n "${ns}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  echo "Pod count: ${pod_count}"
  echo ""

  # --- Pod Status ---
  echo "--- Pod Status ---"
  kubectl get pods -n "${ns}" -o wide 2>/dev/null || echo "  (unable to list pods)"
  echo ""

  # --- Resource Requests & Limits ---
  echo "--- Resource Requests & Limits ---"
  printf "%-30s %-12s %-12s %-12s %-12s\n" "POD" "CPU_REQ" "CPU_LIM" "MEM_REQ" "MEM_LIM"
  hr

  kubectl get pods -n "${ns}" -o json 2>/dev/null | python3 -c "
import sys, json

data = json.load(sys.stdin)
total_cpu_req = 0
total_cpu_lim = 0
total_mem_req = 0
total_mem_lim = 0

def parse_cpu(val):
    if not val:
        return 0
    if val.endswith('m'):
        return int(val[:-1])
    return int(float(val) * 1000)

def parse_mem(val):
    if not val:
        return 0
    if val.endswith('Mi'):
        return int(val[:-2])
    if val.endswith('Gi'):
        return int(float(val[:-2]) * 1024)
    if val.endswith('Ki'):
        return int(float(val[:-2]) / 1024)
    # bytes
    return int(int(val) / (1024 * 1024))

for pod in data.get('items', []):
    name = pod['metadata']['name']
    for c in pod['spec'].get('containers', []):
        res = c.get('resources', {})
        req = res.get('requests', {})
        lim = res.get('limits', {})
        cpu_req = req.get('cpu', '0')
        cpu_lim = lim.get('cpu', '0')
        mem_req = req.get('memory', '0')
        mem_lim = lim.get('memory', '0')
        total_cpu_req += parse_cpu(cpu_req)
        total_cpu_lim += parse_cpu(cpu_lim)
        total_mem_req += parse_mem(mem_req)
        total_mem_lim += parse_mem(mem_lim)
        print(f'{name:<30} {cpu_req:<12} {cpu_lim:<12} {mem_req:<12} {mem_lim:<12}')

print('-' * 78)
print(f'{\"TOTAL\":<30} {str(total_cpu_req)+\"m\":<12} {str(total_cpu_lim)+\"m\":<12} {str(total_mem_req)+\"Mi\":<12} {str(total_mem_lim)+\"Mi\":<12}')
print()

# Output totals for later use
print(f'__TOTALS__:{total_cpu_req}:{total_cpu_lim}:{total_mem_req}:{total_mem_lim}:{len(data.get(\"items\", []))}')
" 2>/dev/null
  echo ""

  # --- Actual Resource Usage (kubectl top) ---
  echo "--- Actual Resource Usage (kubectl top pods) ---"
  if kubectl top pods -n "${ns}" 2>/dev/null; then
    echo ""
    echo "--- Aggregate Usage ---"
    kubectl top pods -n "${ns}" --no-headers 2>/dev/null | awk '
      {
        # Parse CPU (e.g., "1m", "100m", "0")
        cpu = $2
        gsub(/m/, "", cpu)
        total_cpu += cpu

        # Parse Memory (e.g., "10Mi", "128Mi")
        mem = $3
        gsub(/Mi/, "", mem)
        total_mem += mem

        count++
      }
      END {
        printf "  Total CPU usage: %dm\n", total_cpu
        printf "  Total Memory usage: %dMi\n", total_mem
        printf "  Avg CPU per pod: %.1fm\n", total_cpu / count
        printf "  Avg Memory per pod: %.1fMi\n", total_mem / count
      }
    '
  else
    echo "  (metrics-server not available or no data yet)"
  fi
  echo ""
}

compare_namespaces() {
  echo ""
  echo "============================================================"
  echo " Comparison: wasm vs containers"
  echo "============================================================"
  echo ""

  # Collect data from both namespaces via JSON
  local wasm_data containers_data
  wasm_data=$(kubectl get pods -n wasm -o json 2>/dev/null)
  containers_data=$(kubectl get pods -n containers -o json 2>/dev/null)

  python3 -c "
import json, sys

budget_cpu = ${BUDGET_CPU_MILLICORES}
budget_mem = ${BUDGET_MEMORY_MI}

def parse_cpu(val):
    if not val:
        return 0
    if val.endswith('m'):
        return int(val[:-1])
    return int(float(val) * 1000)

def parse_mem(val):
    if not val:
        return 0
    if val.endswith('Mi'):
        return int(val[:-2])
    if val.endswith('Gi'):
        return int(float(val[:-2]) * 1024)
    if val.endswith('Ki'):
        return int(float(val[:-2]) / 1024)
    return int(int(val) / (1024 * 1024))

def get_totals(data):
    pods = data.get('items', [])
    total_cpu_req = 0
    total_cpu_lim = 0
    total_mem_req = 0
    total_mem_lim = 0
    for pod in pods:
        for c in pod['spec'].get('containers', []):
            res = c.get('resources', {})
            req = res.get('requests', {})
            lim = res.get('limits', {})
            total_cpu_req += parse_cpu(req.get('cpu', '0'))
            total_cpu_lim += parse_cpu(lim.get('cpu', '0'))
            total_mem_req += parse_mem(req.get('memory', '0'))
            total_mem_lim += parse_mem(lim.get('memory', '0'))
    return {
        'pod_count': len(pods),
        'cpu_req': total_cpu_req,
        'cpu_lim': total_cpu_lim,
        'mem_req': total_mem_req,
        'mem_lim': total_mem_lim,
    }

wasm = json.loads('''$(echo "${wasm_data}")''')
containers = json.loads('''$(echo "${containers_data}")''')

w = get_totals(wasm)
c = get_totals(containers)

print(f'                        {\"wasm\":>12}  {\"containers\":>12}  {\"ratio\":>10}')
print('-' * 52)
print(f'{\"Pod count\":<24}{w[\"pod_count\"]:>12}  {c[\"pod_count\"]:>12}')
print(f'{\"CPU requests (total)\":<24}{str(w[\"cpu_req\"])+\"m\":>12}  {str(c[\"cpu_req\"])+\"m\":>12}  {c[\"cpu_req\"]/max(w[\"cpu_req\"],1):.1f}x')
print(f'{\"CPU limits (total)\":<24}{str(w[\"cpu_lim\"])+\"m\":>12}  {str(c[\"cpu_lim\"])+\"m\":>12}  {c[\"cpu_lim\"]/max(w[\"cpu_lim\"],1):.1f}x')
print(f'{\"Memory requests\":<24}{str(w[\"mem_req\"])+\"Mi\":>12}  {str(c[\"mem_req\"])+\"Mi\":>12}  {c[\"mem_req\"]/max(w[\"mem_req\"],1):.1f}x')
print(f'{\"Memory limits\":<24}{str(w[\"mem_lim\"])+\"Mi\":>12}  {str(c[\"mem_lim\"])+\"Mi\":>12}  {c[\"mem_lim\"]/max(w[\"mem_lim\"],1):.1f}x')
print()

# Pods per budget
if w['pod_count'] > 0 and c['pod_count'] > 0:
    w_cpu_per_pod = w['cpu_req'] / w['pod_count']
    w_mem_per_pod = w['mem_req'] / w['pod_count']
    c_cpu_per_pod = c['cpu_req'] / c['pod_count']
    c_mem_per_pod = c['mem_req'] / c['pod_count']

    w_pods_by_cpu = int(budget_cpu / max(w_cpu_per_pod, 1))
    w_pods_by_mem = int(budget_mem / max(w_mem_per_pod, 1))
    c_pods_by_cpu = int(budget_cpu / max(c_cpu_per_pod, 1))
    c_pods_by_mem = int(budget_mem / max(c_mem_per_pod, 1))

    w_pods_fit = min(w_pods_by_cpu, w_pods_by_mem)
    c_pods_fit = min(c_pods_by_cpu, c_pods_by_mem)

    print(f'--- Resource Budget Analysis (CPU: {budget_cpu}m, Memory: {budget_mem}Mi) ---')
    print()
    print(f'  Avg CPU request per pod:')
    print(f'    wasm:       {w_cpu_per_pod:.0f}m')
    print(f'    containers: {c_cpu_per_pod:.0f}m')
    print()
    print(f'  Avg Memory request per pod:')
    print(f'    wasm:       {w_mem_per_pod:.0f}Mi')
    print(f'    containers: {c_mem_per_pod:.0f}Mi')
    print()
    print(f'  Max pods that fit in budget:')
    print(f'    wasm:       {w_pods_fit} pods  (CPU-limited: {w_pods_by_cpu}, Mem-limited: {w_pods_by_mem})')
    print(f'    containers: {c_pods_fit} pods  (CPU-limited: {c_pods_by_cpu}, Mem-limited: {c_pods_by_mem})')
    print(f'    Density advantage: {w_pods_fit/max(c_pods_fit,1):.1f}x more Wasm pods')
print()
" 2>/dev/null || echo "  (comparison requires both namespaces to have running pods)"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

log "Resource comparison test starting..."
echo ""

if [[ "${TARGET_NS}" == "all" ]]; then
  collect_namespace_data "wasm"
  collect_namespace_data "containers"
  compare_namespaces
else
  collect_namespace_data "${TARGET_NS}"
fi

log "Resource test complete."
