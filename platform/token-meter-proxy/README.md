# token-meter-proxy

A tiny, dependency-free reverse proxy that meters LLM token usage and ships it to a
Splunk index. Put it in front of any **OpenAI-compatible** server (vLLM, Vertex, LiteLLM,
Ollama's `/v1`) or **Ollama-native** server, on whatever GPU/CPU compute runs your models.
Point your client (e.g. Splunk AITK / DSDL) at the proxy instead of the model directly, and
every call's real token counts land in `index=token_metrics`.

- **Accurate** — counts come from the backend's own `usage` (OpenAI) or
  `prompt_eval_count`/`eval_count` (Ollama), never estimated. Streaming is handled: the proxy
  sets `stream_options.include_usage=true` for OpenAI streams and sums Ollama NDJSON.
- **Transparent** — forwards the request/response body and status unchanged; the client sees
  a normal OpenAI/Ollama endpoint.
- **Portable** — one small Python file, no third-party packages; the image is easy to share
  and run offline.

## Build

```bash
docker build -t token-meter-proxy:latest platform/token-meter-proxy
```

## Run

One proxy instance per upstream. Example: meter a vLLM server on the same host.

```bash
docker run -d --name token-meter-vllm --restart unless-stopped \
  -p 8100:8100 \
  -e UPSTREAM_URL=http://vllm:8001 \
  -e BACKEND_LABEL=vllm \
  -e LISTEN_PORT=8100 \
  -e HEC_URL=https://splunk-host:8088/services/collector/event \
  -e HEC_TOKEN=<hec-token> \
  -e HEC_INDEX=token_metrics \
  -e PROXY_API_KEY=<key clients must send as Bearer> \
  token-meter-proxy:latest
```

Meter Ollama too (native API auto-detected):

```bash
docker run -d --name token-meter-ollama --restart unless-stopped \
  -p 8101:8101 \
  -e UPSTREAM_URL=http://ollama:11434 -e BACKEND_LABEL=ollama -e LISTEN_PORT=8101 \
  -e HEC_URL=https://splunk-host:8088/services/collector/event -e HEC_TOKEN=<hec-token> \
  token-meter-proxy:latest
```

Then point the client at the proxy — e.g. in Splunk AITK's custom-model form set
**Endpoint** = `http://<proxy-host>:8100/v1`, **Model** = your model name, **API Key** =
the `PROXY_API_KEY` value.

## Configuration (env vars)

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
| `REQUEST_TIMEOUT` | `600` | Upstream timeout (seconds) |

## Metric event fields
`ts, backend, model, path, prompt_tokens, completion_tokens, total_tokens, latency_ms,
status, user, app` — `user`/`app` are populated from `X-Splunk-User` / `X-Splunk-App`
request headers when the caller sends them.
