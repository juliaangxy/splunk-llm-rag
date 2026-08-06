#!/usr/bin/env python3
"""Remote MCP server: Amazon Bedrock Knowledge Base retrieval + web search.

Exposes two tools over the MCP **Streamable HTTP** transport, guarded by a static
`Authorization: Bearer <token>` check:

  * bedrock_kb_retrieve(query, max_results)  -> passages from a Bedrock Knowledge Base
  * web_search(query, max_results)           -> top web results (Tavily or Brave)

Configuration is all via environment (see below). Secrets may be passed either directly
(AUTH_TOKEN / SEARCH_API_KEY) or, preferably, as Secrets Manager ARNs the instance role can
read (AUTH_TOKEN_SECRET_ARN / SEARCH_API_KEY_SECRET_ARN) — the CloudFormation template uses
the ARN form so no secret is ever written to disk in plaintext.

Env:
  MCP_HOST                 bind address (default 0.0.0.0)
  MCP_PORT                 listen port (default 8000)
  MCP_PATH                 HTTP path for the MCP endpoint (default /mcp)
  MCP_STATELESS            "true" (default) = no mcp-session-id required, for clients like Splunk
                           AITK that don't resend it; "false" = stateful (session id required)
  MCP_JSON_RESPONSE        "true" (default) = reply with application/json; "false" = SSE stream.
                           AITK json.loads the body, so SSE breaks it ("Expecting value: line 1 …")
  MCP_TLS_CERT/MCP_TLS_KEY paths to a TLS cert+key; if set, the server serves HTTPS
  AUTH_TOKEN               bearer token clients must present (or AUTH_TOKEN_SECRET_ARN)
  BEDROCK_KB_ID            Bedrock Knowledge Base id the retrieve tool queries
  BEDROCK_REGION           region of the KB (default: AWS_REGION)
  SEARCH_PROVIDER          tavily | brave | none  (default tavily)
  SEARCH_API_KEY           web-search provider key (or SEARCH_API_KEY_SECRET_ARN)
"""
import hmac
import json
import os

import boto3
import httpx
from fastmcp import FastMCP
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import JSONResponse
from starlette.routing import Route


def _resolve_secret(direct_env: str, arn_env: str, region: str) -> str:
    """Return a secret: the direct env value if set, else fetched from Secrets Manager."""
    val = os.environ.get(direct_env, "").strip()
    if val:
        return val
    arn = os.environ.get(arn_env, "").strip()
    if not arn:
        return ""
    sm = boto3.client("secretsmanager", region_name=region)
    return sm.get_secret_value(SecretId=arn)["SecretString"].strip()


REGION = os.environ.get("AWS_REGION") or os.environ.get("BEDROCK_REGION") or "us-east-1"
BEDROCK_REGION = os.environ.get("BEDROCK_REGION", "").strip() or REGION
KB_ID = os.environ.get("BEDROCK_KB_ID", "").strip()
SEARCH_PROVIDER = os.environ.get("SEARCH_PROVIDER", "tavily").strip().lower()
SEARXNG_URL = os.environ.get("SEARXNG_URL", "").strip()  # for the open-source 'searxng' provider
MCP_PATH = os.environ.get("MCP_PATH", "/mcp")
# Stateless HTTP: don't hand out / require an mcp-session-id. Default true for broad client
# compatibility — some MCP clients (e.g. Splunk AITK) don't resend the session header on
# follow-up requests, which a stateful server rejects with "400 Bad Request: Missing session ID".
MCP_STATELESS = os.environ.get("MCP_STATELESS", "true").lower() == "true"
# JSON responses instead of SSE (text/event-stream). Default true: some MCP clients (e.g. Splunk
# AITK) json.loads the body directly and choke on an SSE stream ("Expecting value: line 1 column 1").
MCP_JSON_RESPONSE = os.environ.get("MCP_JSON_RESPONSE", "true").lower() == "true"

AUTH_TOKEN = _resolve_secret("AUTH_TOKEN", "AUTH_TOKEN_SECRET_ARN", REGION)
SEARCH_API_KEY = _resolve_secret("SEARCH_API_KEY", "SEARCH_API_KEY_SECRET_ARN", REGION)

mcp = FastMCP("splunk-mcp-server")


@mcp.tool()
def bedrock_kb_retrieve(query: str, max_results: int = 5) -> str:
    """Retrieve the most relevant passages from the configured Amazon Bedrock Knowledge Base.

    Args:
        query: natural-language question to search the knowledge base for.
        max_results: how many passages to return (1-20).
    Returns a JSON array of {text, score, source}.
    """
    if not KB_ID:
        return "No Bedrock knowledge base configured (BEDROCK_KB_ID is unset)."
    max_results = max(1, min(int(max_results), 20))
    client = boto3.client("bedrock-agent-runtime", region_name=BEDROCK_REGION)
    resp = client.retrieve(
        knowledgeBaseId=KB_ID,
        retrievalQuery={"text": query},
        retrievalConfiguration={"vectorSearchConfiguration": {"numberOfResults": max_results}},
    )
    results = [
        {
            "text": (r.get("content") or {}).get("text", ""),
            "score": r.get("score"),
            "source": r.get("location") or {},
        }
        for r in resp.get("retrievalResults", [])
    ]
    return json.dumps(results, indent=2)


