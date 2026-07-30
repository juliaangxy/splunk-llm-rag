# Token Metering — add to any Splunk + Ollama/vLLM (cloud or on-prem)

Bolt per-call token metering onto model servers you **already** run (Ollama and/or any
OpenAI-compatible server like vLLM), shipping usage into a Splunk `token_metrics` index
with an **AI Token Usage** dashboard. Works on **any Splunk host you can reach** — AWS,
another cloud, a VM, or bare metal. Copy the files over, then run **one installer**; it
auto-discovers which models are up and wires everything.

```
client / AITK ─▶ token-meter proxy ─▶ your model (Ollama :11434 / vLLM :8001)
                     └─ one metric per call ─▶ Splunk HEC ─▶ index=token_metrics ─▶ dashboard
```

Token counts come from the **backend's own response** (OpenAI `usage`, Ollama
`prompt_eval_count`/`eval_count`), so they're exact. The proxy is stdlib-only Python 3 and
runs as a `systemd` unit. Nothing here is AWS-specific (the only cloud-only feature is
optional tag-based routing — see *Advanced*).

## What the installer does

`scripts/token-meter/install-token-meter.sh` takes a **metric-index host** and a **model host** and:
1. **auto-discovers** which backends (Ollama / vLLM-OpenAI) are actually running on the model host,
2. creates the `token_metrics` index + HEC token on the metric host (or ships to a remote Splunk), and
3. starts a metering proxy **only for the backends it found**.

## The scripts — what each does (and whether you need it)

| Script | Needed? | Purpose |
|---|---|---|
| `scripts/common.sh` | **required** | Shared bash helpers (logging, `require_root`, `wait_for_port`, Splunk CLI wrapper). Sourced by the others. |
| `scripts/11-token-metrics.sh` | **required** | Creates the `token_metrics` index (system-scope) + HEC token on Splunk, restarts until a probe is searchable, installs the **AI Token Usage** dashboard, writes `token-meter.env`, and kicks off the proxies. Also a platform bootstrap stage, so it stays in `scripts/`. |
| `scripts/token-meter/install-token-meter.sh` | **required** (entrypoint) | The one command you run — discovers the model backends, calls `11`, starts the right proxies. |
| `scripts/token-meter/start-token-meter-proxies.sh` | **required** | Launches the vLLM/Ollama metering proxies (systemd units) in front of the models. |
| `token-meter-proxy/app.py` | **required** | The reverse proxy itself — reads token usage from each response and posts it to HEC. |
| `scripts/token-meter/configure-token-meter-routes.sh` | optional | Only for **routing** — sending different models'/sources' metrics to different Splunk instances. A single-Splunk install doesn't need it. |
| `scripts/token-meter/refresh-token-meter-routes.sh` | optional | Self-heal timer for the routing table (re-resolves peer IPs). Only with routing. |
| `scripts/token-meter/aws-helpers.sh` | optional | AWS-only IMDS + tag→IP lookup, used **solely** by the two routing scripts. Inert off AWS. |
| `scripts/token-meter/diagnose-token-metering.sh` | optional | Read-only troubleshooter (probes proxy → HEC → index). Handy if metrics don't show up. |

**Bare minimum for a basic install:** `common.sh`, `11-token-metrics.sh`, `install-token-meter.sh`, `start-token-meter-proxies.sh`, `app.py`. The rest are optional (routing / diagnostics) — but the copy step below grabs the whole `token-meter/` folder, so you get them all with no downside.

## Prerequisites

- **Splunk Enterprise** with admin access (where the index + dashboard live).
- **Ollama and/or vLLM** reachable from the Splunk host.
- **Python 3** + `bash`/`curl` on the Splunk host. The scripts run as **root** (via `sudo`).
- SSH access to the host (for the copy step), or the files already on the host.

---

## Set your variables once (edit these)

