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
| `scripts/token-meter/configure-token-meter-routes.sh` | optional | Picks **which Splunk** the metrics ship to (this host vs. a remote/search-head), resolving a role to an IP. A standalone single-Splunk install doesn't need it. |
| `scripts/token-meter/refresh-token-meter-routes.sh` | optional | Self-heal timer for that destination (re-resolves the peer IP). Only used with the script above. |
| `scripts/token-meter/aws-helpers.sh` | optional | AWS-only IMDS + tag→IP lookup, used **solely** by the two scripts above. Inert off AWS. |
| `scripts/token-meter/diagnose-token-metering.sh` | optional | Read-only troubleshooter (probes proxy → HEC → index). Handy if metrics don't show up. |
| `scripts/token-meter/uninstall-token-meter.sh` | optional | Reverses the install — stops/removes the proxies + timer and staged files. `--purge-splunk` also drops the index/HEC/dashboard. |

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
KEY="$HOME/.ssh/your-key.pem"  # SSH private key; set KEY="" for agent/password auth
#   Use STRAIGHT quotes " " (NOT smart quotes “ ”) and $HOME (NOT ~, which stays literal
#   inside quotes). A mangled key path is the #1 cause of "Permission denied (publickey)".

# --- what to install ---
ADMIN_PW='YOUR_SPLUNK_ADMIN_PASSWORD'
METRIC_HOST=localhost          # Splunk that stores metrics (localhost = the host you install on)
MODEL_HOST=localhost           # where Ollama/vLLM run (localhost, or another host/IP)
# optional flags for Step 2 if you need them:
#   --ollama-proxy-port 8101  --vllm-proxy-port 8100  --ollama-port 11434  --vllm-port 8001

# SSH auth, rebuilt fresh each time you run this block (so no stale value can creep in).
# IDENT holds `-i <key>` only when KEY is set; pass "${IDENT[@]}" $O on every ssh/scp below.
IDENT=(); O="-o StrictHostKeyChecking=accept-new"
[ -n "$KEY" ] && { chmod 600 "$KEY"; IDENT=(-i "$KEY"); }

# Verify the connection BEFORE copying — this must print "connected as <USER>":
ssh "${IDENT[@]}" $O "$USER@$HOST" 'echo connected as $(whoami)'
```

> If that check fails with `Permission denied (publickey)`: confirm `ls -l "$KEY"` shows the
> real file (no stray `“ ”`), that `chmod 600 "$KEY"` ran, and that this key is the one paired
> with `$USER` on the instance. Re-run the whole block above so `IDENT` is rebuilt cleanly.

---

## Step 1 — copy the files onto the Splunk host

From a checkout of this repo:

```bash
cd <path-to-this-repo>
# clears a stale host key if the host was rebuilt/restarted; harmless otherwise
ssh-keygen -R "$HOST" 2>/dev/null || true

scp "${IDENT[@]}" $O scripts/common.sh scripts/11-token-metrics.sh "$USER@$HOST:/tmp/"
scp "${IDENT[@]}" $O -r scripts/token-meter "$USER@$HOST:/tmp/token-meter"
scp "${IDENT[@]}" $O token-meter-proxy/app.py "$USER@$HOST:/tmp/app.py"

ssh "${IDENT[@]}" $O "$USER@$HOST" 'sudo bash -s' <<'EOF'
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
ssh "${IDENT[@]}" $O "$USER@$HOST" \
  "sudo SPLUNK_ADMIN_PASSWORD='$ADMIN_PW' bash /opt/splunk-ai/scripts/token-meter/install-token-meter.sh \
     --metric-host $METRIC_HOST --model-host $MODEL_HOST"
