# Token Metering — add to an existing Ollama / vLLM + Splunk

Bolt per-call token metering onto model servers you **already** run (Ollama and/or any
OpenAI-compatible server like vLLM), shipping usage into a Splunk `token_metrics` index
with an **AI Token Usage** dashboard. No full-platform deploy — just five files and two
commands.

```
client / AITK ─▶ token-meter proxy ─▶ your model (Ollama :11434 / vLLM :8001)
                     └─ one metric per call ─▶ Splunk HEC ─▶ index=token_metrics ─▶ dashboard
```

Token counts come from the **backend's own response** (OpenAI `usage`, Ollama
`prompt_eval_count`/`eval_count`), so they're exact, not estimated. The proxy is
stdlib-only Python 3 and runs as a `systemd` unit.

## Files you need (from this repo)

Copy these, preserving the layout so the script defaults resolve:

```
/opt/splunk-ai/
├── scripts/
│   ├── common.sh                        # shared helpers (sourced by the others)
│   ├── 11-token-metrics.sh              # creates the index + HEC token on Splunk
│   ├── start-token-meter-proxies.sh     # starts the vLLM + Ollama proxies
│   └── configure-token-meter-routes.sh  # OPTIONAL: route metrics to a chosen Splunk
└── token-meter-proxy/
    └── app.py                           # the metering reverse proxy
```

Quick copy from a checkout of this repo:
```bash
sudo mkdir -p /opt/splunk-ai/scripts /opt/splunk-ai/token-meter-proxy
sudo cp scripts/common.sh scripts/11-token-metrics.sh scripts/start-token-meter-proxies.sh \
        scripts/configure-token-meter-routes.sh /opt/splunk-ai/scripts/
sudo cp token-meter-proxy/app.py /opt/splunk-ai/token-meter-proxy/
sudo chmod +x /opt/splunk-ai/scripts/*.sh
```

## Prerequisites

- **Splunk Enterprise** with admin access (this is where the index + dashboard live).
- **One or both model servers** reachable: Ollama (`:11434`), vLLM/OpenAI (`:8001` or yours).
- **Python 3** on the host that will run the proxy (ideally the same host as the models).
- Run the scripts as **root** (they manage Splunk config and `systemd` units).

`common.sh` reads config from the environment, or from `/opt/splunk-ai/bootstrap.env` +
`/opt/splunk-ai/bootstrap.secrets.env` if those exist. For a standalone install you can
just pass the variables inline (shown below) — no bootstrap files required. The AWS/IMDS
helpers in `common.sh` are only used by the optional routing step, so **no AWS is needed**
for a basic install.

---

## Case A — models and Splunk on the SAME host (simplest)