```bash
# --- connection to the Splunk host (skip if you'll run the installer directly on the host) ---
HOST=<splunk-host-ip-or-dns>
USER=<your-ssh-login>          # ec2-user / ubuntu / root / ... whatever logs into HOST
KEY=                           # path to an SSH private key (e.g. ~/.ssh/id_rsa); leave EMPTY for agent/password auth

# --- what to install ---
ADMIN_PW='YOUR_SPLUNK_ADMIN_PASSWORD'
METRIC_HOST=localhost          # Splunk that stores metrics (localhost = the host you install on)
MODEL_HOST=localhost           # where Ollama/vLLM run (localhost, or another host/IP)
# optional flags for Step 2 if you need them:
#   --ollama-proxy-port 8101  --vllm-proxy-port 8100  --ollama-port 11434  --vllm-port 8001

# derived SSH options — adds `-i <key>` only when KEY is set; used by the copy commands below
SSHOPTS="-o StrictHostKeyChecking=accept-new"; [ -n "$KEY" ] && SSHOPTS="-i $KEY $SSHOPTS"
```

---

## Step 1 — copy the files onto the Splunk host

From a checkout of this repo:

```bash
cd <path-to-this-repo>
# clears a stale host key if the host was rebuilt/restarted; harmless otherwise
ssh-keygen -R "$HOST" 2>/dev/null || true

scp $SSHOPTS scripts/common.sh scripts/11-token-metrics.sh "$USER@$HOST:/tmp/"
scp $SSHOPTS -r scripts/token-meter "$USER@$HOST:/tmp/token-meter"
scp $SSHOPTS token-meter-proxy/app.py "$USER@$HOST:/tmp/app.py"

ssh $SSHOPTS "$USER@$HOST" 'sudo bash -s' <<'EOF'
mkdir -p /opt/splunk-ai/scripts/token-meter /opt/splunk-ai/token-meter-proxy
cp /tmp/common.sh /tmp/11-token-metrics.sh /opt/splunk-ai/scripts/
cp /tmp/token-meter/*.sh /opt/splunk-ai/scripts/token-meter/
cp /tmp/app.py /opt/splunk-ai/token-meter-proxy/app.py
chmod +x /opt/splunk-ai/scripts/*.sh /opt/splunk-ai/scripts/token-meter/*.sh
echo "placed:"; ls -1 /opt/splunk-ai/scripts /opt/splunk-ai/scripts/token-meter
EOF
```

> **Already on the host** (on-prem / bare metal, repo copied via git/rsync/USB)? Skip the SSH
> and just place the files, then run Step 2 locally:
> ```bash
> sudo mkdir -p /opt/splunk-ai/scripts/token-meter /opt/splunk-ai/token-meter-proxy
> sudo cp scripts/common.sh scripts/11-token-metrics.sh /opt/splunk-ai/scripts/
> sudo cp scripts/token-meter/*.sh /opt/splunk-ai/scripts/token-meter/
> sudo cp token-meter-proxy/app.py /opt/splunk-ai/token-meter-proxy/app.py
> sudo chmod +x /opt/splunk-ai/scripts/*.sh /opt/splunk-ai/scripts/token-meter/*.sh
> ```

## Step 2 — run the installer

**Remote (over SSH):**
```bash
ssh $SSHOPTS "$USER@$HOST" \
  "sudo SPLUNK_ADMIN_PASSWORD='$ADMIN_PW' bash /opt/splunk-ai/scripts/token-meter/install-token-meter.sh \
     --metric-host $METRIC_HOST --model-host $MODEL_HOST"
```

**Local (already on the host):**
```bash
sudo SPLUNK_ADMIN_PASSWORD='YOUR_ADMIN_PW' bash /opt/splunk-ai/scripts/token-meter/install-token-meter.sh \
  --metric-host localhost --model-host localhost
```

The installer probes the model host, creates the `token_metrics` index + HEC (restarting
Splunk until a probe is actually searchable), installs the **AI Token Usage** dashboard, and
starts a proxy for each backend found. Watch for `SUCCESS ... searchable` and the
`Point clients at the proxies` summary. (Add any `--*-port` overrides to the command as needed.)

**Flags:**