@mcp.tool()
def web_search(query: str, max_results: int = 5) -> str:
    """Search the public web and return the top results.

    Args:
        query: the search query.
        max_results: how many results to return (1-20).
    Returns a JSON array of {title, url, snippet}. The backend is chosen by SEARCH_PROVIDER:
    open-source 'searxng' (self-hosted, no key) or 'duckduckgo' (no key), or the commercial
    'tavily'/'brave' (need SEARCH_API_KEY).
    """
    if SEARCH_PROVIDER == "none":
        return "Web search is disabled on this server."
    max_results = max(1, min(int(max_results), 20))

    # --- Open-source backends (no API key) ---
    if SEARCH_PROVIDER == "searxng":
        if not SEARXNG_URL:
            return "Web search not configured (SEARXNG_URL is unset)."
        r = httpx.get(
            f"{SEARXNG_URL.rstrip('/')}/search",
            params={"q": query, "format": "json"},
            timeout=30,
        )
        r.raise_for_status()
        results = [
            {"title": x.get("title"), "url": x.get("url"), "snippet": x.get("content")}
            for x in r.json().get("results", [])[:max_results]
        ]
        return json.dumps(results, indent=2)
    if SEARCH_PROVIDER == "duckduckgo":
        from ddgs import DDGS  # imported lazily so the dep is only needed for this provider

        with DDGS() as ddgs:
            rows = ddgs.text(query, max_results=max_results)
        results = [
            {"title": x.get("title"), "url": x.get("href"), "snippet": x.get("body")}
            for x in rows
        ]
        return json.dumps(results, indent=2)

    # --- Commercial backends (need SEARCH_API_KEY) ---
    if not SEARCH_API_KEY:
        return f"Web search provider '{SEARCH_PROVIDER}' needs SEARCH_API_KEY, which is unset."
    if SEARCH_PROVIDER == "tavily":
        r = httpx.post(
            "https://api.tavily.com/search",
            json={"api_key": SEARCH_API_KEY, "query": query, "max_results": max_results},
            timeout=30,
        )
        r.raise_for_status()
        results = [
            {"title": x.get("title"), "url": x.get("url"), "snippet": x.get("content")}
            for x in r.json().get("results", [])
        ]
        return json.dumps(results, indent=2)
    if SEARCH_PROVIDER == "brave":
        r = httpx.get(
            "https://api.search.brave.com/res/v1/web/search",
            headers={"X-Subscription-Token": SEARCH_API_KEY, "Accept": "application/json"},
            params={"q": query, "count": max_results},
            timeout=30,
        )
        r.raise_for_status()
        web = (r.json().get("web") or {}).get("results", [])
        results = [
            {"title": x.get("title"), "url": x.get("url"), "snippet": x.get("description")}
            for x in web
        ]
        return json.dumps(results, indent=2)
    return f"Unknown SEARCH_PROVIDER '{SEARCH_PROVIDER}' (expected searxng|duckduckgo|tavily|brave|none)."


class BearerAuthMiddleware(BaseHTTPMiddleware):
    """Require `Authorization: Bearer <AUTH_TOKEN>` on every request except /health."""

    async def dispatch(self, request, call_next):
        if request.url.path.rstrip("/") == "/health":
            return await call_next(request)
        if AUTH_TOKEN:
            presented = request.headers.get("authorization", "")
            if not hmac.compare_digest(presented, f"Bearer {AUTH_TOKEN}"):
                return JSONResponse({"error": "unauthorized"}, status_code=401)
        return await call_next(request)


async def _health(_request):
    return JSONResponse({"status": "ok"})


# Streamable-HTTP ASGI app, with an unauthenticated health route + bearer auth on the rest.
app = mcp.http_app(path=MCP_PATH, stateless_http=MCP_STATELESS, json_response=MCP_JSON_RESPONSE)
app.router.routes.append(Route("/health", _health, methods=["GET"]))
app.add_middleware(BearerAuthMiddleware)


if __name__ == "__main__":
    import uvicorn

    if not AUTH_TOKEN:
        print("WARNING: no AUTH_TOKEN configured — the server is UNAUTHENTICATED", flush=True)
    ssl_kwargs = {}
    cert, key = os.environ.get("MCP_TLS_CERT", ""), os.environ.get("MCP_TLS_KEY", "")
    if cert and key:
        ssl_kwargs = {"ssl_certfile": cert, "ssl_keyfile": key}
    uvicorn.run(
        app,
        host=os.environ.get("MCP_HOST", "0.0.0.0"),
        port=int(os.environ.get("MCP_PORT", "8000")),
        **ssl_kwargs,
    )
