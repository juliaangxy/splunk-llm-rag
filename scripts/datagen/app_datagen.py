#!/usr/bin/env python3
"""Application telemetry generator (index=app) for troubleshooting / triage agents.

Steady 'normal' HTTP traffic (2xx, healthy latency) plus INCIDENT CHAINS that read like a real
degradation: a trigger (deploy, dependency, leak), rising errors/latency, then recovery. Every
incident event carries:
  app_incident_id  e.g. APP-2026-0001    (correlates the chain)
  phase            trigger | degradation | mitigation | recovery
plus RCA fields: service, endpoint, method, status, latency_ms, trace_id, error, deploy_version,
upstream. Some chains reference infra hosts/nodes on purpose so a triage agent can correlate
across the app <-> infra indexes. Stdlib only; see datagen_common.py for flags.
"""
import random

from datagen_common import Scenario, make_event, run

IDX = "app"
SERVICES = [
    ("payments-api", "payments-api-1", ["/charge", "/refund", "/health"]),
    ("checkout-web", "checkout-web-2", ["/cart", "/checkout", "/health"]),
    ("orders-api", "orders-api-1", ["/orders", "/orders/{id}", "/health"]),
    ("catalog-service", "catalog-svc-1", ["/items", "/items/{id}", "/health"]),
]


def _trace():
    return "%016x" % random.randrange(16 ** 16)


def _e(ts, service, host, fields, sourcetype="access", level="info"):
    body = {"level": level, "service": service, "trace_id": _trace()}
    body.update(fields)
    return make_event(ts, IDX, sourcetype, host, body)


# --- steady, healthy baseline ----------------------------------------------------------------
def baseline(ts):
    out = []
    for service, host, paths in random.sample(SERVICES, 3):
        out.append(_e(ts + random.uniform(0, 6), service, host, {
            "endpoint": random.choice(paths), "method": random.choice(["GET", "GET", "POST"]),
            "status": 200, "latency_ms": random.randint(20, 140), "deploy_version": "v2.2.9",
            "message": "request served"}))
    return out


# --- incident chains -------------------------------------------------------------------------
def _bad_deploy_5xx(start):
    iid, service, host = "APP-2026-0001", "checkout-web", "checkout-web-2"
    out = [_e(start, service, host, {
        "endpoint": "/deploy", "status": 200, "latency_ms": 5, "deploy_version": "v2.3.0",
        "app_incident_id": iid, "phase": "trigger", "message": "deploy v2.3.0 rolled out to 100%"})]
    for i in range(10):
        out.append(_e(start + 20 + i * 9, service, host, {
            "endpoint": "/checkout", "method": "POST", "status": 500, "latency_ms": random.randint(30, 90),
            "deploy_version": "v2.3.0", "error": "NullPointerException in CheckoutV2.total()",
            "error_rate_pct": min(3 + i * 2, 22), "app_incident_id": iid, "phase": "degradation",
            "message": "500 on /checkout (5xx rate rising)"}, level="error"))
    out.append(_e(start + 130, service, host, {
        "endpoint": "/deploy", "status": 200, "deploy_version": "v2.2.9", "app_incident_id": iid,
        "phase": "mitigation", "message": "rolled back to v2.2.9"}, level="warn"))
    out.append(_e(start + 170, service, host, {
        "endpoint": "/checkout", "method": "POST", "status": 200, "latency_ms": 95, "deploy_version": "v2.2.9",
        "error_rate_pct": 0, "app_incident_id": iid, "phase": "recovery", "message": "5xx back to baseline"}))
    return out


def _slow_db_dependency(start):
    iid, service, host = "APP-2026-0002", "orders-api", "orders-api-1"
    out = []
    for i in range(9):
        lat = 180 + i * 220
        out.append(_e(start + i * 12, service, host, {
            "endpoint": "/orders", "method": "GET", "status": 200 if lat < 1500 else 504,
            "latency_ms": lat, "upstream": "pg-primary-1", "upstream_latency_ms": lat - 40,
            "app_incident_id": iid, "phase": "degradation" if lat < 1500 else "trigger",
            "error": None if lat < 1500 else "upstream timeout (pg-primary-1)",
            "message": f"/orders p99 latency {lat}ms via pg-primary-1"},
            level="warn" if lat < 1500 else "error"))
    out.append(_e(start + 120, service, host, {
        "endpoint": "/orders", "method": "GET", "status": 200, "latency_ms": 120, "upstream": "pg-primary-1",
        "app_incident_id": iid, "phase": "recovery", "message": "latency normal after slow query killed"}))
    return out


