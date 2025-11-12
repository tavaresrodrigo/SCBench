#!/usr/bin/env bash
set -euo pipefail

# SCBench - per-pod PVC mode, clean awk parser, updated CSV format (<10ms column)

if [ $# -lt 2 ]; then
  echo "usage: $0 <storage-class-name> <parallel> [summary_csv] [details_csv]" >&2
  exit 1
fi

SC_NAME="$1"
PARALLEL="$2"
SUMMARY_CSV="${3:-./tables/summary.csv}"
DETAILS_CSV="${4:-./tables/details.csv}"

NS="${NS:-storage-bench}"
BASE_DIR="${BASE_DIR:-kustomize/base}"
AGG="${AGG:-max}"
THRESH_NS="${THRESH_NS:-10000000}"
KEEP="${KEEP:-0}"

mkdir -p "$(dirname "$SUMMARY_CSV")" "$(dirname "$DETAILS_CSV")"
[ -f "$SUMMARY_CSV" ] || echo "Parallel Replicas,Storage Backend,99thP ns,<10ms" > "$SUMMARY_CSV"
[ -f "$DETAILS_CSV" ] || echo "Parallel Replicas,pod,storageClass,p99_ns,< 10ms" > "$DETAILS_CSV"

oc get ns "$NS" >/dev/null 2>&1 || oc create ns "$NS" >/dev/null

RUN_ID="$(date +%s)"
JOB_NAMES=()
PVC_NAMES=()

cleanup() {
  if [ "${KEEP}" != "1" ]; then
    echo
    echo "🧹 Cleaning up resources for run ${RUN_ID}..."
    for JOB in "${JOB_NAMES[@]:-}"; do
      oc delete job "$JOB" -n "$NS" --ignore-not-found --wait=true >/dev/null 2>&1 || true
    done
    for PVC in "${PVC_NAMES[@]:-}"; do
      oc delete pvc "$PVC" -n "$NS" --ignore-not-found --wait=true >/dev/null 2>&1 || true
    done
    oc delete ns "$NS"
    echo "✅ Cleanup completed."
  else
    echo
    echo "ℹ️ KEEP=1 set — resources retained:"
    [ ${#PVC_NAMES[@]:-0} -gt 0 ] && printf "   PVCs: %s\n" "${PVC_NAMES[@]}"
    [ ${#JOB_NAMES[@]:-0} -gt 0 ] && printf "   Jobs: %s\n" "${JOB_NAMES[@]}"
  fi
}
trap cleanup EXIT

# Create one PVC per pod
for i in $(seq 1 "$PARALLEL"); do
  PVC_NAME="bench-pvc-${SC_NAME}-${RUN_ID}-${i}"
  PVC_NAMES+=("$PVC_NAME")
  oc kustomize "$BASE_DIR" \
  | yq eval "select(.kind==\"PersistentVolumeClaim\") | .metadata.name = \"${PVC_NAME}\" | .spec.storageClassName = \"${SC_NAME}\"" - \
  | oc create -n "$NS" -f - >/dev/null
done

# Create jobs, each mounts its own PVC
for i in $(seq 1 "$PARALLEL"); do
  JOB_NAME="etcd-perf-${SC_NAME}-${RUN_ID}-${i}"
  JOB_NAMES+=("$JOB_NAME")
  PVC_NAME="bench-pvc-${SC_NAME}-${RUN_ID}-${i}"

  oc kustomize "$BASE_DIR" \
  | yq eval "
      select(.kind==\"Job\") |
      .metadata.name = \"${JOB_NAME}\" |
      .metadata.labels.\"bench.tool\" = \"fio\" |
      .metadata.labels.\"bench.sc\" = \"${SC_NAME}\" |
      .metadata.labels.\"bench.run\" = \"${RUN_ID}\" |
      .spec.template.metadata.labels.\"bench.tool\" = \"fio\" |
      .spec.template.metadata.labels.\"bench.sc\" = \"${SC_NAME}\" |
      .spec.template.metadata.labels.\"bench.run\" = \"${RUN_ID}\" |
      (.spec.template.spec.volumes[]? | select(.name == \"etcd-data\").persistentVolumeClaim.claimName) = \"${PVC_NAME}\" |
      .spec.template.spec.containers[0].name = \"${JOB_NAME}\"
    " - \
  | oc create -n "$NS" -f - >/dev/null
done

echo
echo "▶ Created ${PARALLEL} PVCs and ${PARALLEL} jobs in ${NS} for ${SC_NAME}"
echo "▶ Watching pods (Ctrl+C to stop; script will continue waiting)..."
echo

oc get pods -n "$NS" -l "bench.run=${RUN_ID}" -w --no-headers &
WATCH_PID=$!

for JOB in "${JOB_NAMES[@]}"; do
  echo "⏳ Waiting for job/$JOB..."
  oc wait --for=condition=complete "job/$JOB" -n "$NS" --timeout=30m >/dev/null
done

kill "$WATCH_PID" >/dev/null 2>&1 || true
echo
echo "✅ All jobs completed."
echo

# --- JSON parsing helpers (clean awk, no warnings) ---
extract_json() { awk 'found{print} /^[[:space:]]*\{/{found=1}'; }

parse_p99_from_json() {
  local json
  json="$(cat)"

  local paths=(
    '.jobs[0].sync.clat_ns.percentile."99.000000"'
    '.jobs[0].sync.lat_ns.percentile."99.000000"'
    '.jobs[0].write.clat_ns.percentile."99.000000"'
    '.jobs[0].write.lat_ns.percentile."99.000000"'
    '.jobs[0].clat_ns.percentile."99.000000"'
    '.jobs[0].lat_ns.percentile."99.000000"'
  )
  local val p
  for p in "${paths[@]}"; do
    val="$(printf '%s' "$json" | yq -p=json -o=y "$p" - 2>/dev/null || true)"
    if [[ -n "$val" && "$val" != "null" && "$val" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$val"
      return 0
    fi
  done

  val="$(printf '%s' "$json" | awk 'match($0, /99\.000000[[:space:]]*:[[:space:]]*([0-9]+)/, m){print m[1]; exit}')"
  if [[ -n "$val" && "$val" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$val"
    return 0
  fi
  return 1
}

get_fio_json() {
  local pod="$1"
  local logs json
  for _ in 1 2 3 4 5; do
    logs="$(oc logs -n "$NS" "$pod" 2>/dev/null || true)"; [ -n "$logs" ] && break; sleep 1
  done
  json="$(printf "%s\n" "${logs:-}" | extract_json || true)"
  if [ -z "$json" ]; then
    json="$(oc exec -n "$NS" "$pod" -- sh -c 'cat /tmp/fio.out 2>/dev/null || true' 2>/dev/null || true)"
  fi
  printf "%s" "${json:-}"
}
# -----------------------------------------------------

P99_VALUES=()
COUNT=0
for JOB in "${JOB_NAMES[@]}"; do
  COUNT=$((COUNT + 1))
  POD="$(oc get pods -n "$NS" -l "job-name=${JOB}" -o name | head -n1 || true)"
  if [ -z "$POD" ]; then
    echo "${COUNT},,${SC_NAME},N/A,N/A" >> "$DETAILS_CSV"
    continue
  fi

  JSON_BLOCK="$(get_fio_json "$POD" || true)"
  P99=""
  if [ -n "$JSON_BLOCK" ]; then
    P99="$(printf '%s\n' "$JSON_BLOCK" | parse_p99_from_json | tr -d '\r' | head -n1 || true)"
  fi

  if [ -z "${P99:-}" ]; then
    LOGS="$(oc logs -n "$NS" "$POD" 2>/dev/null || true)"
    P99="$(printf "%s\n" "$LOGS" | sed -n 's/^INFO: 99th percentile of fsync is \([0-9][0-9]*\) ns/\1/p' | head -n1)"
    [ -z "${P99:-}" ] && P99="$(printf "%s\n" "$LOGS" | sed -n 's/^WARN: 99th percentile of the fsync is greater.* is \([0-9][0-9]*\) ns.*/\1/p' | head -n1)"
  fi

  [[ "${P99:-}" =~ ^[0-9]+$ ]] || unset P99

  STATUS="N/A"
  if [ -n "${P99:-}" ]; then
    [ "$P99" -ge "$THRESH_NS" ] && STATUS="NO" || STATUS="YES"
    P99_VALUES+=("$P99")
    echo "${COUNT},${POD#pod/},${SC_NAME},${P99},${STATUS}" >> "$DETAILS_CSV"
  else
    echo "${COUNT},${POD#pod/},${SC_NAME},N/A,N/A" >> "$DETAILS_CSV"
  fi
done

summary_value="N/A"
if [ ${#P99_VALUES[@]} -gt 0 ]; then
  case "$AGG" in
    max) summary_value="$(printf '%s\n' "${P99_VALUES[@]}" | sort -n | tail -n1)";;
    min) summary_value="$(printf '%s\n' "${P99_VALUES[@]}" | sort -n | head -n1)";;
    avg) sum=0; for v in "${P99_VALUES[@]}"; do sum=$((sum + v)); done; summary_value=$(( sum / ${#P99_VALUES[@]} ));;
  esac
fi

SUMMARY_STATUS="N/A"
if [ "$summary_value" != "N/A" ]; then
  [ "$summary_value" -ge "$THRESH_NS" ] && SUMMARY_STATUS="NO" || SUMMARY_STATUS="YES"
fi

echo "${PARALLEL},${SC_NAME},${summary_value},${SUMMARY_STATUS}" >> "$SUMMARY_CSV"

echo
if command -v column >/dev/null 2>&1; then
  column -s, -t "$SUMMARY_CSV"
else
  cat "$SUMMARY_CSV"
fi

echo
echo "PVCs used: ${PVC_NAMES[*]}"
echo "Details: $DETAILS_CSV"
echo "Summary: $SUMMARY_CSV"
echo "(<10ms = YES means meets etcd latency requirement)"
