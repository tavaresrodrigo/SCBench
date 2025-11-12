#!/usr/bin/env bash
set -euo pipefail

NS="storage-bench"
SC_NAME="${1:-ceph-sc}"
OUT_FILE="${2:-./tables/results.csv}"

# header if file doesn’t exist
if [ ! -f "$OUT_FILE" ]; then
  echo "tool,replicas,storageClass,p99_ns" > "$OUT_FILE"
fi

COUNT=0
oc get pods -n "$NS" --no-headers | awk '{print $1}' | grep "$SC_NAME" | while read -r pod; do
  LOGS=$(oc logs -n "$NS" "$pod")
  P99=$(echo "$LOGS" | grep -Eo '(p99|99th)[^0-9]*[0-9]+' | grep -Eo '[0-9]+' | head -n1)
  COUNT=$((COUNT+1))
  echo "etcd-perf,$COUNT,$SC_NAME,${P99:-N/A}" >> "$OUT_FILE"
done
