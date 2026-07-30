# AI Token Counting

Accurate, per-call token metering for the models served by this platform — **Ollama**
(native API) and **vLLM / any OpenAI-compatible server** — shipped into a Splunk
`token_metrics` index with an **AI Token Usage** dashboard.

> **Source of truth:** everything below lives under [`platform/`](platform/). This file is
> the overview; the runnable pieces are the scripts and the proxy in that folder.

## How it works

A tiny, dependency-free reverse proxy ([`platform/token-meter-proxy/app.py`](platform/token-meter-proxy/app.py))
sits in front of the model server. It transparently forwards every request, reads the
**token usage the backend itself reports** (not an estimate), and posts one metric event
per call to a Splunk HTTP Event Collector (HEC):

- OpenAI-compatible (vLLM, Ollama `/v1`): `usage.prompt_tokens` / `completion_tokens`
  (for streaming it injects `stream_options.include_usage=true`).
- Ollama native (`/api/chat`, `/api/generate`): `prompt_eval_count` / `eval_count`.

It is stdlib-only Python 3, records usage even if the client disconnects mid-stream, and
runs as a host `systemd` unit (no container required).

```
client / AITK ─▶ token-meter proxy ─▶ model server (Ollama :11434 / vLLM :8001)
                      └─ one metric per call ─▶ Splunk HEC ─▶ index=token_metrics ─▶ dashboard
```

### Where usage is metered (important)

AITK/DSDL does **not** call the model from the search head's `splunkd` — it dispatches the
job to the shared DSDL container on the GPU host, which makes the model call from there. So
**all** model usage is metered by the **GPU-host proxy**, regardless of which instance's UI
started it. The metric (a small HEC POST) is decoupled from the model traffic, so it can be
shipped to whichever Splunk you want to view it in — by default the **search head's**
`token_metrics` index. See `platform/README.md` → *Where usage is metered* for the full
explanation and the per-model/-source routing table.

## Components (all under `platform/`)

| Path | Purpose |
|---|---|
| [`token-meter-proxy/app.py`](platform/token-meter-proxy/app.py) | The metering reverse proxy (Ollama + OpenAI), with optional per-model/-source HEC routing |
| [`scripts/11-token-metrics.sh`](platform/scripts/11-token-metrics.sh) | Creates the **system-scoped** `token_metrics` index + HEC token, restarts to load them, self-tests end-to-end, installs the visible **AI Token Usage** app/dashboard |
| [`scripts/start-token-meter-proxies.sh`](platform/scripts/start-token-meter-proxies.sh) | Starts the vLLM (:8100) and Ollama (:8101) proxies as systemd units |
| [`scripts/configure-token-meter-routes.sh`](platform/scripts/configure-token-meter-routes.sh) | Generates the routing table (which model/source → which Splunk HEC), resolving peer IPs by their `SplunkAiRole` tag |
| [`scripts/configure-splunk-llm.sh`](platform/scripts/configure-splunk-llm.sh) | Points AITK/DSDL at the proxies (`--mode proxy`) or the models directly (`--mode direct`) |
| [`scripts/diagnose-token-metering.sh`](platform/scripts/diagnose-token-metering.sh) | Read-only end-to-end diagnostic (proxy → HEC → index) |

On a fresh deploy with `DeployTokenMeterProxy=true`, the bootstrap runs `11-token-metrics.sh`
on each instance and starts the proxies automatically — no manual steps.

## Setting it up by hand (or on someone else's Splunk)

1. **Create the index** — Splunk Web → Settings → Indexes → New → `token_metrics` (Events).
   Or `splunk add index token_metrics`. Define it at **system/global scope**, never inside a
   custom app's `local/indexes.conf`, or the indexer drops events as "unconfigured index".
2. **Create the HEC token** — Settings → Data inputs → HTTP Event Collector: enable all
   tokens (port 8088), new token `token-meter` with default index `token_metrics` and
   sourcetype `token_metrics`. **Restart Splunk** — HEC tokens only load on a restart.
