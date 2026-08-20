#!/usr/bin/env python3
"""Security telemetry generator (index=security) for threat-detection agents.

Emits a steady 'normal' baseline (auth successes, routine API calls, allowed traffic) plus
multi-stage ATTACK CHAINS. Every malicious event carries:
  threat_id       e.g. THREAT-2026-0001   (correlates the stages of one attack)
  attack_stage    recon | brute-force | valid-accounts | privilege-escalation | exfiltration | ...
  mitre_technique e.g. T1110              (so an agent can map to ATT&CK)
  severity        low | medium | high | critical
plus entity fields (user, src_ip, dest_ip, dest_port, geo_country, bytes_out) so an agent can
pivot and correlate. Stdlib only; see datagen_common.py for flags (--dry-run to eyeball).
"""
import random

from datagen_common import Scenario, make_event, run

IDX = "security"


def _e(ts, sourcetype, host, fields, level="info"):
    body = {"level": level}
    body.update(fields)
    return make_event(ts, IDX, sourcetype, host, body)


def _ip(net="10.0.1"):
    return f"{net}.{random.randint(2, 250)}"


# --- steady, benign baseline -----------------------------------------------------------------
def baseline(ts):
    out = []
    for u in random.sample(["alice", "bob", "carol", "dave", "erin"], 2):
        out.append(_e(ts + random.uniform(0, 6), "auth", "auth-svc-1", {
            "action": "login", "outcome": "success", "user": u, "src_ip": _ip(),
            "geo_country": "SG", "mfa": "verified", "message": f"login success for {u}"}))
    out.append(_e(ts + random.uniform(0, 6), "cloudtrail", "aws-controlplane", {
        "action": random.choice(["GetObject", "DescribeInstances", "ListBuckets", "GetParameter"]),
        "outcome": "success", "user": "app-role", "src_ip": _ip("10.0.2"),
        "message": "api call ok"}))
    out.append(_e(ts + random.uniform(0, 6), "firewall", "fw-edge-1", {
        "action": "allow", "src_ip": f"203.0.113.{random.randint(2, 250)}", "dest_ip": _ip(),
        "dest_port": random.choice([443, 443, 80]), "bytes_out": random.randint(200, 4000),
        "message": "allow"}))
    return out


# --- attack chains ---------------------------------------------------------------------------
def _brute_force_privesc(start):
    tid, src, host = "THREAT-2026-0001", "203.0.113.66", "auth-svc-1"
    out = []
    for i in range(9):
        out.append(_e(start + i * 7, "auth", host, {
            "action": "login", "outcome": "failure", "user": "root", "src_ip": src, "geo_country": "RU",
            "severity": "medium", "mitre_technique": "T1110", "threat_id": tid, "attack_stage": "brute-force",
            "message": "failed password for root (invalid credentials)"}, level="warn"))
    out.append(_e(start + 75, "auth", host, {
        "action": "login", "outcome": "success", "user": "root", "src_ip": src, "geo_country": "RU",
        "mfa": "not-present", "severity": "high", "mitre_technique": "T1078", "threat_id": tid,
        "attack_stage": "valid-accounts", "message": "accepted password for root"}, level="warn"))
    out.append(_e(start + 110, "cloudtrail", "aws-controlplane", {
        "action": "AssumeRole", "outcome": "success", "user": "root", "src_ip": src,
        "target_role": "OrganizationAdmin", "severity": "critical", "mitre_technique": "T1548",
        "threat_id": tid, "attack_stage": "privilege-escalation",
        "message": "AssumeRole to OrganizationAdmin from root session"}, level="error"))
    return out


def _impossible_travel(start):
    tid, user = "THREAT-2026-0002", "jdoe"
    return [
        _e(start, "auth", "corp-vpn-1", {
            "action": "login", "outcome": "success", "user": user, "src_ip": "13.71.20.5",
            "geo_country": "SG", "severity": "low", "threat_id": tid, "attack_stage": "valid-accounts",
            "message": f"vpn login for {user} from SG"}),
        _e(start + 480, "auth", "corp-vpn-1", {
            "action": "login", "outcome": "success", "user": user, "src_ip": "77.75.77.10",
            "geo_country": "RU", "severity": "high", "mitre_technique": "T1078", "threat_id": tid,
            "attack_stage": "impossible-travel",
            "message": f"vpn login for {user} from RU 8 min after SG (impossible travel)"}, level="warn"),
        _e(start + 520, "auth", "corp-vpn-1", {
            "action": "account-action", "outcome": "success", "user": user, "severity": "high",
            "threat_id": tid, "attack_stage": "containment",
            "message": f"{user} auto-suspended; sessions revoked"}, level="warn"),
    ]


def _scan_exploit_c2(start):
    tid, src, target = "THREAT-2026-0003", "185.220.101.4", "10.0.3.20"
    out = []
    for i, port in enumerate([22, 23, 80, 443, 3306, 5432, 6379, 8080, 9200]):
        out.append(_e(start + i * 3, "firewall", "fw-edge-1", {
            "action": "deny", "src_ip": src, "dest_ip": target, "dest_port": port, "geo_country": "NL",
            "severity": "low", "mitre_technique": "T1046", "threat_id": tid, "attack_stage": "recon",
            "message": f"port scan hit tcp/{port}"}, level="warn"))
    out.append(_e(start + 40, "waf", "api-gateway-1", {
        "action": "block", "src_ip": src, "dest_port": 443, "signature": "log4j-jndi",
        "severity": "high", "mitre_technique": "T1190", "threat_id": tid, "attack_stage": "exploit",
        "message": "blocked ${jndi:ldap://...} exploit attempt on /api"}, level="warn"))
    for i in range(4):  # regular-interval outbound beacon = C2
        out.append(_e(start + 120 + i * 60, "firewall", "fw-edge-1", {
            "action": "allow", "src_ip": target, "dest_ip": "45.133.1.7", "dest_port": 443,
            "bytes_out": 512 + random.randint(-20, 20), "severity": "high", "mitre_technique": "T1071",
            "threat_id": tid, "attack_stage": "command-and-control",
            "message": "periodic 512B beacon to known-bad host (60s interval)"}, level="warn"))
    return out


