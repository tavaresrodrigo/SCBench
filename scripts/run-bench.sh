#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <overlay-path> [parallel] [sc-name]"
  exit 1
fi

NS="storage-bench"
OVERLAY="$1"        # e.g. kustomize/overlays/ceph-sc
PARALLEL="${2:-5}"  # how many jobs to run at once
SC_NAME="${3:-ceph-sc}"

oc get ns "$NS" >/dev/null 2>&1 || oc create ns "$NS"

# 1) create PVC + base job from the overlay
# oc can handle kustomize directly
oc apply -k "$OVERLAY" -n "$NS"

# 2) create N jobs that all mount the same PVC at /var/lib/etcd
for i in $(seq 1 "$PARALLEL"); do
  JOB_NAME="etcd-perf-${SC_NAME}-${i}"

  # we still render with kustomize to tweak the job name
  kustomize build "$OVERLAY" \
  | yq "(. | select(.kind == \"Job\")).metadata.name = \"$JOB_NAME\" |
        (. | select(.kind == \"Job\")).spec.template.spec.containers[0].name = \"etcd-perf-${SC_NAME}-${i}\"" \
  | oc apply -n "$NS" -f -
done

echo "Created $PARALLEL jobs in namespace $NS using StorageClass $SC_NAME (shared PVC)."
