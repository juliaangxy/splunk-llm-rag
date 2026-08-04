#!/usr/bin/env python3
"""Token-metering reverse proxy for OpenAI-compatible and Ollama-native model servers.

Sits in front of a model backend (vLLM, Ollama, or any OpenAI-compatible server),
transparently forwards every request, extracts the token usage the backend reports,
and ships one metric event per call to a Splunk HTTP Event Collector (HEC) index so
users can track token consumption. Dependency-free (Python standard library only) so
the image is tiny and airgap-friendly, and the container can be shared and dropped in
front of whatever model server runs on someone else's GPU/CPU compute.

Accuracy: token counts come from the backend itself, not an estimate.
  * OpenAI-compatible (vLLM, Ollama /v1): response `usage.prompt_tokens` / `completion_tokens`.
    For streaming, the proxy injects `stream_options.include_usage=true` so the final
    SSE chunk carries the real usage.
  * Ollama native (/api/chat, /api/generate): `prompt_eval_count` / `eval_count`
    (summed across streamed lines).

Configuration (environment variables):
  UPSTREAM_URL     Base URL of the model server, e.g. http://vllm:8001 or http://ollama:11434  (required)
  LISTEN_PORT      Port to listen on (default 8100)
  BACKEND_LABEL    Label recorded in metrics: vllm | ollama | <name> (default "upstream")
  HEC_URL          Splunk HEC collector URL, e.g. https://splunk:8088/services/collector/event
  HEC_TOKEN        Splunk HEC token
  HEC_INDEX        Splunk index for metrics (default token_metrics)
  HEC_SOURCETYPE   Sourcetype (default token_metrics)
  HEC_VERIFY_TLS   "true" to verify HEC TLS (default "false"; Splunk HEC is usually self-signed)
  PROXY_API_KEY    If set, require this bearer token on inbound requests (else pass through)
  REQUEST_TIMEOUT  Upstream timeout seconds (default 600)
"""

import json
import os
import ssl
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM_URL = os.environ.get("UPSTREAM_URL", "").rstrip("/")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8100"))
BACKEND_LABEL = os.environ.get("BACKEND_LABEL", "upstream")
HEC_URL = os.environ.get("HEC_URL", "").strip()
HEC_TOKEN = os.environ.get("HEC_TOKEN", "").strip()
HEC_INDEX = os.environ.get("HEC_INDEX", "token_metrics")
HEC_SOURCETYPE = os.environ.get("HEC_SOURCETYPE", "token_metrics")
HEC_VERIFY_TLS = os.environ.get("HEC_VERIFY_TLS", "false").lower() == "true"
# Optional HEC destination file: a JSON file naming which Splunk HEC (url/token/index) to
# ship metrics to, so the destination can be resolved at deploy time (e.g. the GPU host
# shipping its usage to the search head) without baking it into the systemd unit. When
# unset/absent, the HEC_URL/HEC_TOKEN env above is used. Hot-reloaded on mtime change. Schema:
#   { "default": {"hec_url": "...", "hec_token": "...", "hec_index": "..."} }
HEC_ROUTES_FILE = os.environ.get("HEC_ROUTES_FILE", "").strip()
PROXY_API_KEY = os.environ.get("PROXY_API_KEY", "").strip()
REQUEST_TIMEOUT = float(os.environ.get("REQUEST_TIMEOUT", "600"))
# Cap how much of each response we buffer to find the usage record, so memory stays
# bounded regardless of generation size. The usage object/chunk is always at the end,
# so keeping the tail is sufficient. Default 256 KiB.
MAX_CAPTURE_BYTES = int(os.environ.get("MAX_CAPTURE_BYTES", str(256 * 1024)))
# AITK's client to the model does not forward Splunk's user/app, so headers are usually
# absent. Fall back to the OpenAI `user` body field (if the caller sets it) and to these
# static labels so events are still attributable to the source.
DEFAULT_APP = os.environ.get("DEFAULT_APP", "").strip()
DEFAULT_USER = os.environ.get("DEFAULT_USER", "").strip()
# Identifies the calling search head when ONE proxy (e.g. on the GPU host) meters traffic from
# several. Prefer the X-Splunk-Origin header; else this env; else the client's IP (each search
# head connects to the proxy directly, so its address distinguishes it).
DEFAULT_ORIGIN = os.environ.get("DEFAULT_ORIGIN", "").strip()

if not UPSTREAM_URL:
    print("FATAL: UPSTREAM_URL is required", file=sys.stderr)
    sys.exit(1)

_hec_ctx = ssl.create_default_context()
if not HEC_VERIFY_TLS:
    _hec_ctx.check_hostname = False
    _hec_ctx.verify_mode = ssl.CERT_NONE