def _leaked_key_exfil(start):
    tid, key, src = "THREAT-2026-0004", "AKIAEXAMPLE1337", "104.244.72.9"
    out = [_e(start, "cloudtrail", "aws-controlplane", {
        "action": "GetCallerIdentity", "outcome": "success", "user": key, "src_ip": src, "geo_country": "US",
        "severity": "medium", "mitre_technique": "T1552", "threat_id": tid, "attack_stage": "recon",
        "message": "exposed access key used from a new ASN"}, level="warn")]
    for act in ["ListBuckets", "ListObjects", "GetBucketPolicy"]:
        out.append(_e(start + 20 + len(out) * 15, "cloudtrail", "aws-controlplane", {
            "action": act, "outcome": "success", "user": key, "src_ip": src, "severity": "medium",
            "mitre_technique": "T1580", "threat_id": tid, "attack_stage": "discovery",
            "message": f"{act} enumerated by leaked key"}, level="warn"))
    out.append(_e(start + 90, "cloudtrail", "aws-controlplane", {
        "action": "GetObject", "outcome": "success", "user": key, "src_ip": src,
        "bucket": "reporting-exports", "bytes_out": 4_800_000_000, "severity": "critical",
        "mitre_technique": "T1530", "threat_id": tid, "attack_stage": "exfiltration",
        "message": "4.8 GB downloaded from reporting-exports in 90s"}, level="error"))
    out.append(_e(start + 130, "cloudtrail", "aws-controlplane", {
        "action": "DeactivateAccessKey", "outcome": "success", "user": "secops", "severity": "high",
        "threat_id": tid, "attack_stage": "containment", "message": "leaked key deactivated"}, level="warn"))
    return out


def _endpoint_malware(start):
    tid, host, user = "THREAT-2026-0005", "WIN-FIN-07", "finance\\svc_report"
    return [
        _e(start, "endpoint", host, {
            "action": "process-start", "outcome": "success", "user": user, "process": "powershell.exe",
            "cmdline": "powershell -enc SQBFAFgA... (base64)", "severity": "high", "mitre_technique": "T1059.001",
            "threat_id": tid, "attack_stage": "execution", "message": "encoded PowerShell spawned by macro"}, level="warn"),
        _e(start + 35, "endpoint", host, {
            "action": "persistence", "outcome": "success", "user": user, "process": "schtasks.exe",
            "severity": "high", "mitre_technique": "T1053.005", "threat_id": tid, "attack_stage": "persistence",
            "message": "scheduled task 'Updater' created for hourly run"}, level="warn"),
        _e(start + 80, "endpoint", host, {
            "action": "network-connect", "outcome": "success", "user": user, "dest_ip": "10.0.3.44",
            "dest_port": 445, "severity": "high", "mitre_technique": "T1021.002", "threat_id": tid,
            "attack_stage": "lateral-movement", "message": "SMB connection to peer host 10.0.3.44"}, level="warn"),
        _e(start + 120, "endpoint", host, {
            "action": "quarantine", "outcome": "success", "process": "powershell.exe", "severity": "high",
            "threat_id": tid, "attack_stage": "containment", "message": "EDR isolated host and killed process"}, level="warn"),
    ]


def _web_app_attack(start):
    tid, src = "THREAT-2026-0006", "45.155.205.99"
    out = []
    for sig in ["sqli-union-select", "sqli-or-1-1", "xss-script-tag", "path-traversal-etc-passwd"]:
        out.append(_e(start + len(out) * 6, "waf", "api-gateway-1", {
            "action": "block", "src_ip": src, "signature": sig, "endpoint": "/api/login",
            "severity": "medium", "mitre_technique": "T1190", "threat_id": tid, "attack_stage": "exploit",
            "message": f"WAF blocked {sig}"}, level="warn"))
    out.append(_e(start + 45, "waf", "api-gateway-1", {
        "action": "allow", "src_ip": src, "endpoint": "/api/admin/export", "status": 200,
        "severity": "high", "mitre_technique": "T1190", "threat_id": tid, "attack_stage": "initial-access",
        "message": "200 on /api/admin/export after auth-bypass attempts (investigate)"}, level="warn"))
    return out


SCENARIOS = [
    Scenario("THREAT-2026-0001", _brute_force_privesc),
    Scenario("THREAT-2026-0002", _impossible_travel),
    Scenario("THREAT-2026-0003", _scan_exploit_c2),
    Scenario("THREAT-2026-0004", _leaked_key_exfil),
    Scenario("THREAT-2026-0005", _endpoint_malware),
    Scenario("THREAT-2026-0006", _web_app_attack),
]


if __name__ == "__main__":
    run("Security threat data generator (index=security)", baseline, SCENARIOS, seed=2026)