| Flag | Required | Default | Meaning |
|---|---|---|---|
| `--metric-host` | ✅ | — | Splunk that stores metrics (its HEC). Local → creates index+HEC here (needs `SPLUNK_ADMIN_PASSWORD`); remote → also pass `--hec-token`. |
| `--model-host` | ✅ | — | Host where Ollama/vLLM run (probed to auto-detect). |
| `--ollama-proxy-port` / `--vllm-proxy-port` | | `8101` / `8100` | proxy listen ports clients call |
| `--ollama-port` / `--vllm-port` | | `11434` / `8001` | model ports to probe/forward to |
| `--hec-port` | | `8088` | Splunk HEC port |
| `--hec-token` | remote only | — | HEC token already registered on a remote `--metric-host` |

**Models on another host / custom ports:**
```bash
sudo SPLUNK_ADMIN_PASSWORD='...' bash /opt/splunk-ai/scripts/token-meter/install-token-meter.sh \
  --metric-host localhost --model-host 10.20.0.5 --ollama-proxy-port 9101 --vllm-proxy-port 9100
```

**Ship to a remote Splunk** (index+HEC must exist there first — run the installer on that
Splunk with `--metric-host localhost`, then read its token with
`sudo grep '^HEC_TOKEN=' /opt/splunk-ai/token-meter.env`):
```bash
sudo bash /opt/splunk-ai/scripts/token-meter/install-token-meter.sh \
  --metric-host splunk.internal --model-host localhost --hec-token '<token-from-that-splunk>'
```

## Step 3 — point clients / AITK at the proxies (on the Splunk host)

| Client | Base URL |
|---|---|
| Ollama | `http://<splunk-host>:8101` (or your `--ollama-proxy-port`) |
| OpenAI / vLLM | `http://<splunk-host>:8100/v1` (API key = `sudo grep '^PROXY_API_KEY=' /opt/splunk-ai/token-meter.env`) |
| Splunk AITK provider | set the Ollama / OpenAI base URL to the proxy above |

## Step 4 — verify

```bash
curl -s http://localhost:8101/api/chat \
  -d '{"model":"<your-model>","messages":[{"role":"user","content":"hi"}],"stream":false}' >/dev/null
```
In Splunk: `index=token_metrics earliest=-15m`, or **Apps → AI Token Usage**.
Fields: `backend, model, prompt_tokens, completion_tokens, total_tokens, latency_ms, user, app`.

---

## Advanced — run the pieces directly / custom endpoints

The installer just orchestrates these:

- **Index + HEC only** (on the Splunk host): `sudo SPLUNK_ADMIN_PASSWORD=... bash 11-token-metrics.sh`
- **Proxies only**, fully custom endpoints (env wins over `token-meter.env`; empty upstream skips a backend):
  ```bash
  sudo OLLAMA_UPSTREAM_URL="http://10.20.0.5:11434" \
       VLLM_UPSTREAM_URL="" \
       HEC_URL="https://splunk.internal:8088/services/collector/event" \
       HEC_TOKEN="<token>" HEC_INDEX="token_metrics" PROXY_API_KEY="<key>" \
       bash token-meter/start-token-meter-proxies.sh
  ```
- **Routing** (per model/source → a specific Splunk): `configure-token-meter-routes.sh`.
  On-prem, use explicit `hec_host` per route (`TOKEN_METER_ROUTES` / `TOKEN_METER_DEFAULT_HOST`).
  The `target_role` option (resolve a peer by an EC2 `SplunkAiRole` tag) is **AWS-only** —
  ignore it on-prem.

## Gotchas (handled by the installer, but worth knowing)

- A new **HEC token loads only on a full restart** — `11` restarts (as the `splunk` user)
  and retries until a probe indexes, so the token is loaded before it exits.
- The **index must be system-scoped** — `11` writes it to `etc/system/local/indexes.conf`.
- HEC `{"code":0}` means **accepted, not indexed** — verify by *searching*, not the HEC reply.
- If a search is empty: confirm your **admin password** is correct (the installer's verify
  step searches with it), that `$SPLUNK_DB` is writable by the **splunk** user, that the role's
  `srchIndexesAllowed` includes `*` or `token_metrics`, and that the call went **through** the
  proxy port (not the model directly).
