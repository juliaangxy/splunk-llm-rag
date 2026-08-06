# Token metering (token-meter proxy)

A tiny, dependency-free reverse proxy that meters LLM token usage and ships it to a Splunk index.
Put it in front of any **OpenAI-compatible** server (vLLM, Vertex, LiteLLM, Ollama's `/v1`) or
**Ollama-native** server, on whatever GPU/CPU compute runs your models. Point your client (e.g.
Splunk AITK / DSDL) at the proxy instead of the model directly, and every call's real token counts
land in `index=token_metrics`.

- **Accurate** — counts come from the backend's own `usage` (OpenAI) or
  `prompt_eval_count`/`eval_count` (Ollama), never estimated. Streaming is handled: the proxy sets
  `stream_options.include_usage=true` for OpenAI streams and sums Ollama NDJSON.
- **Transparent** — forwards the request/response body and status unchanged; the client sees a
  normal OpenAI/Ollama endpoint.
- **Portable** — one small Python file (`token-meter-proxy/app.py`), stdlib-only, ~50 MB and
  bounded in memory; light enough to co-locate with the models, and packaged as a tiny image
  (`token-meter-proxy/Dockerfile`) for hosts where you'd rather run a container.

> **This README covers *what it does and how it works*.** For the ways to get it running — the
> one-command installer (a `systemd` unit) **or** the Docker container, copying files, verifying,
> and uninstalling — see **[TOKEN-METERING-INSTALL.md](TOKEN-METERING-INSTALL.md)**.

## How it works

```
client / AITK ─▶ token-meter proxy ─▶ your model (Ollama :11434 / vLLM :8001)
                     └─ one metric per call ─▶ Splunk HEC ─▶ index=token_metrics
```

The proxy reads the real `usage` the server returns and ships one event per call to
`index=token_metrics`. It is model-agnostic, so the same mechanism meters a vLLM model and Ollama
models alike. Run one proxy instance per upstream (one for vLLM on `:8100`, one for Ollama on
`:8101`), each forwarding to its model and posting a metric to Splunk HEC.

## Where usage is metered (architecture)

In the [Splunk AI RAG platform](../../README.md), AITK/DSDL does **not** call the model from the
search head's `splunkd`. When you invoke a model from the AI Toolkit, Splunk **dispatches the job
to the shared DSDL container on the GPU host** (`mltk-container/local/containers.conf` → `api_url =
https://<gpu>:5001`), and that container makes the model call **from the GPU**. So every model call
— no matter which instance's UI you started it from — is metered by the **GPU-host proxy**:

```
AITK UI (search head or GPU)
   └─ dispatch job ─▶ DSDL container (GPU host)
                        └─ model call ─▶ GPU proxy :8100/:8101 ─▶ vLLM/Ollama (GPU)
                                            └─ metric (HEC POST) ─▶  chosen Splunk HEC
```

Two consequences worth knowing:
- **You cannot attribute a call to "who started it."** AITK forwards no Splunk user/app/origin into
  the model HTTP call, so container-dispatched calls all look identical at the proxy.
- **The metric is decoupled from the model traffic.** The HEC event is a tiny POST that the proxy
  can send to *any* Splunk instance, independent of where the model runs — that's the destination
  knob below. By default the deploy points it at the **search head**, so all usage lands in one
  index there, without hair-pinning the heavy model traffic.

## What gets recorded (metric fields)

Each metered call is one event in `index=token_metrics`:

`ts, backend, model, path, prompt_tokens, completion_tokens, total_tokens, latency_ms, status,
user, app, origin`

- `user` / `app` come from `X-Splunk-User` / `X-Splunk-App` request headers when the caller sends them.
- `origin` comes from `X-Splunk-Origin` (else `DEFAULT_ORIGIN`, else the client IP) — used to
  attribute calls when many search heads share one proxy.
- `prompt` / `response` are added **only** when `LOG_PROMPT` / `LOG_COMPLETION` are enabled (off by
  default — see the Configuration warning).

View them with `index=token_metrics earliest=-15m` or **Apps → token_metrics → AI Token Usage**.

## Configuration (env vars)

The proxy is configured entirely by environment — the same variables whether it runs as a systemd
unit or a container:

| Var | Default | Meaning |
|-----|---------|---------|
| `UPSTREAM_URL` | (required) | Base URL of the model server, e.g. `http://vllm:8001` |
| `LISTEN_PORT` | `8100` | Port the proxy listens on |
| `BACKEND_LABEL` | `upstream` | Recorded in each metric (`vllm`, `ollama`, …) |
| `HEC_URL` | – | Splunk HEC event endpoint; if unset, metrics are logged to stdout |
| `HEC_TOKEN` | – | Splunk HEC token |
| `HEC_INDEX` | `token_metrics` | Destination index |
| `HEC_SOURCETYPE` | `token_metrics` | Sourcetype |
| `HEC_VERIFY_TLS` | `false` | Verify HEC TLS (Splunk HEC is usually self-signed) |
| `PROXY_API_KEY` | – | If set, inbound requests must send `Authorization: Bearer <key>` |
| `DEFAULT_ORIGIN` | – | Fallback `origin` when no `X-Splunk-Origin` header is sent |
| `REQUEST_TIMEOUT` | `600` | Upstream timeout (seconds) |
| `LOG_PROMPT` | `false` | Also record the request **prompt** text in each event (see warning below) |
| `LOG_COMPLETION` | `false` | Also record the **response** text in each event (see warning below) |
| `MAX_CONTENT_CHARS` | `2000` | Truncate logged prompt/response to this many characters |

> ⚠️ **Content logging is off by default.** `LOG_PROMPT`/`LOG_COMPLETION` add `prompt` / `response`
> fields containing the **actual text**, which may hold PII/secrets and is far larger than a
> counts-only metric (license + storage cost). Turn them on only for an index whose access you
> control. For streamed responses over `MAX_CAPTURE_BYTES` (256 KiB) only the tail is buffered, so
> a very long logged response can be partial.

## Where token usage lands (destination)

Because the metric is just a HEC POST, one deployment can funnel **all** usage into a single index
on whichever Splunk you choose. In the platform this is one CloudFormation param (set in
`config/<env>.json`), applied automatically at deploy time (bootstrap runs
`configure-token-meter-routes.sh` before starting the proxies):

| Param | Default | Meaning |
|---|---|---|
| `TokenMeterDefaultRole` | `search-head` | Which Splunk stores all usage: `search-head` \| `gpu-host` \| `self` (the instance that generated it). |

The role is resolved to a private IP automatically via the instance's `SplunkAiRole` tag
(`ec2:DescribeInstances`), so no IPs are hard-coded. The default `search-head` puts all usage (from
both instances) in one index on the search head.

### Which file controls the destination — `token-meter.env` vs the routes file

Two files on the proxy host can influence metering, but only **one decides where metrics ship**:

| File | Written by | Holds | For the destination |
|---|---|---|---|
| `/opt/splunk-ai/token-meter.env` | `11-token-metrics.sh` | Base config: `HEC_TOKEN`, `HEC_INDEX`, `PROXY_API_KEY`, upstream URLs, and a default `HEC_URL`. Always read. | **Fallback** — used when there is no routes file. |
| `/opt/splunk-ai/token-meter-routes.json` | `configure-token-meter-routes.sh` | **Optional** override: `{hec_url, hec_token, hec_index}`. Hot-reloaded; kept fresh by the self-heal timer. | **Winner** — used whenever the file exists. |

So only one destination applies at a time:

- **Same-host metering** (proxy → its own Splunk): just `token-meter.env` (its `HEC_URL` points at localhost). **No routes file needed.**
- **Cross-host metering** (e.g. the GPU-host proxy → the search head): the **routes file** provides the destination and overrides `token-meter.env`'s `HEC_URL`. `token-meter.env` still supplies the token, index, and API key.

The proxy uses the routes file only when `HEC_ROUTES_FILE` points at an existing file (default
`/opt/splunk-ai/token-meter-routes.json`); a missing or unreadable file silently falls back to
`token-meter.env`, so a bad file never stops metrics flowing. See
**[`token-meter-routes.example.json`](token-meter-routes.example.json)** for the schema — though you
normally **generate** it with `configure-token-meter-routes.sh` (role → IP) rather than hand-writing it.

**Token caveat:** shipping a metric to another instance's HEC requires the token that instance
registered. This is automatic because `SPLUNK_HEC_TOKEN` is a per-environment **shared secret**
(both instances fetch the same one and `11-token-metrics.sh` registers it on each). Only if you
deliberately use per-instance tokens do you need to set a route's `hec_token` explicitly.

> A `TokenMeterRoutesJson` param still exists in the templates for backward compatibility but is
> **inert** — per-model/-source routing was removed because it couldn't be tested end-to-end.
> Leave it `[]`. Changing the destination on a running host, or setting it on-prem (no AWS tags),
> is an operational task — see the **Destination** notes in
> [TOKEN-METERING-INSTALL.md](TOKEN-METERING-INSTALL.md#advanced--run-the-pieces-directly--custom-endpoints).

## Turn it on (in a deployed platform)

Deployment stages the proxy on the GPU host but leaves it **off** (vLLM itself is deployed by
default with `DeployVllm=true`; set it `false` to skip). Enable metering with:

```bash
# 1. Start the proxies (vLLM -> :8100, Ollama -> :8101), sending to token_metrics:
sudo /opt/splunk-ai/scripts/token-meter/start-token-meter-proxies.sh
# 2. Point Splunk at the proxies (run on BOTH instances), then reload DSDL:
sudo /opt/splunk-ai/scripts/configure-splunk-llm.sh --mode proxy
```
Back to calling models directly (no metering): `configure-splunk-llm.sh --mode direct`.

For everything operational — installing on a standalone Splunk + Ollama/vLLM stack, the two ways to
run the proxy (**systemd unit vs. Docker container**), the many-search-heads scenario, verifying,
and uninstalling — see **[TOKEN-METERING-INSTALL.md](TOKEN-METERING-INSTALL.md)**.