```

**Local (already on the host):** both hosts default to `localhost`, so a bare run does a
same-host install — no flags needed:
```bash
sudo SPLUNK_ADMIN_PASSWORD='YOUR_ADMIN_PW' bash /opt/splunk-ai/scripts/token-meter/install-token-meter.sh
```

The installer probes the model host, creates the `token_metrics` index + HEC (restarting
Splunk until a probe is actually searchable), installs the **AI Token Usage** dashboard, and
starts a proxy for each backend found. Watch for `SUCCESS ... searchable` and the
`Point clients at the proxies` summary. (Add any `--*-port` overrides to the command as needed.)

**Flags:**

| Flag | Required | Default | Meaning |
|---|---|---|---|
| `--metric-host` | | `localhost` | Splunk that stores metrics (its HEC). Local → creates index+HEC here (needs `SPLUNK_ADMIN_PASSWORD`); remote → also pass `--hec-token`. |
| `--model-host` | | `localhost` | Host where Ollama/vLLM run (probed to auto-detect). |
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

## Uninstall / reinstall (test the files on a host)

`scripts/token-meter/uninstall-token-meter.sh` reverses the install. By default it's a
**non-destructive** teardown of the proxy layer — it stops and removes the metering proxies
+ the self-heal timer and clears the runtime state (`token-meter.env` + destination file), but
**leaves** the staged code (scripts + the proxy app under `/opt/splunk-ai/token-meter-proxy`)
and the Splunk `token_metrics` index, data, HEC token, and dashboard, so a reinstall reuses them.

```bash
# preview what would be removed (no root needed, changes nothing)
sudo bash /opt/splunk-ai/scripts/token-meter/uninstall-token-meter.sh --dry-run

# stop the proxies + clear runtime state (keeps staged code + the Splunk index/data/dashboard)
sudo bash /opt/splunk-ai/scripts/token-meter/uninstall-token-meter.sh

# ALSO drop the index (INCLUDING data), HEC token, and dashboard app, then restart Splunk
sudo SPLUNK_ADMIN_PASSWORD='YOUR_ADMIN_PW' \
  bash /opt/splunk-ai/scripts/token-meter/uninstall-token-meter.sh --purge-splunk

# ALSO delete the staged code (scripts + proxy app). Only do this if you'll re-copy before reinstalling.
sudo bash /opt/splunk-ai/scripts/token-meter/uninstall-token-meter.sh --remove-scripts
```

> **Order matters for a clean reinstall.** `install-token-meter.sh` does **not** re-copy the
> proxy `app.py` — it expects it already staged. So **uninstall first, then re-copy (Step 1),
> then install**. (A default or `--purge-splunk` uninstall keeps the staged code, so copying
> before uninstalling also works; but uninstall→copy→install is safe no matter which flags you use.)

**Test a clean reinstall of the new files** (run the copy from your repo checkout, the rest over SSH):

```bash
# 1) full teardown first (uses the already-staged uninstaller; drop --purge-splunk to keep the index)
ssh "${IDENT[@]}" $O "$USER@$HOST" \
  "sudo SPLUNK_ADMIN_PASSWORD='$ADMIN_PW' bash /opt/splunk-ai/scripts/token-meter/uninstall-token-meter.sh --purge-splunk"

# 2) re-copy the latest files (repeat Step 1's copy block) so app.py + scripts are freshly staged

# 3) reinstall (bare run = same-host, all-local)
ssh "${IDENT[@]}" $O "$USER@$HOST" \
  "sudo SPLUNK_ADMIN_PASSWORD='$ADMIN_PW' bash /opt/splunk-ai/scripts/token-meter/install-token-meter.sh"

# 4) verify (Step 4): fire a call through the proxy, then search index=token_metrics
```

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
- **Destination** (which single Splunk gets the metrics): `configure-token-meter-routes.sh`.
  Set `TOKEN_METER_DEFAULT_ROLE` (`self` | `search-head` | `gpu-host`) or an explicit
  `TOKEN_METER_DEFAULT_HOST=<ip/host>`. Role→IP resolution uses the EC2 `SplunkAiRole` tag and
  is **AWS-only** — on-prem, set `TOKEN_METER_DEFAULT_HOST` explicitly. (For a same-host install
  you don't need this at all; the installer ships to the local HEC by default.)

## Gotchas (handled by the installer, but worth knowing)

- A new **HEC token loads only on a full restart** — `11` restarts (as the `splunk` user)
  and retries until a probe indexes, so the token is loaded before it exits.
- The **index must be system-scoped** — `11` writes it to `etc/system/local/indexes.conf`.
- HEC `{"code":0}` means **accepted, not indexed** — verify by *searching*, not the HEC reply.
- If a search is empty: confirm your **admin password** is correct (the installer's verify
  step searches with it), that `$SPLUNK_DB` is writable by the **splunk** user, that the role's
  `srchIndexesAllowed` includes `*` or `token_metrics`, and that the call went **through** the
  proxy port (not the model directly).
