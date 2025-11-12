#!/usr/bin/env bash
set -euo pipefail

NS="storage-bench"
SC_NAME="${1:-ceph-sc}"

oc get pods -n "$NS" --no-headers | awk '{print $1}' | grep "$SC_NAME" | while read -r pod; do
  echo "# $pod"
  oc logs -n "$NS" "$pod"
  echo
done
