#!/usr/bin/env bash

set -Eeuo pipefail

kubeconfig="${1:-/home/ubuntu/.kube/config}"
nodes_json="$(mktemp)"
pods_json="$(mktemp)"
metrics_file="$(mktemp)"
trap 'rm -f "$nodes_json" "$pods_json" "$metrics_file"' EXIT

kubectl --kubeconfig="$kubeconfig" get nodes -o json >"$nodes_json"
kubectl --kubeconfig="$kubeconfig" get pods -A -o json >"$pods_json"
kubectl --kubeconfig="$kubeconfig" top nodes --no-headers >"$metrics_file" 2>/dev/null || true

python3 - "$nodes_json" "$pods_json" "$metrics_file" <<'PY'
import json
import re
import sys


def cpu_m(value):
    value = str(value or "0")
    if value.endswith("n"):
        return int(value[:-1]) / 1_000_000
    if value.endswith("u"):
        return int(value[:-1]) / 1_000
    if value.endswith("m"):
        return float(value[:-1])
    return float(value) * 1000


MEMORY = {
    "Ki": 1024,
    "Mi": 1024**2,
    "Gi": 1024**3,
    "Ti": 1024**4,
    "K": 1000,
    "M": 1000**2,
    "G": 1000**3,
    "T": 1000**4,
}


def memory_bytes(value):
    value = str(value or "0")
    match = re.fullmatch(r"([0-9.]+)([A-Za-z]+)?", value)
    if not match:
        return 0
    number, suffix = match.groups()
    return float(number) * MEMORY.get(suffix or "", 1)


def fmt_cpu(value):
    return f"{value:.0f}m"


def fmt_mem(value):
    return f"{value / 1024**2:.0f}Mi"


with open(sys.argv[1]) as stream:
    nodes = json.load(stream)["items"]
with open(sys.argv[2]) as stream:
    pods = json.load(stream)["items"]

metrics = {}
with open(sys.argv[3]) as stream:
    for line in stream:
        fields = line.split()
        if len(fields) >= 3:
            metrics[fields[0]] = (fields[1], fields[2])

requested = {}
for pod in pods:
    if pod.get("status", {}).get("phase") in ("Succeeded", "Failed"):
        continue
    node_name = pod.get("spec", {}).get("nodeName")
    if not node_name:
        continue
    regular_cpu = regular_mem = 0
    for container in pod.get("spec", {}).get("containers", []):
        request = container.get("resources", {}).get("requests", {})
        regular_cpu += cpu_m(request.get("cpu"))
        regular_mem += memory_bytes(request.get("memory"))
    init_cpu = init_mem = 0
    for container in pod.get("spec", {}).get("initContainers", []):
        request = container.get("resources", {}).get("requests", {})
        init_cpu = max(init_cpu, cpu_m(request.get("cpu")))
        init_mem = max(init_mem, memory_bytes(request.get("memory")))
    cpu = max(regular_cpu, init_cpu)
    memory = max(regular_mem, init_mem)
    requested[node_name] = (
        requested.get(node_name, (0, 0))[0] + cpu,
        requested.get(node_name, (0, 0))[1] + memory,
    )

rows = []
total = [0, 0, 0, 0]
for node in nodes:
    metadata = node.get("metadata", {})
    spec = node.get("spec", {})
    labels = metadata.get("labels", {})
    taints = spec.get("taints", []) or []
    excluded = (
        "node-role.kubernetes.io/control-plane" in labels
        or "node-role.kubernetes.io/master" in labels
        or spec.get("unschedulable", False)
        or any(
            taint.get("key") == "node-role.kubernetes.io/scaling"
            and taint.get("effect") == "NoSchedule"
            for taint in taints
        )
    )
    if excluded:
        continue
    name = metadata["name"]
    allocatable = node.get("status", {}).get("allocatable", {})
    alloc_cpu = cpu_m(allocatable.get("cpu"))
    alloc_mem = memory_bytes(allocatable.get("memory"))
    req_cpu, req_mem = requested.get(name, (0, 0))
    avail_cpu = max(0, alloc_cpu - req_cpu)
    avail_mem = max(0, alloc_mem - req_mem)
    actual_cpu, actual_mem = metrics.get(name, ("N/A", "N/A"))
    rows.append((name, alloc_cpu, req_cpu, avail_cpu, alloc_mem, req_mem, avail_mem, actual_cpu, actual_mem))
    total[0] += alloc_cpu
    total[1] += req_cpu
    total[2] += alloc_mem
    total[3] += req_mem

print("Eligible workers: control-plane, unschedulable, scaling:NoSchedule excluded")
print(f"{'NODE':<57} {'CPU alloc':>10} {'CPU req':>10} {'CPU avail':>10} {'MEM alloc':>11} {'MEM req':>10} {'MEM avail':>11} {'Actual CPU':>11} {'Actual MEM':>11}")
for row in rows:
    name, ac, rc, vc, am, rm, vm, actual_cpu, actual_mem = row
    print(f"{name:<57} {fmt_cpu(ac):>10} {fmt_cpu(rc):>10} {fmt_cpu(vc):>10} {fmt_mem(am):>11} {fmt_mem(rm):>10} {fmt_mem(vm):>11} {actual_cpu:>11} {actual_mem:>11}")

print("-" * 145)
print(f"{'TOTAL':<57} {fmt_cpu(total[0]):>10} {fmt_cpu(total[1]):>10} {fmt_cpu(max(0, total[0]-total[1])):>10} {fmt_mem(total[2]):>11} {fmt_mem(total[3]):>10} {fmt_mem(max(0, total[2]-total[3])):>11}")
if not metrics:
    print("Actual usage: N/A (Metrics API is not available). Scheduler availability above is based on Pod requests.")
PY
