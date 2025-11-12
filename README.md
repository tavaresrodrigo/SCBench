# SCBench

Benchmark StorageClasses by emulating etcd write patterns with fio / etcd-perf using [`quay.io/cloud-bulldozer/etcd-perf`](https://github.com/cloud-bulldozer/images/tree/main/etcd-perf).

Each pod gets its **own PVC** during a run. This measures the underlying StorageClass performance without contention on a single volume and observes parallel scaling across volumes.

---

## Objective

SCBench runs fio workloads that simulate etcd fsync behavior. It collects p99 latency from the container logs and reports the result for each StorageClass.

The tool helps verify if a storage backend meets the etcd recommendation of p99 fsync < 10 ms.

---

## Repository Structure

```text
scbench/
├── README.md
├── kustomize/
│   ├── base/
│   │   ├── job.yaml          # Job definition (runs fio via etcd-perf)
│   │   ├── pvc.yaml          # PVC used by all pods
│   │   └── kustomization.yaml
├── scripts/
│   └── run-bench.sh          # Runs jobs, watches pods, collects results
└── tables/
    ├── summary.csv           # Aggregated results per run
    └── details.csv           # Detailed per-pod results
```

---

## Requirements

* OpenShift 4.18+ or Kubernetes 1.29+
* Tools: `oc`, `kustomize`, `yq` v4+
* Namespace: `storage-bench`
* Valid StorageClass (e.g., `ocs-external-storagecluster-ceph-rbd`, `lvms-vg1`)
* The terminal must be logged in to the Openshift cluster  (oc login or export KUBECONFIG)

---

## Run

```bash
scripts/run-bench.sh <storage-class-name> <parallel> [summary_csv] [details_csv]
```

Example:

```bash
scripts/run-bench.sh ocs-external-storagecluster-ceph-rbd 10 ./tables/summary.csv ./tables/details.csv
```

Steps:

1. Create **N PVCs** per run (`bench-pvc-<sc>-<runid>-<i>`), one per pod.
2. Launch N Jobs. Each Job mounts its **own PVC**.
3. Watch pod progress live.
4. Wait for all Jobs to complete.
5. Parse fio JSON output to collect the 99th percentile (p99) latency.
6. Write results to `details.csv` and `summary.csv`.
7. Delete Jobs and the PVC unless `KEEP=1` is set.

---

## Example Output

### tables/summary.csv

```csv
Parallel Replicas,Storage Backend,99thP ns,Status
1,ocs-external-storagecluster-ceph-rbd,245120,OK
5,ocs-external-storagecluster-ceph-rbd,9876543,OK
10,ocs-external-storagecluster-ceph-rbd,12876543,FAIL
```

### tables/details.csv

```csv
job,pod,storageClass,p99_ns,Status
etcd-perf-ocs-1762940738-1,etcd-perf-ocs-1762940738-1,ocs-external-storagecluster-ceph-rbd,287032,OK
etcd-perf-ocs-1762940738-2,etcd-perf-ocs-1762940738-2,ocs-external-storagecluster-ceph-rbd,11234567,FAIL
```

### Terminal summary

```text
Parallel Replicas  Storage Backend                          99thP ns   Status
1                  ocs-external-storagecluster-ceph-rbd     245120     OK
5                  ocs-external-storagecluster-ceph-rbd     9876543    OK
10                 ocs-external-storagecluster-ceph-rbd     12876543   FAIL
```

---

## Result Criteria

| Condition   | Description            |
| ----------- | ---------------------- |
| p99 < 10 ms | Meets etcd requirement |
| p99 ≥ 10 ms | Not suitable for etcd  |

---

## Cleanup

Resources are deleted automatically when the script finishes.

To keep them for inspection:

```bash
KEEP=1 scripts/run-bench.sh <storage-class> <parallel>
```

To remove all benchmark data manually:

```bash
oc delete ns storage-bench
```

---

## Configuration Notes

* Mount path `/var/lib/etcd` is required.
* Each run creates **one PVC per pod** (`bench-pvc-<sc>-<runid>-<i>`).
* Jobs use labels (`bench.sc`, `bench.run`, `bench.tool`) for tracking.
* Aggregation mode: `AGG=max` (default). Change with:

```bash
AGG=avg scripts/run-bench.sh <sc> 10
AGG=min scripts/run-bench.sh <sc> 10
```

* Threshold can be adjusted with `THRESH_NS` (default: 10000000 ns).

---

## 📚 References

* [Cloud-Bulldozer etcd-perf container](https://github.com/cloud-bulldozer/images/tree/main/etcd-perf)
* [fio official documentation](https://fio.readthedocs.io/en/latest/fio_doc.html)
* [Validating the hardware for etcd](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/scalability_and_performance/recommended-performance-and-scalability-practices-2#etcd-verify-hardware_recommended-etcd-practices)

---