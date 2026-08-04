# MCP server — Bedrock Knowledge Base + web search

A remote **MCP (Model Context Protocol) server** on EC2 that Splunk Enterprise (or any MCP
client) can call over the **Streamable HTTP** transport, guarded by an `Authorization: Bearer`
token. It exposes two tools:

| Tool | What it does |
|---|---|
| `bedrock_kb_retrieve(query, max_results)` | Retrieves passages from an **Amazon Bedrock Knowledge Base** |
| `web_search(query, max_results)` | Runs a **web search** — open-source SearXNG/DuckDuckGo, or commercial Tavily/Brave |

```
Splunk Enterprise (another subnet) ─┐
                                     ├─▶ MCP server :8000/mcp ─┬─▶ Bedrock KB (bedrock-agent-runtime:Retrieve)
Internet (optional) ─────────────────┘   Bearer-token auth     └─▶ Web search API (Tavily/Brave)
```

The [CloudFormation template](cloudformation/mcp-server.yaml) either **creates a VPC** or
deploys into an **existing one** (e.g. the Splunk VPC), and optionally attaches an Elastic IP
for internet reachability. The instance clones this repo and runs
[`server/mcp_server.py`](server/mcp_server.py) as a `systemd` unit.

## Prerequisites

- An **Amazon Bedrock Knowledge Base** (note its id) in a Bedrock-enabled region.
- A **web-search backend** (`WebSearchProvider`), one of:
  - `searxng` — open source, **no key**. Leave `SearxngUrl` **empty** and the bootstrap installs [SearXNG](https://docs.searxng.org) on the **same instance** (Docker, bound to `127.0.0.1:8888`); or set `SearxngUrl` to an existing SearXNG with the JSON API enabled.
  - `duckduckgo` — open source, **no key, no infra** (scrapes DDG; light use only).
  - `tavily` ([Tavily](https://tavily.com), default) or `brave` ([Brave Search API](https://brave.com/search/api/)) — commercial, need `WebSearchApiKey`.
  - `none` — disable `web_search`.
- AWS CLI configured; permission to create IAM roles (`--capabilities CAPABILITY_IAM`).
- A way for the instance to get the server code:
  - **Private repo (recommended): stage the two files in S3** (see [Stage the code](#stage-the-code-s3)) —
    the instance pulls them via its IAM role, no git credentials needed.
  - Public repo: leave `CodeS3Bucket` empty and it `git clone`s `RepoUrl`@`RepoBranch` instead.
- The chosen subnet must have **outbound internet** (an IGW for public subnets, or a NAT gateway
  for private ones) so the instance can install packages and clone the repo at boot.

## Stage the code (S3)

For a **private repo**, upload the two server files to an S3 bucket in your region; the instance
pulls them via its IAM role (the template grants `s3:GetObject` on just that prefix):

```bash
BUCKET=<your-code-bucket>        # an S3 bucket in your region (create one if needed)
aws s3 mb s3://$BUCKET --region ap-southeast-1        # skip if it already exists
aws s3 cp mcp/server/mcp_server.py    s3://$BUCKET/mcp-server/mcp_server.py
aws s3 cp mcp/server/requirements.txt s3://$BUCKET/mcp-server/requirements.txt
```

Then pass `CodeS3Bucket=$BUCKET` in the deploy. (Skip this section for a public repo — the
instance clones `RepoUrl` instead.)

## Deploy

### Quick deploy (env file + KB auto-discovery) — recommended

Copy the example env, edit it, and run the wrapper. It **auto-discovers your Bedrock KB id** (by
name, in `BedrockRegion`) so you don't have to paste it, then runs the CloudFormation deploy:

```bash
cp mcp/mcp.env.example mcp/mcp.env      # usually only BedrockRegion + CodeS3Bucket need editing
bash mcp/deploy-mcp.sh                  # auto-resolves VPC/IGW/subnet + KB id, then deploys
bash mcp/deploy-mcp.sh --dry-run        # print the resolved deploy command first
bash mcp/deploy-mcp.sh --no-discover-kb # use BedrockKnowledgeBaseId from the env as-is
```

The wrapper fills in as much as it can from your account, so most of the env can stay blank:

| Value | Auto-resolved from |
|---|---|
| `BedrockKnowledgeBaseId` | KB named `KB_NAME` (default `splunk-ai-kb`) in `BedrockRegion`, or the only KB there |
| `ExistingVpcId` | `PLATFORM_NET_STACK` output `VpcId`, else a VPC tagged `Name=splunk-ai-vpc` |
| `ExistingIgwId` | the internet gateway attached to that VPC |
| `SplunkCidr` | the VPC CIDR (whole VPC may reach the port) |
| `SubnetCidr` | the highest free `/24` in the VPC (non-overlapping) |

Set any of them explicitly in the env to override. The raw `aws cloudformation deploy` commands
below are the manual equivalent.

### A) Into your existing Splunk VPC (so Splunk can reach it directly)

The MCP server **always gets its own new subnet** (it never shares an existing one). For an
existing VPC, set `ExistingVpcId`, its `ExistingIgwId` (so the new subnet can route out), a free
`SubnetCidr`, and `SplunkCidr`:

```bash
aws cloudformation deploy \
  --template-file mcp/cloudformation/mcp-server.yaml \
  --stack-name mcp-server \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    ExistingVpcId=vpc-0abc123 \
    ExistingIgwId=igw-0abc123 \
    SubnetCidr=10.0.250.0/24 \
    SplunkCidr=10.0.5.0/24 \
    BedrockKnowledgeBaseId=ABCDEF1234 \
    WebSearchProvider=tavily \
    WebSearchApiKey=tvly-xxxxxxxx
```

### B) Create a new VPC, exposed to the internet

Leave `ExistingVpcId` empty (a VPC + public subnet + IGW are created) and turn on internet
access (opens the port to `0.0.0.0/0` and attaches an Elastic IP):

```bash
aws cloudformation deploy \
  --template-file mcp/cloudformation/mcp-server.yaml \
  --stack-name mcp-server \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    AllowInternetAccess=true \
    BedrockKnowledgeBaseId=ABCDEF1234 \
    WebSearchProvider=tavily \
    WebSearchApiKey=tvly-xxxxxxxx
```

Add `AllowInternetAccess=true` to also open the port to the internet and attach an Elastic IP.
(The new subnet is always created as a public subnet routed to the IGW, so the instance has
egress for bootstrap either way; actual inbound is governed entirely by the security group.)

### Open-source web search (no API key)

Swap the `WebSearch*` overrides for a keyless backend:

```bash
# SearXNG on the SAME instance (bootstrap installs it via Docker on localhost) — leave SearxngUrl empty
    WebSearchProvider=searxng
# or point at an existing SearXNG
    WebSearchProvider=searxng SearxngUrl=https://searxng.internal:8888
# or DuckDuckGo (no infra, light use only)
    WebSearchProvider=duckduckgo
```

Running SearXNG on the same box adds a Docker container — use `InstanceType=t3.medium` (or larger)
rather than the `t3.small` default.

## Cost (POC)

Built to stay cheap:

- **Bedrock KB → Amazon S3 Vectors**: serverless, pay-per-use, **no hourly/standing charge**. For
  ~20 small docs, storage + queries are effectively pennies/month. (OpenSearch Serverless, the
  alternative, has a ~US$350/mo idle-OCU floor — deliberately avoided.)
- **Embedding/retrieval**: pay per token at ingest (one-time, tiny) and per query. Negligible at POC volume.
- **KB logs**: `setup-bedrock-kb.sh` caps CloudWatch retention (14 days, `KB_LOG_RETENTION_DAYS`).
- **MCP instance**: the only real line item — `t3.small` ≈ **US$15/mo** on-demand. Stop it when idle:
  ```bash
  aws ec2 stop-instances --instance-ids <McpInstanceId>   # start-instances to resume
  ```
  Or delete the whole stack (`aws cloudformation delete-stack --stack-name mcp-server`) — the KB,
  its S3 Vectors store, and the docs are independent and stay put.

## After deploy

Read the stack outputs — endpoint + how to fetch the token:

```bash
aws cloudformation describe-stacks --stack-name mcp-server \
  --query 'Stacks[0].Outputs' --output table

# fetch the bearer token
aws secretsmanager get-secret-value \
  --secret-id mcp-server-mcp-auth-token \
  --query SecretString --output text
```

`McpEndpoint` looks like `https://<ip>:8000/mcp` (self-signed TLS) or `http://…` (`TlsMode=none`).

### Point a client at it

Any MCP client using the Streamable HTTP transport, sending the token:

```
URL:     https://<ip>:8000/mcp
Header:  Authorization: Bearer <token from Secrets Manager>
```

Quick check with curl (initialize handshake):

```bash
TOKEN=$(aws secretsmanager get-secret-value --secret-id mcp-server-mcp-auth-token --query SecretString --output text)
curl -sk https://<ip>:8000/mcp \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"1"}}}'
# health (no auth): curl -sk https://<ip>:8000/health
```

## Reachability

- **From the Splunk subnet:** set `SplunkCidr` — the security group allows that CIDR to the MCP
  port. Deploying into the **same VPC** as Splunk (scenario A) means normal intra-VPC routing;
  no peering needed. If Splunk is in a **different VPC**, either enable internet access or set up
  VPC peering / Transit Gateway (out of scope here) and add that CIDR as `SplunkCidr`.
- **From the internet:** `AllowInternetAccess=true` opens the port to `0.0.0.0/0` and attaches an
  Elastic IP. The bearer token is the only thing gating access, so keep TLS on.

## Parameters

| Parameter | Default | Notes |
|---|---|---|
| `ExistingVpcId` | *(empty)* | Empty → create a VPC. Set → deploy into it (needs `ExistingIgwId`). A new subnet is always created either way. |
| `ExistingIgwId` | *(empty)* | The existing VPC's Internet Gateway id. **Required** when `ExistingVpcId` is set — the new subnet routes out through it. |
| `VpcCidr` | `10.20.0.0/16` | CIDR for the new VPC (only when creating one). |
| `SubnetCidr` | `10.20.1.0/24` | CIDR for the **new subnet** (always created). Must be a free range in the VPC. |
| `SplunkCidr` | *(empty)* | Splunk subnet CIDR allowed inbound. |
| `AllowInternetAccess` | `false` | `true` → open to `0.0.0.0/0` + Elastic IP. |
| `McpPort` | `8000` | MCP listen port. |
| `BedrockKnowledgeBaseId` | *(empty)* | KB the retrieve tool queries. |
| `BedrockRegion` | *(stack region)* | Region of the KB. |
| `WebSearchProvider` | `tavily` | `searxng` \| `duckduckgo` \| `tavily` \| `brave` \| `none`. |
| `WebSearchApiKey` | *(empty)* | Key for `tavily`/`brave` (Secrets Manager). Not needed for `searxng`/`duckduckgo`. |
| `SearxngUrl` | *(empty)* | For `searxng`: empty → install SearXNG on this instance; or a URL to an existing SearXNG. |
| `TlsMode` | `self-signed` | `self-signed` (HTTPS) or `none` (plain HTTP). |
| `InstanceType` | `t3.small` | |
| `KeyName` | *(empty)* | Optional SSH key; otherwise use SSM Session Manager. |
| `CodeS3Bucket` | *(empty)* | S3 bucket with the server code (private-repo path). Empty → git clone `RepoUrl`. |
| `CodeS3Prefix` | `mcp-server` | Key prefix under the bucket for `mcp_server.py` + `requirements.txt`. |
| `RepoUrl` / `RepoBranch` | this repo / `main` | Public git source, used only when `CodeS3Bucket` is empty. |

## Security notes

- The bearer token is auto-generated (48 chars, Secrets Manager). To rotate it, update the
  secret's value and restart the service (`systemctl restart mcp-server`).
- `TlsMode=self-signed` gives HTTPS with an auto-generated cert — clients must **skip cert
  verification** (`curl -k`). For production, front the instance with an **ALB + ACM certificate**
  (real hostname) or a reverse proxy terminating TLS, and set `TlsMode=none` behind it.
- Prefer scenario A (private, `SplunkCidr` only) over internet exposure when you can.
- The instance role grants only `bedrock:Retrieve`/`RetrieveAndGenerate` on knowledge bases and
  `GetSecretValue` on its own secrets — no broad permissions.

## Local development

```bash
cd mcp/server
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
AUTH_TOKEN=dev-token BEDROCK_KB_ID=ABCDEF1234 \
  SEARCH_PROVIDER=tavily SEARCH_API_KEY=tvly-xxxx \
  python mcp_server.py            # serves http://0.0.0.0:8000/mcp
```

Connecting to it needs AWS credentials with the same Bedrock/Secrets permissions as the
instance role.