def log(msg):
    print(f"[{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}] {msg}", flush=True)


def _default_route():
    return {"hec_url": HEC_URL, "hec_token": HEC_TOKEN, "hec_index": HEC_INDEX}


_route_lock = threading.Lock()
_route_cache = {"mtime": None, "default": _default_route()}


def _load_default():
    """Return the HEC destination, hot-reloading the JSON file on mtime change.

    Falls back to the single HEC_URL/HEC_TOKEN default when no destination file is set or
    it can't be read/parsed — a bad file must never stop metrics from flowing.
    """
    if not HEC_ROUTES_FILE:
        return _default_route()
    try:
        mtime = os.stat(HEC_ROUTES_FILE).st_mtime
    except OSError:
        return _default_route()
    with _route_lock:
        if _route_cache["mtime"] != mtime:
            try:
                with open(HEC_ROUTES_FILE, encoding="utf-8") as fh:
                    cfg = json.load(fh) or {}
                d = cfg.get("default") or {}
                default = {
                    "hec_url": (d.get("hec_url") or HEC_URL).strip(),
                    "hec_token": (d.get("hec_token") or HEC_TOKEN).strip(),
                    "hec_index": d.get("hec_index") or HEC_INDEX,
                }
                _route_cache.update(mtime=mtime, default=default)
                log(f"loaded HEC destination from {HEC_ROUTES_FILE}")
            except Exception as exc:  # noqa: BLE001 - never break metering on a bad file
                log(f"WARN: failed to load {HEC_ROUTES_FILE}: {exc}; using default HEC")
                _route_cache.update(mtime=mtime, default=_default_route())
        return _route_cache["default"]


