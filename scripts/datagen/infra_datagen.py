#!/usr/bin/env python3
"""Infrastructure telemetry generator (index=infra) for troubleshooting agents.

Steady 'healthy' host/k8s/db signals plus INCIDENT CHAINS showing saturation and failure:
resource is fine -> climbs -> breaches -> recovers. Every incident event carries:
  infra_incident_id  e.g. INFRA-2026-0001   (correlates the chain)
  phase              baseline | degradation | trigger | mitigation | recovery
plus fields: component, node, pod, cpu_pct, mem_pct, disk_pct, state, reason. Several chains reuse
hosts/nodes referenced by the app generator (k8s-node-3, pg-primary-1) so a triage agent can join
the infra root cause to the app symptom. Stdlib only; see datagen_common.py for flags.
"""
import random

from datagen_common import Scenario, make_event, run

IDX = "infra"
NODES = ["k8s-node-1", "k8s-node-2", "k8s-node-4", "k8s-node-5"]


def _e(ts, sourcetype, host, fields, level="info"):
    body = {"level": level}
    body.update(fields)
    return make_event(ts, IDX, sourcetype, host, body)


# --- steady, healthy baseline ----------------------------------------------------------------
def baseline(ts):
    out = []
    for node in random.sample(NODES, 2):
        out.append(_e(ts + random.uniform(0, 6), "kubernetes", node, {
            "component": "kubelet", "node": node, "cpu_pct": random.randint(15, 55),
            "mem_pct": random.randint(30, 65), "disk_pct": random.randint(35, 60), "state": "Ready",
            "message": "node healthy"}))
    out.append(_e(ts + random.uniform(0, 6), "database", "pg-primary-1", {
        "component": "postgres", "cpu_pct": random.randint(20, 55), "mem_pct": random.randint(40, 70),
        "replica_lag_s": random.randint(0, 2), "state": "ok", "message": "checkpoint complete"}))
    return out


# --- incident chains -------------------------------------------------------------------------
def _node_mem_pressure_oom(start):
    # Root cause for app APP-2026-0004 (recommendation-service OOMKilled on k8s-node-3).
    iid, node = "INFRA-2026-0001", "k8s-node-3"
    out = []
    for i in range(7):
        mem = 68 + i * 5
        out.append(_e(start + i * 12, "kubernetes", node, {
            "component": "kubelet", "node": node, "mem_pct": min(mem, 99), "cpu_pct": random.randint(40, 70),
            "state": "MemoryPressure" if mem > 85 else "Ready", "infra_incident_id": iid,
            "phase": "degradation", "message": f"node memory {min(mem, 99)}%"},
            level="warn" if mem > 85 else "info"))
    out.append(_e(start + 95, "kubernetes", node, {
        "component": "kubelet", "node": node, "pod": "recommendation-service", "reason": "OOMKilled",
        "state": "MemoryPressure", "infra_incident_id": iid, "phase": "trigger",
        "message": "OOMKilled pod recommendation-service; evicting neighbors"}, level="error"))
    out.append(_e(start + 150, "kubernetes", node, {
        "component": "kubelet", "node": node, "mem_pct": 61, "state": "Ready", "infra_incident_id": iid,
        "phase": "recovery", "reason": "memory limits set + pod rescheduled", "message": "node back to Ready"}))
    return out


def _disk_fill_queue_block(start):
    iid, host = "INFRA-2026-0002", "indexer-2"
    out = []
    for i in range(7):
        disk = 72 + i * 4
        out.append(_e(start + i * 12, "host_metrics", host, {
            "component": "disk", "disk_pct": min(disk, 100), "mount": "/opt/splunk/var",
            "infra_incident_id": iid, "phase": "degradation", "message": f"hot volume {min(disk, 100)}% full"},
            level="warn" if disk > 85 else "info"))
    out.append(_e(start + 95, "splunkd", host, {
        "component": "indexer", "state": "blocked", "queue": "indexqueue", "reason": "disk full",
        "infra_incident_id": iid, "phase": "trigger", "message": "index queue blocked; forwarders backing up"},
        level="error"))
    out.append(_e(start + 150, "host_metrics", host, {
        "component": "disk", "disk_pct": 63, "infra_incident_id": iid, "phase": "recovery",
        "reason": "frozen old buckets + maxTotalDataSizeMB set", "message": "disk pressure cleared"}))
    return out


