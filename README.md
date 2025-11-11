# SCBench
Benchmark the performance of your StorageClasses by emulating etcd’s write pattern with fio / etcd-perf.

This repository provides a  way to benchmark **Kubernetes/OpenShift StorageClasses** using
[`quay.io/cloud-bulldozer/etcd-perf`](https://github.com/cloud-bulldozer/images/tree/main/etcd-perf).

By running multiple pods concurrently — all writing to the same PVC — you can evaluate how each **StorageClass** behaves under **synchronous write contention**.

---

## 🧩 Repository structure

```text
etcd-perf-storage-bench/
├── README.md
├── kustomize/
│   ├── base/
│   │   ├── job.yaml          # Base Job (runs fio via etcd-perf)
│   │   └── pvc.yaml          # Shared PVC definition
│   └── overlays/
│       ├── ceph-rbd/          # Example overlay for Ceph SC
│       └── lvm-local/          # Add overlays for other SCs
├── scripts/
│   ├── run-bench.sh          # Launch parallel jobs (oc-based)
│   ├── get-logs.sh           # Fetch pod logs
│   └── parse-99th.sh         # Parse fio JSON -> p99(ns)
└── tables/
    └── results.csv           # Consolidated output
```

---

## ⚙️ Requirements

* OpenShift 4.18+ cluster
* CLI tools:

  * `oc` (logged into your cluster)
  * `kustomize`
  * `yq` (v4+)
* Namespace: `storage-bench`

---

## ⚡ Why fio?

[`fio`](https://fio.readthedocs.io/en/latest/fio_doc.html) (Flexible I/O Tester) is an industry-standard tool to measure:

| Metric                     | Description                                  |
| -------------------------- | -------------------------------------------- |
| **IOPS**                   | Input/output operations per second           |
| **Latency**                | Time taken per I/O request                   |
| **Bandwidth**              | Data transferred per second                  |
| **Percentiles (p99, p95)** | How latency behaves for the slowest requests |

The parameters used in `etcd-perf` emulate etcd’s transactional write pattern using synchronous writes (`--ioengine=sync`, `--fdatasync=1`).
The 99th percentile (`p99`) represents tail latency — how slow the slowest operations get under load.

---

## 🚀 Quick start

### 1. Clone the repo

```bash
git clone https://github.com/tavaresrodrigo/scbench.git
cd etcd-perf-storage-bench
```

### 2. Choose or create a StorageClass overlay

Edit `kustomize/overlays/<your-sc>/patch-pvc.yaml` and set:

```yaml
spec:
  storageClassName: <your-storage-class>
```

Each overlay defines one StorageClass to test.

---

### 3. Run the benchmark

Example: run 5 concurrent pods using the Ceph StorageClass:

```bash
scripts/run-bench.sh kustomize/overlays/ceph-sc 5 ceph-sc
```

This will:

1. Ensure the namespace `storage-bench` exists
2. Create a shared PVC (`bench-pvc`)
3. Launch 5 Jobs (`etcd-perf-ceph-sc-1` .. `-5`), all mounting the same PVC at `/var/lib/etcd`

---

## 📊 Monitor progress

```bash
oc get pods -n storage-bench
```

Wait until all pods show **Completed**.

---

## 📈 Collect and analyze results

### 1. Get logs

```bash
scripts/get-logs.sh ceph-sc
```

### 2. Extract the 99th percentile latency

```bash
scripts/parse-99th.sh ceph-sc ./tables/results.csv
```

### 3. Display results

```bash
column -s, -t ./tables/results.csv
```

#### Example output

```text
tool       replicas  storageClass  p99_ns
fio        1         ceph-sc       102400
fio        2         ceph-sc       124800
fio        3         ceph-sc       159200
fio        4         ceph-sc       178300
fio        5         ceph-sc       192700
```

---

## 🔍 Interpretation

| Observation                           | Meaning                                          |
| ------------------------------------- | ------------------------------------------------ |
| **Low p99 (<1 ms)**                   | Backend handles sync writes efficiently          |
| **Rising p99 as replicas increase**   | I/O contention is increasing                     |
| **Large jumps in p99 (>5× baseline)** | Possible bottleneck (journal, metadata, network) |
| **Flat p99 curve**                    | Backend scales well (SSD, good caching)          |

---

## 🧠 Notes

* The image `quay.io/cloud-bulldozer/etcd-perf` is a wrapper around `fio`.
* `/var/lib/etcd` mount path is **mandatory** — do not change it.
* OpenShift handles SELinux labeling; no `:Z` suffix needed.
* Shared PVC is intentional — tests concurrent access to the same volume.


---

## 🧹 Cleanup

```bash
oc delete ns storage-bench
```

---

## 🧪 Compare multiple StorageClasses

```bash
scripts/run-bench.sh kustomize/overlays/ceph-sc 5 ceph-sc
scripts/parse-99th.sh ceph-sc ./tables/results.csv

scripts/run-bench.sh kustomize/overlays/ocs-rbd 5 ocs-rbd
scripts/parse-99th.sh ocs-rbd ./tables/results.csv
```

The file `tables/results.csv` will contain all results.

---

## 📚 References

* [Cloud-Bulldozer etcd-perf container](https://github.com/cloud-bulldozer/images/tree/main/etcd-perf)
* [fio official documentation](https://fio.readthedocs.io/en/latest/fio_doc.html)

---