def _retry_storm_breaker(start):
    iid, service, host = "APP-2026-0003", "shipping-service", "shipping-svc-1"
    out = []
    for i in range(8):
        out.append(_e(start + i * 8, service, host, {
            "endpoint": "/label", "method": "POST", "status": 429, "latency_ms": random.randint(60, 120),
            "upstream": "carrier-api", "retries": i, "app_incident_id": iid, "phase": "degradation",
            "error": "carrier-api 429 rate limited; retrying (no backoff)",
            "message": "429 from carrier-api, retry storm building"}, level="warn"))
    out.append(_e(start + 80, service, host, {
        "endpoint": "/label", "method": "POST", "status": 503, "upstream": "carrier-api",
        "app_incident_id": iid, "phase": "mitigation", "circuit_breaker": "open",
        "message": "circuit breaker opened for carrier-api"}, level="error"))
    out.append(_e(start + 150, service, host, {
        "endpoint": "/label", "method": "POST", "status": 200, "latency_ms": 110, "upstream": "carrier-api",
        "app_incident_id": iid, "phase": "recovery", "circuit_breaker": "closed",
        "message": "breaker half-open then closed; labels flowing"}))
    return out


def _memory_leak_oom(start):
    # Cross-index: this app service is OOMKilled by k8s — pairs with an infra event on k8s-node-3.
    iid, service, host = "APP-2026-0004", "recommendation-service", "reco-svc-1"
    out = []
    for i in range(6):
        out.append(_e(start + i * 15, service, host, {
            "endpoint": "/recommend", "method": "GET", "status": 200, "latency_ms": 90 + i * 40,
            "heap_pct": 70 + i * 5, "node": "k8s-node-3", "app_incident_id": iid, "phase": "degradation",
            "message": f"heap {70 + i * 5}% on k8s-node-3, GC pauses rising"}, level="warn"))
    out.append(_e(start + 100, service, host, {
        "endpoint": "/recommend", "method": "GET", "status": 503, "node": "k8s-node-3",
        "error": "container OOMKilled (restarting)", "app_incident_id": iid, "phase": "trigger",
        "message": "pod OOMKilled on k8s-node-3"}, level="error"))
    out.append(_e(start + 150, service, host, {
        "endpoint": "/recommend", "method": "GET", "status": 200, "latency_ms": 95, "node": "k8s-node-5",
        "app_incident_id": iid, "phase": "recovery", "message": "rescheduled to k8s-node-5; healthy"}))
    return out


def _auth_token_expiry(start):
    iid, service, host = "APP-2026-0005", "tax-service", "tax-svc-1"
    out = []
    for i in range(6):
        out.append(_e(start + i * 10, service, host, {
            "endpoint": "/quote", "method": "POST", "status": 401, "upstream": "tax-provider",
            "error": "tax-provider 401 token expired", "app_incident_id": iid, "phase": "degradation",
            "message": "401 from tax-provider; falling back to estimated tax"}, level="warn"))
    out.append(_e(start + 80, service, host, {
        "endpoint": "/quote", "method": "POST", "status": 200, "latency_ms": 130, "upstream": "tax-provider",
        "app_incident_id": iid, "phase": "recovery", "message": "token rotated in Secrets Manager; live tax restored"}))
    return out


SCENARIOS = [
    Scenario("APP-2026-0001", _bad_deploy_5xx),
    Scenario("APP-2026-0002", _slow_db_dependency),
    Scenario("APP-2026-0003", _retry_storm_breaker),
    Scenario("APP-2026-0004", _memory_leak_oom),
    Scenario("APP-2026-0005", _auth_token_expiry),
]


if __name__ == "__main__":
    run("Application data generator (index=app)", baseline, SCENARIOS, seed=4040)