def _db_cpu_saturation(start):
    # Root cause for app APP-2026-0002 (orders-api slow via pg-primary-1).
    iid, host = "INFRA-2026-0003", "pg-primary-1"
    out = []
    for i in range(7):
        cpu = 70 + i * 4
        out.append(_e(start + i * 12, "database", host, {
            "component": "postgres", "cpu_pct": min(cpu, 100), "active_queries": 40 + i * 20,
            "slow_query_s": 1.2 + i * 0.6, "infra_incident_id": iid, "phase": "degradation",
            "message": f"postgres cpu {min(cpu, 100)}%, seq-scan on orders"}, level="warn"))
    out.append(_e(start + 95, "database", host, {
        "component": "postgres", "cpu_pct": 99, "state": "saturated", "reason": "missing index on orders.created_at",
        "infra_incident_id": iid, "phase": "trigger", "message": "query pile-up; connections maxed"}, level="error"))
    out.append(_e(start + 150, "database", host, {
        "component": "postgres", "cpu_pct": 46, "state": "ok", "reason": "index created concurrently",
        "infra_incident_id": iid, "phase": "recovery", "message": "cpu normal; slow queries gone"}))
    return out


def _replica_lag(start):
    iid, host = "INFRA-2026-0004", "pg-replica-eu-1"
    out = []
    for i in range(6):
        lag = 5 + i * 18
        out.append(_e(start + i * 14, "database", host, {
            "component": "postgres-replica", "replica_lag_s": lag, "region": "eu-west-1",
            "infra_incident_id": iid, "phase": "degradation", "message": f"replica lag {lag}s (WAL saturated)"},
            level="warn"))
    out.append(_e(start + 100, "database", host, {
        "component": "postgres-replica", "replica_lag_s": 2, "region": "eu-west-1", "reason": "backfill throttled",
        "infra_incident_id": iid, "phase": "recovery", "message": "replica caught up"}))
    return out


def _gpu_driver_fail(start):
    iid, host = "INFRA-2026-0005", "gpu-node-1"
    return [
        _e(start, "gpu", host, {
            "component": "nvidia", "state": "degraded", "reason": "kernel upgraded", "infra_incident_id": iid,
            "phase": "trigger", "message": "CUDA driver version is insufficient after kernel upgrade"}, level="error"),
        _e(start + 30, "gpu", host, {
            "component": "vllm", "state": "crash", "infra_incident_id": iid, "phase": "degradation",
            "message": "vLLM failed to start: no CUDA device"}, level="error"),
        _e(start + 80, "kubernetes", host, {
            "component": "kubelet", "node": host, "state": "cordoned", "infra_incident_id": iid,
            "phase": "mitigation", "message": "node cordoned; inference shifted to gpu-node-2"}, level="warn"),
        _e(start + 140, "gpu", host, {
            "component": "nvidia", "state": "ok", "reason": "DKMS driver rebuilt", "infra_incident_id": iid,
            "phase": "recovery", "message": "driver rebuilt; node uncordoned"}),
    ]


SCENARIOS = [
    Scenario("INFRA-2026-0001", _node_mem_pressure_oom),
    Scenario("INFRA-2026-0002", _disk_fill_queue_block),
    Scenario("INFRA-2026-0003", _db_cpu_saturation),
    Scenario("INFRA-2026-0004", _replica_lag),
    Scenario("INFRA-2026-0005", _gpu_driver_fail),
]


if __name__ == "__main__":
    run("Infrastructure data generator (index=infra)", baseline, SCENARIOS, seed=6060)