def send_to_hec(event, route=None):
    """Ship one metric event to Splunk HEC (best-effort, off the response path)."""
    if route is None:
        route = _load_default()
    hec_url = route.get("hec_url") or ""
    hec_token = route.get("hec_token") or ""
    hec_index = route.get("hec_index") or HEC_INDEX
    if not hec_url or not hec_token:
        log(f"metric (no HEC configured): {json.dumps(event)}")
        return
    body = json.dumps({
        "event": event,
        "sourcetype": HEC_SOURCETYPE,
        "index": hec_index,
        "time": event.get("ts", time.time()),
    }).encode("utf-8")
    req = urllib.request.Request(hec_url, data=body, method="POST")
    req.add_header("Authorization", f"Splunk {hec_token}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=10, context=_hec_ctx) as resp:
            resp.read()
    except Exception as exc:  # noqa: BLE001 - never break the proxy on metric failure
        log(f"WARN: HEC send failed: {exc}")


def extract_usage(payload):
    """Return (prompt, completion, total) from an OpenAI or Ollama JSON object, or None."""
    if not isinstance(payload, dict):
        return None
    usage = payload.get("usage")
    if isinstance(usage, dict) and ("prompt_tokens" in usage or "completion_tokens" in usage):
        p = int(usage.get("prompt_tokens") or 0)
        c = int(usage.get("completion_tokens") or 0)
        t = int(usage.get("total_tokens") or (p + c))
        return p, c, t
    if "prompt_eval_count" in payload or "eval_count" in payload:
        p = int(payload.get("prompt_eval_count") or 0)
        c = int(payload.get("eval_count") or 0)
        return p, c, p + c
    return None


def parse_streaming_usage(raw_bytes):
    """Scan a streamed body (SSE or Ollama NDJSON) for the last usage found."""
    found = None
    for line in raw_bytes.split(b"\n"):
        line = line.strip()
        if not line:
            continue
        if line.startswith(b"data:"):
            line = line[5:].strip()
        if line == b"[DONE]":
            continue
        try:
            obj = json.loads(line.decode("utf-8"))
        except Exception:  # noqa: BLE001
            continue
        u = extract_usage(obj)
        if u:
            found = u
    return found


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # silence default logging
        return

    def _reject(self, code, msg):
        data = json.dumps({"error": msg}).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _authorized(self):
        if not PROXY_API_KEY:
            return True
        auth = self.headers.get("Authorization", "")
        return auth.removeprefix("Bearer ").strip() == PROXY_API_KEY

    def do_GET(self):
        self._proxy("GET")

    def do_POST(self):
        self._proxy("POST")

    def _read_body(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        return self.rfile.read(length) if length else b""

    def _proxy(self, method):
        if not self._authorized():
            self._reject(401, "unauthorized")
            return

        body = self._read_body()
        model = ""
        req_user = ""
        is_stream = False
        # Inject include_usage for OpenAI-style streaming so we get accurate counts.
        if body:
            try:
                obj = json.loads(body)
                model = str(obj.get("model", "") or "")
                req_user = str(obj.get("user", "") or "")
                is_stream = bool(obj.get("stream", False))
                if is_stream and self.path.startswith("/v1/"):
                    so = obj.get("stream_options") or {}
                    so["include_usage"] = True
                    obj["stream_options"] = so
                    body = json.dumps(obj).encode("utf-8")
            except Exception:  # noqa: BLE001 - forward non-JSON untouched
                pass

        url = f"{UPSTREAM_URL}{self.path}"
        up_req = urllib.request.Request(url, data=body if method == "POST" else None, method=method)
        for h in ("Content-Type", "Authorization", "Accept"):
            if self.headers.get(h):
                up_req.add_header(h, self.headers.get(h))
        if body:
            up_req.add_header("Content-Length", str(len(body)))

        started = time.time()
        try:
            upstream = urllib.request.urlopen(up_req, timeout=REQUEST_TIMEOUT)
        except urllib.error.HTTPError as e:
            err = e.read()
            self.send_response(e.code)
            self.send_header("Content-Type", e.headers.get("Content-Type", "application/json"))
            self.send_header("Content-Length", str(len(err)))
            self.end_headers()
            self.wfile.write(err)
            return
        except Exception as exc:  # noqa: BLE001
            self._reject(502, f"upstream error: {exc}")
            return

        status = upstream.getcode()
        ctype = upstream.headers.get("Content-Type", "application/octet-stream")
        captured = bytearray()

        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        # A client (e.g. AITK) that hangs up mid-stream must NOT cost us the metric: the
        # token usage arrives in the FINAL chunk, so if we stop reading upstream when the
        # client disconnects we lose the count. Keep draining upstream to capture usage;
        # only writing back to the client stops.
        client_alive = True
        try:
            while True:
                chunk = upstream.read(8192)
                if not chunk:
                    break
                captured.extend(chunk)
                if len(captured) > MAX_CAPTURE_BYTES:
                    del captured[:len(captured) - MAX_CAPTURE_BYTES]
                if client_alive:
                    try:
                        size = f"{len(chunk):X}\r\n".encode("ascii")
                        self.wfile.write(size + chunk + b"\r\n")
                    except Exception as exc:  # noqa: BLE001 - client gone, keep draining
                        client_alive = False
                        log(f"WARN: client disconnected mid-stream; draining upstream to record usage: {exc}")
            if client_alive:
                try:
                    self.wfile.write(b"0\r\n\r\n")
                except Exception:  # noqa: BLE001
                    pass
        except Exception as exc:  # noqa: BLE001
            log(f"WARN: upstream read failed: {exc}")
        finally:
            upstream.close()

        latency_ms = int((time.time() - started) * 1000)
        self._record(bytes(captured), ctype, model, is_stream, latency_ms, status, req_user)

    def _record(self, raw, ctype, model, is_stream, latency_ms, status, req_user=""):
        usage = None
        if "text/event-stream" in ctype or is_stream:
            usage = parse_streaming_usage(raw)
        else:
            try:
                usage = extract_usage(json.loads(raw))
            except Exception:  # noqa: BLE001
                usage = parse_streaming_usage(raw)  # NDJSON fallback (Ollama)
        if not usage:
            return
        prompt, completion, total = usage
        user = (self.headers.get("X-Splunk-User") or self.headers.get("X-User")
                or req_user or DEFAULT_USER or "")
        app = self.headers.get("X-Splunk-App") or DEFAULT_APP or ""
        origin = (self.headers.get("X-Splunk-Origin") or DEFAULT_ORIGIN
                  or (self.client_address[0] if getattr(self, "client_address", None) else ""))
        event = {
            "ts": time.time(),
            "backend": BACKEND_LABEL,
            "model": model,
            "path": self.path,
            "prompt_tokens": prompt,
            "completion_tokens": completion,
            "total_tokens": total,
            "latency_ms": latency_ms,
            "status": status,
            "user": user,
            "app": app,
            "origin": origin,
        }
        threading.Thread(target=send_to_hec, args=(event,), daemon=True).start()


def main():
    _dflt = _load_default()
    dest = HEC_ROUTES_FILE if HEC_ROUTES_FILE else "env"
    log(f"token-meter-proxy -> upstream={UPSTREAM_URL} label={BACKEND_LABEL} "
        f"listen={LISTEN_PORT} hec={'on' if _dflt.get('hec_url') else 'off'} "
        f"index={_dflt.get('hec_index')} dest={dest}")
    server = ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