**1. Create the index + HEC token on Splunk** (run on the Splunk host):
```bash
sudo SPLUNK_HOME=/opt/splunk SPLUNK_ADMIN_PASSWORD='YOUR_ADMIN_PW' \
  bash /opt/splunk-ai/scripts/11-token-metrics.sh
```
This creates a **system-scoped** `token_metrics` index + a HEC token (`aitk-token-meter`
on `:8088`), **restarts Splunk until a probe event is actually searchable** (so the token
and index are truly loaded), writes `/opt/splunk-ai/token-meter.env`, installs the **AI
Token Usage** dashboard app, and then starts the proxies. Watch for:
```
SUCCESS (attempt N): probe event is searchable in index=token_metrics — metering works.
```
Optional: pin the token/proxy key by also passing `SPLUNK_HEC_TOKEN='...'` and
`PROXY_API_KEY='...'` (otherwise they're generated and saved to `token-meter.env`).

**2. Proxies are already up** (stage-11 started them). Confirm / restart anytime:
```bash
sudo bash /opt/splunk-ai/scripts/start-token-meter-proxies.sh
```
This starts **both**:
- **Ollama proxy** on `:8101` → forwards to Ollama `:11434` (keyless)
- **vLLM/OpenAI proxy** on `:8100` → forwards to vLLM `:8001` (requires the bearer `PROXY_API_KEY`)

Only running one backend? It still starts both; the unused proxy just forwards to a closed
port and gets no traffic — harmless. (Or run a single proxy directly — see *One backend only*.)

---

## Case B — models and Splunk on DIFFERENT hosts

**1. On the Splunk host** — create the index + HEC token exactly as in Case A step 1.
Note the token it saves:
```bash
sudo grep '^HEC_TOKEN=' /opt/splunk-ai/token-meter.env
```

**2. On the model host** — write a `token-meter.env` pointing at the remote Splunk HEC,
then start the proxies:
```bash
sudo mkdir -p /opt/splunk-ai
sudo tee /opt/splunk-ai/token-meter.env >/dev/null <<EOF
HEC_URL=https://<SPLUNK_HOST>:8088/services/collector/event
HEC_TOKEN=<paste the HEC_TOKEN from the Splunk host>
HEC_INDEX=token_metrics
PROXY_API_KEY=<choose/copy a key for the vLLM proxy>
EOF
sudo chmod 600 /opt/splunk-ai/token-meter.env
sudo bash /opt/splunk-ai/scripts/start-token-meter-proxies.sh
```
If the model host reaches the models over the network (not loopback), set the upstream:
```bash
sudo UPSTREAM_HOST=<MODEL_HOST_IP> bash /opt/splunk-ai/scripts/start-token-meter-proxies.sh
```
Ensure the Splunk host's HEC port (`8088`) is reachable from the model host.

---

## Point your clients at the proxies

Send traffic to the proxy instead of the model directly:

| Client | Change base URL to |
|---|---|
| Ollama (native `/api/*` or `/v1`) | `http://<proxy-host>:8101` |
| OpenAI / vLLM | `http://<proxy-host>:8100/v1` (API key = `PROXY_API_KEY`) |
| Splunk AITK provider | set the Ollama / OpenAI base URL to the proxy above |

Get the vLLM proxy key anytime: `sudo grep '^PROXY_API_KEY=' /opt/splunk-ai/token-meter.env`.

## Verify + view

```bash
# fire one metered call through the Ollama proxy, then search Splunk
curl -s http://localhost:8101/api/chat \
  -d '{"model":"<your-ollama-model>","messages":[{"role":"user","content":"hi"}],"stream":false}' >/dev/null
```
In Splunk: `index=token_metrics earliest=-15m`, or open **Apps → AI Token Usage**.
Fields: `backend, model, prompt_tokens, completion_tokens, total_tokens, latency_ms, user, app`.

## Optional — route metrics to a specific Splunk / per model

By default every proxy ships to the HEC in its local `token-meter.env`. To send different
models/backends to different Splunk instances, generate a routing table:
```bash
sudo TOKEN_METER_ROUTES='[{"match_field":"model","match_value":"my-model","hec_host":"10.0.0.9","hec_token":"<token-on-that-splunk>"}]' \
     TOKEN_METER_DEFAULT_HOST='<default-splunk-host>' \
  bash /opt/splunk-ai/scripts/configure-token-meter-routes.sh
sudo bash /opt/splunk-ai/scripts/start-token-meter-proxies.sh
```
`match_field` = `model` | `backend` | `app` | `user` | `path`; `match_mode` = `equals`
(default) | `contains` | `prefix`. Use `hec_host` for an explicit address, or `target_role`
(resolved via the AWS `SplunkAiRole` tag) if you're on the AWS platform.

## One backend only (run a single proxy directly)

If you don't want `start-token-meter-proxies.sh` launching both, run the proxy for just
your backend as a `systemd-run` unit:
```bash
# Ollama only
sudo systemd-run --unit=token-meter-ollama --collect --property=Restart=always \
  --setenv=UPSTREAM_URL=http://127.0.0.1:11434 --setenv=BACKEND_LABEL=ollama --setenv=LISTEN_PORT=8101 \
  --setenv=HEC_URL=https://<splunk>:8088/services/collector/event \
  --setenv=HEC_TOKEN=<token> --setenv=HEC_INDEX=token_metrics --setenv=HEC_VERIFY_TLS=false \
  python3 /opt/splunk-ai/token-meter-proxy/app.py
```
(For vLLM: `UPSTREAM_URL=http://127.0.0.1:8001`, `BACKEND_LABEL=vllm`, `LISTEN_PORT=8100`,
add `--setenv=PROXY_API_KEY=<key>`.)

## Config reference (env vars)

| Var | Default | Used by | Meaning |
|---|---|---|---|
| `SPLUNK_HOME` | `/opt/splunk` | 11 | Splunk install dir |
| `SPLUNK_ADMIN_PASSWORD` | — (required) | 11 | admin password for REST/restart |
| `SPLUNK_HEC_TOKEN` | generated | 11 | HEC token value (reused if already in `token-meter.env`) |
| `PROXY_API_KEY` | generated | 11, proxies | bearer key required by the vLLM/OpenAI proxy |
| `TOKEN_METRICS_INDEX` | `token_metrics` | all | index name |
| `HEC_PORT` | `8088` | 11 | HEC port |
| `OLLAMA_PORT` / `VLLM_PORT` | `11434` / `8001` | proxies | where your models listen |
| `OLLAMA_PROXY_PORT` / `VLLM_PROXY_PORT` | `8101` / `8100` | proxies | where the proxies listen |
| `UPSTREAM_HOST` | loopback | proxies | model host if not on the proxy host |
| `HEC_URL` / `HEC_TOKEN` / `HEC_INDEX` | from `token-meter.env` | proxies | where metrics are shipped |
| `METER_ENV_FILE` | `/opt/splunk-ai/token-meter.env` | 11, proxies | the shared HEC/key file |
| `PROXY_APP` | `/opt/splunk-ai/token-meter-proxy/app.py` | proxies | proxy source |

## Gotchas (already handled by `11`, but worth knowing)

- A new **HEC token loads only on a full restart** — `11` restarts (as the `splunk` user)
  and retries until a probe indexes, so the token is guaranteed loaded before it exits.
- The **index must be system-scoped** — an app-scoped `indexes.conf` can leave the index
  counted-but-unsearchable; `11` writes it to `etc/system/local/indexes.conf`.
- HEC `{"code":0}` means **accepted, not indexed** — `11` verifies by *searching*, not by
  the HEC reply. If you ever see empty results, confirm you're searching the Splunk the
  proxy ships to, and that a call actually went *through* the proxy.