3. **Run the proxy** in front of the model, pointed at the HEC:
   ```bash
   UPSTREAM_URL=http://<model>:11434 LISTEN_PORT=8101 BACKEND_LABEL=ollama \
   HEC_URL=https://<splunk>:8088/services/collector/event HEC_TOKEN=<token> \
   HEC_INDEX=token_metrics HEC_VERIFY_TLS=false python3 app.py
   # OpenAI/vLLM: UPSTREAM_URL=http://<model>:8001 LISTEN_PORT=8100 BACKEND_LABEL=vllm PROXY_API_KEY=<key>
   ```
4. **Point clients at the proxy** — Ollama → `http://<proxy>:8101`; OpenAI/vLLM →
   `http://<proxy>:8100/v1` with the `PROXY_API_KEY`. In AITK set the provider base URL to
   the proxy.
5. **View** — search `index=token_metrics` or open **Apps → AI Token Usage**.

## AITK OpenAI connection values (vLLM Granite example)

| Field | Value |
|---|---|
| Base URL | `http://<gpu-private-ip>:8100/v1` (metered) — or `:8001/v1` direct/unmetered |
| API Key | the `PROXY_API_KEY` (any value for the direct `:8001` endpoint) |
| Model | `granite-3.1-2b-instruct` |
| Request timeout | `200` |

## Fields in `index=token_metrics`

`backend` (ollama/vllm), `model`, `path`, `prompt_tokens`, `completion_tokens`,
`total_tokens`, `latency_ms`, `status`, `user`, `app`.

## Quick reference

**Ports** — Ollama model `11434`, vLLM model `8001`; Ollama proxy `8101`, vLLM proxy `8100`; Splunk HEC `8088`.

**Proxy env vars** — `UPSTREAM_URL`, `LISTEN_PORT`, `BACKEND_LABEL`, `HEC_URL`, `HEC_TOKEN`, `HEC_INDEX`, `HEC_VERIFY_TLS`, `PROXY_API_KEY`, `HEC_ROUTES_FILE`, `DEFAULT_APP`.

**Common commands** (on an instance):
```bash
sudo bash /opt/splunk-ai/scripts/11-token-metrics.sh                 # create index + HEC, restart, self-test, install dashboard
sudo bash /opt/splunk-ai/scripts/start-token-meter-proxies.sh        # start/refresh the vLLM + Ollama proxies
sudo TOKEN_METER_DEFAULT_ROLE=search-head \
  bash /opt/splunk-ai/scripts/configure-token-meter-routes.sh        # route metrics to a chosen Splunk instance
sudo bash /opt/splunk-ai/scripts/configure-splunk-llm.sh --mode proxy # point AITK/DSDL at the proxies
sudo bash /opt/splunk-ai/scripts/diagnose-token-metering.sh          # read-only end-to-end diagnostic
```

**Verify indexing** (remember `code:0` ≠ indexed):
```bash
curl -k https://<splunk>:8088/services/collector/event \
  -H "Authorization: Splunk <TOKEN>" \
  -d '{"event":{"probe":1},"index":"token_metrics","sourcetype":"token_metrics"}'
# then in Splunk:  index=token_metrics
```

## Gotchas (learned the hard way)

- **Restart after adding a HEC token** — a reload isn't enough; otherwise `Invalid token`.
- **Index must be system/global scope** — an app-scoped index can be counted-but-unsearchable
  (dir never created; events dropped as "unconfigured index").
- **HEC `{"code":0}` means *accepted*, not *indexed*** — always confirm by searching, and use
  `totalEventCount` via `/services/data/indexes/token_metrics` as the authoritative count.
- Cross-instance routing needs the token the **destination** Splunk registered; the platform
  uses one shared per-environment HEC token so both instances agree.
