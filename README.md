# Splunk AI Platform — two-instance, two-environment

A self-contained rebuild of the deployment that provisions **two EC2 instances per
environment** across **two environments that share one VPC**:

- **GPU host** (`g4dn.4xlarge`) — Splunk Enterprise + the full Dockerized AI stack
  (Ollama serving **Foundation-Sec-8B** and **llama3.1**, Milvus/MinIO/etcd, DSDL/MLTK
  containers).
- **Search head** (`t3.medium`) — Splunk Enterprise with apps + license, wired to drive
  the AI containers on the GPU host over the VPC (DSDL remote Docker, Ollama, Milvus).
  Runs on **Amazon Linux 2023** (a Splunk-supported OS, resolved per-region by
  `utils/get-al2023-ami-id.sh`) — not the GPU DLAMI, which the GPU host uses
  (`utils/get-dlami-ami-id.sh`). Override either with `SEARCH_HEAD_AMI_ID` / the 3rd
  `deploy.sh` arg.
- **`cloud`** environment — full internet egress.
- **`airgapped`** environment — same VPC, but **no internet egress**: every artifact comes
  from S3 and every image from ECR via VPC endpoints. It stays directly reachable on 22/8000
  for convenience (see *How the airgap works*).

This folder is independent of the original top-level `cloudformation/` + `scripts/` project,
which is left untouched.

## Architecture

```
                         one shared VPC (public subnet, IGW, VPC endpoints)
   ┌──────────────────────────────────────────────────────────────────────────┐
   │  VPC endpoints: S3(gw)  ecr.api  ecr.dkr  ssm  ssmmessages  ec2messages    │
   │                 secretsmanager  logs  sts                                  │
   │                                                                            │
   │   cloud environment                    airgapped environment              │
   │   ┌───────────────┐  ┌───────────┐     ┌───────────────┐  ┌───────────┐   │
   │   │ GPU g4dn.4xl  │←─│ SH t3.med │     │ GPU g4dn.4xl  │←─│ SH t3.med │   │
   │   │ Splunk+AI     │  │ Splunk    │     │ Splunk+AI     │  │ Splunk    │   │
   │   └───────────────┘  └───────────┘     └───────────────┘  └───────────┘   │
   │   SG egress: 0.0.0.0/0                  SG egress: VPC CIDR + S3 prefix    │
   └──────────────────────────────────────────────────────────────────────────┘
        shared: 2 S3 buckets (ai-artifacts, apps-license) + 1 ECR repo + IAM
```

- **Foundation** (deployed once, shared): `network.yaml`, `storage.yaml`, `iam.yaml`.
- **Per environment**: `main.yaml` nests `security.yaml`, `gpu-instance.yaml`,
  `search-head-instance.yaml`, `scheduler.yaml`.

### How the airgap works
The airgapped instances live in the same public subnet and keep an Elastic IP so you can
still reach SSH (22) and Splunk Web (8000). "Airgapped" is enforced at the **security-group
egress** level: their SG allows outbound traffic **only** to the VPC CIDR (interface
endpoints + the other instance) and the **S3 managed prefix list** (gateway endpoint).
All other outbound is denied, so the instances cannot reach the public internet — every
model, app, license, RPM, and container image is served from S3/ECR. Inbound SSH/UI still
works because security groups are stateful.

### Friday auto-stop
`scheduler.yaml` creates an EventBridge Scheduler rule per environment that stops both of
that environment's instances every **Friday 23:00 Asia/Singapore** (`cron(0 23 ? * FRI *)`).
There is no automatic restart — start them again with `aws ec2 start-instances` when needed.

### Secrets
Secrets never appear as CloudFormation parameters. `config/<env>.env` (git-ignored) holds
them locally; `deploy.sh` pushes them into Secrets Manager (`splunk-ai/<env>`). At boot,
`scripts/fetch-secrets.sh` reads the secret and materializes it into a root-only env file
that every bootstrap stage overlays.

## Prerequisites
- `aws` CLI **already authenticated** for the target account/region (SSO or `aws login`).
- `jq`, `python3`, Docker (local, to pull+push images to ECR), and `tar`.
- An EC2 key pair per environment (names set in `config/<env>.json` → `KeyName`).
- Your Enterprise license file(s) in the repo-root `licenses/` folder and Splunk app
  packages in the repo-root `apps/` folder (reused by `deploy.sh`).

## Deploy

```bash
cp config/cloud.env.example config/cloud.env
# edit cloud.env: ALLOWED_SSH_CIDR, ALLOWED_SPLUNK_UI_CIDR, SPLUNK_ADMIN_PASSWORD
./deploy.sh cloud ap-southeast-1
```

```bash
cp config/airgapped.env.example config/airgapped.env
# edit airgapped.env (same fields). For a real airgap, also set LLAMA_HF to a GGUF repo
# so llama3.1 is pre-staged into S3.
./deploy.sh airgapped ap-southeast-1
```

`deploy.sh` will: deploy the shared foundation (idempotent), stage artifacts to S3, seed
images into ECR (all images for `airgapped`, just the Splunk DSDL/MLTK images for `cloud`),
push secrets, then package and deploy the per-environment stack. It prints the stack outputs
(Splunk URLs, instance IDs, Elastic IPs) at the end.

### Useful `deploy.sh` toggles (set in `<env>.env` or the shell)
- `STAGE_ARTIFACTS=false` — skip all S3 staging on re-runs.
- `STAGE_APPS=false` — skip only the Splunk app upload (use when apps are already in the bucket).
- `SEED_ECR=false` — skip ECR seeding on re-runs.
- `LLAMA_HF=<hf-gguf-repo>` — GGUF source for llama3.1 staging (required for airgapped).
- `SPLUNK_PACKAGE_URL`, `VPC_CIDR`, `PUBLIC_SUBNET_CIDR`, `RESOURCE_NAME_PREFIX`.

### S3 bucket options (set in `<env>.env`)
The foundation needs two buckets (AI artifacts, apps+licenses). Pick one of:
```bash
# A) Reuse buckets you already have (exact names — nothing created, nothing renamed):
export AI_ARTIFACTS_BUCKET='my-existing-ai-bucket'
export APPS_LICENSE_BUCKET='my-existing-apps-bucket'

# B) Create buckets from YOUR base name; deploy appends '-<random5>' for global uniqueness
#    (e.g. my-team-ai -> my-team-ai-rg24g):
export AI_ARTIFACTS_BUCKET_BASE='my-team-ai'
export APPS_LICENSE_BUCKET_BASE='my-team-apps'

# C) Set none of the above -> deploy creates '<prefix>-ai-artifacts-<random5>' and
#    '<prefix>-apps-license-<random5>'.
```
Since your apps are already uploaded to the apps bucket, add `export STAGE_APPS=false`.

## Operating commands — set these once

After a deploy, export these once; every command block below reuses them.
```bash
export REGION=ap-southeast-1
export ENV=cloud                      # or: airgapped
export PREFIX=splunk-ai               # RESOURCE_NAME_PREFIX

# Foundation outputs (works whether buckets were created or reused):
sto() { aws cloudformation describe-stacks --region "$REGION" --stack-name "$PREFIX-foundation-storage" \
  --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
export APPS_BUCKET=$(sto AppsLicenseBucketName)
export AI_BUCKET=$(sto AiArtifactsBucketName)
export ECR_REGISTRY_URI=$(sto EcrRegistryUri)
export ECR_REPOSITORY_NAME=$(sto ContainerRepositoryName)

# Per-env instance endpoints:
env_out() { aws cloudformation describe-stacks --region "$REGION" --stack-name "$PREFIX-$ENV" \
  --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
export GPU_EIP=$(env_out GpuElasticIp)
export SH_EIP=$(env_out SearchHeadElasticIp)
export GPU_PRIVATE_IP=$(env_out GpuPrivateIp)

# Generated secrets (PROXY_API_KEY, SPLUNK_HEC_TOKEN, ...) from Secrets Manager:
eval "$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$PREFIX/$ENV" \
  --query SecretString --output text | jq -r 'to_entries[] | "export \(.key)=\(.value|@sh)"')"
```

# Platform components

Beyond the base two-instance deploy, the platform ships these components — each self-contained in
its own folder, with a deeper README alongside the code.

## MCP server — Bedrock KB + web search (`mcp/`)

A remote **MCP (Model Context Protocol) server** on EC2 that Splunk Enterprise (or any MCP client)
calls over the **Streamable HTTP** transport, guarded by an `Authorization: Bearer` token. It
exposes two tools:

| Tool | What it does |
|---|---|
| `bedrock_kb_retrieve(query, max_results)` | Retrieves passages from an **Amazon Bedrock Knowledge Base** |
| `web_search(query, max_results)` | Runs a **web search** — open-source SearXNG/DuckDuckGo, or commercial Tavily/Brave |

The [CloudFormation template](mcp/cloudformation/mcp-server.yaml) either **creates a VPC** or
deploys into an **existing one** (e.g. the Splunk VPC) — always in its **own new subnet** — and
optionally attaches an Elastic IP for internet reachability. The instance pulls the server code
(from **S3** for a private repo, or `git clone` for a public one) and runs
[`server/mcp_server.py`](mcp/server/mcp_server.py) as a `systemd` unit.
[`deploy-mcp.sh`](mcp/deploy-mcp.sh) auto-discovers your VPC/IGW, a free subnet CIDR, and your
Bedrock KB id, so a deploy is one command from an env file.

Full setup — staging the code to S3, choosing a web-search backend, the env-file deploy wrapper,
and wiring Splunk to the server — is in **[mcp/README.md](mcp/README.md)**.

## DSDL / MLTK app containers (`scripts/dsdl/`)

### Starting the DSDL containers (manual, by design)

Deployment does **not** pull or start the three DSDL/MLTK workload containers
(`gpu_container`, `llm_rag`, `cpu_container`) — auto-pulling those multi-GB images during
cloud-init caused Docker problems. Instead the GPU host only *configures* them
(`mltk-container/local/images.conf`, `containers.conf`) and sets up the ECR credential helper,
so you start the container you need, when you need it, from the DSDL UI (Configuration →
Containers) or a `... | fit MLTKContainer ... container_image="..."` search. Docker pulls the
image from ECR (airgapped) or Docker Hub/ECR (cloud) on first use.

This is controlled by the `AutoPullDsdlContainers` parameter (default `false` in both
`config/cloud.json` and `config/airgapped.json`). Set it to `true` only if you want the old
behavior of pulling those images during deployment.

### Default DSDL images in the airgapped environment
The airgapped instances cannot reach Docker Hub, so the **default Splunk DSDL images** must
be seeded into ECR and DSDL/AITK told to pull them from there. This follows the DSDL
[Container Customization](https://docs.splunk.com/Documentation/DSDL/5.2.2/User/ContainerCustomization)
guidance ("push to a local registry … update `images.conf` to point to your internal registry
references").

- **`scripts/dsdl/dsdl-default-images.json`** — the single source of truth: the 10 default images
  from `mltk-container/default/images.conf` (DSDL 5.2.4), each with its Docker Hub source and
  the tag it gets inside the shared ECR repo.
- **`scripts/dsdl/seed-default-dsdl-images.sh <region>`** — run on a connected operator machine
  (Docker + internet): pulls each default image from Docker Hub and pushes it to ECR.
  `deploy.sh airgapped …` runs this automatically.
- **`scripts/dsdl/generate_default_images_conf.py`** — runs on each instance during
  `09-configure-{gpu,searchhead}.sh` when `AIRGAPPED=true`: writes
  `mltk-container/local/images.conf` (which overrides `default/`) with every default stanza's
  `repo`/`image` repointed at ECR, keeping `title`/`runtime`. DSDL builds its pull reference as
  `repo` + `image`, so a stanza becomes e.g.
  `123….dkr.ecr.<region>.amazonaws.com/` + `<ecr-repo>:mltk-container-golden-gpu-5.2.4`.
  The running `__dev__` container in `containers.conf` already uses the ECR image URIs that
  `deploy.sh` computes, so both DSDL and the AI Toolkit start containers from ECR.

To use a different DSDL version, edit `dsdl-default-images.json` and pass `DSDL_VERSION` to
`deploy.sh`. To skip the arm64 image (it cannot run on the x86 instances) set `SKIP_ARM=true`.

## Demo data generation (`scripts/datagen/`)

Stands up demo/test data for the Splunk AI + RAG stack. The Splunk events and the Bedrock KB
documents share `incident_id` values (`INC-2026-0101`…`0120`), so an analyst can pivot from a log
line to its postmortem in the KB.

| Tool | Does | How it runs |
|---|---|---|
| `populate-splunk-data.sh` | **One-shot** backfill of N minutes of history into `app`/`infra`/`security`, in a container that exits when done. | bootstrap stage (default on) |
| `datagen-live.sh` | **Long-running** container emitting fresh data; sends to itself by default, can fan out to a list of nodes; pause/resume/stop. | **manual only** (never at boot) |
| `setup-bedrock-kb.sh` | Creates a Bedrock Knowledge Base (S3 Vectors) over an S3 doc prefix and runs ingestion. | operator-run |

Only **populate** runs at bootstrap — a stage on the search head and the GPU host, gated by the CFN
`SplunkDataTargets` param (**default `search-head,gpu`**); a node acts only if its role is in the
list. **`datagen-live.sh` is manual-only** and never auto-starts, so continuous data can't
accumulate unbounded. Flags (`--duration`, `--end-offset-min`, `--target`, `--pause`/`--resume`/
`--set-interval`/`--stop`), the shared engine, and the full architecture diagram are in
**[scripts/datagen/README.md](scripts/datagen/README.md)**. The 20 source case notes live in
[`kb-documents/`](kb-documents/).

## AI models & token metering (`scripts/token-meter/`)

Deployment brings up a small-but-capable **IBM Granite model on vLLM** (OpenAI-API-compatible)
on the GPU host and wires Splunk to call it, with accurate token metering available on demand.

**Model choice — ungated, no HF token, Cisco-Green.** The default is
`ibm-granite/granite-3.1-2b-instruct`: an ~2B instruct model in the same "small but decently
performant" niche as Gemma 2 2B, but **ungated and Apache-2.0**, so no Hugging Face token is
ever required. It is on Cisco's *Green* (low-risk) list in *Using Publicly Available AI Models
in Cisco Products and Operations* (as is Gemma — Gemma was only avoided here because its HF repo
is gated). To use a different model, set `VllmModel`/`VllmModelName` in the config JSON;
`HF_TOKEN` is only needed if you deliberately choose a gated repo.

What deployment sets up automatically:
- **vLLM** serving `ibm-granite/granite-3.1-2b-instruct` (served name `granite-3.1-2b-instruct`)
  on `:8001` (`scripts/12-vllm.sh`). Cloud pulls the model from Hugging Face (no token needed);
  airgapped loads it from S3 (`deploy.sh` pre-stages it) and the vLLM image from ECR.
- **`token_metrics` index + HEC** on **each** instance's Splunk, plus an **"AI Token Usage"**
  dashboard in the `token_metrics` app (`scripts/11-token-metrics.sh`). By default all usage is
  routed to the **search head's** index (see the [token-meter README](scripts/token-meter/README.md)).
- **`mltk-container/local/llm.conf`** on **both** instances registering the OpenAI provider
  (vLLM Granite) and the Ollama provider — by default pointed **directly** at the models so they
  work out of the box (`scripts/configure-splunk-llm.sh`).
- The **token-metering proxy image** is staged (pulled to the GPU host) but **not started**.

### Add the custom model in the AITK v6 UI (alternative to llm.conf)
Print the exact values to paste into the AI Toolkit "add custom model" form
(uses the vars from *Operating commands — set these once*):
```bash
echo "Endpoint       : http://$GPU_PRIVATE_IP:8100/v1   # proxy (metered); use :8001 to skip metering"
echo "Request Timeout: 200"
echo "API Key        : $PROXY_API_KEY"
echo "Model          : granite-3.1-2b-instruct"
```

### Token counting / metering

Every model call can be metered by a tiny reverse proxy that reads the backend's real `usage`
and ships one event per call to `index=token_metrics`. The proxy image is staged on the GPU host
but left **off** by default (`DeployVllm=true` deploys vLLM; set it `false` to skip). What it is,
how it works, the dispatch architecture (why every call is metered on the GPU host), and where
usage lands are in the folder's own docs:

- **[scripts/token-meter/README.md](scripts/token-meter/README.md)** — what the proxy does, the
  metric fields, configuration, and the destination knob.
- **[scripts/token-meter/TOKEN-METERING-INSTALL.md](scripts/token-meter/TOKEN-METERING-INSTALL.md)** —
  how to install/run it (systemd unit vs. Docker container), including on a Splunk + Ollama/vLLM
  stack **outside** this platform.

# Utilities & operations

## Local utilities (`utils/`)
Helper scripts you run from a connected operator machine (not on the instances):
- `get-dlami-ami-id.sh` / `get-al2023-ami-id.sh` — resolve the latest GPU DLAMI / Amazon Linux
  2023 AMI per region (used by `deploy.sh`).
- `push-docker-images-to-ecr.sh`, `build-and-push-dsdl-images-to-ecr.sh` — seed container images
  into the shared ECR repo.
- `upload-huggingface-ollama-model.sh`, `upload-huggingface-embedding-model.sh`,
  `upload-milvus-compose-artifacts.sh` — stage models/artifacts into S3 (airgapped prep).
- `validate-stack.sh`, `delete-stack.sh` — stack validation and teardown helpers.

## Upgrading the apps (AITK / DSDL / PSC)

`scripts/upgrade-apps.sh` does an in-place upgrade of the **AI Toolkit (AITK)**, **DSDL**, and
**Python for Scientific Computing (PSC)** apps, and reconciles the DSDL container images when a
DSDL upgrade changes their image URIs. Everything flows through **S3** (the same pathway used at
deploy time), so the airgapped environment upgrades the same way as the cloud one.

What the script does each run:
- Installs the newest matching package for each selected app (`splunk install app -update 1`).
- If DSDL was upgraded, reads the app's new `mltk-container/default/images.conf` to learn the
  image URIs it now expects (`scripts/dsdl/dsdl_images_conf_to_manifest.py`), **compares them to what
  the instance currently uses**, and for each changed URI: (GPU host) pulls the new image, pushes
  it to ECR, re-pulls it locally, removes stale containers so the new image is used, and rewrites
  `mltk-container/local/images.conf` to the new ECR references. The search head (no local dockerd)
  updates the image configuration only.
- Reloads/restarts Splunk.

Run it on the **GPU host first** (it performs the container re-pull), then on the **search head**.
Reach either instance over SSH or SSM Session Manager. Use `--apps` to select a subset and
`--dry-run` to preview without applying.

(Uses the vars from *Operating commands — set these once*.)

### Cloud environment
1. Upload the newer app package(s) to the apps bucket:
   ```bash
   aws s3 cp splunk-ai-toolkit_600.tgz "s3://$APPS_BUCKET/splunk-apps/"
   aws s3 cp splunk-app-for-data-science-and-deep-learning_524.spl "s3://$APPS_BUCKET/splunk-apps/"
   aws s3 cp python-for-scientific-computing-for-linux-64-bit_434.tgz "s3://$APPS_BUCKET/splunk-apps/"
   ```
2. On the GPU host, then the search head:
   ```bash
   sudo /opt/splunk-ai/scripts/upgrade-apps.sh --apps aitk,dsdl,psc
   ```
   New DSDL container images are pulled from Docker Hub, pushed to ECR, and re-pulled automatically.

### Airgapped environment
The instances can't reach Docker Hub, so pre-seed the new default images into ECR from a
connected operator machine **before** upgrading (same S3/ECR pathway as deploy):
1. Upload the newer app package(s) to the apps bucket (as in the cloud steps above).
2. Update `scripts/dsdl/dsdl-default-images.json` to the new DSDL version, then on a connected machine
   (`ECR_REGISTRY_URI`/`ECR_REPOSITORY_NAME` already exported above):
   ```bash
   ./scripts/dsdl/seed-default-dsdl-images.sh "$REGION"
   ```
3. On the GPU host, then the search head:
   ```bash
   sudo /opt/splunk-ai/scripts/upgrade-apps.sh --apps aitk,dsdl,psc
   ```
   With `AIRGAPPED=true` the script skips the Docker Hub pull, re-pulls the pre-seeded images from
   ECR, and rewrites `local/images.conf` accordingly.

> Tip: to refresh the on-instance copy of the scripts (e.g. after editing them), re-run
> `deploy.sh` for that environment, or `aws s3 cp` the updated `scripts/` tarball and
> re-extract under `/opt/splunk-ai`.

## Verify
- Splunk UI on `https://$GPU_EIP:8000` (GPU host) and `https://$SH_EIP:8000` (search head) from your allowed CIDR.
- On the GPU host: `curl http://localhost:11434/api/tags` lists **both** models; Milvus on
  `:19530`; `nvidia-smi` and `docker ps` healthy.
- On the search head: `/opt/splunk/etc/apps/dsdl/local/docker.conf` points at the GPU host's
  private IP; a DSDL run reaches the remote containers.
- Airgapped: from an instance, `aws s3 ls` / ECR pulls succeed while `curl https://example.com`
  **fails** (no internet egress). Use SSM Session Manager or SSH; read
  `/var/log/splunk-ai-bootstrap.log`.
- Scheduler: `aws scheduler get-schedule --name "$ENV-splunk-ai-friday-stop" --region "$REGION"`.

## Cleanup
(Uses `$REGION` / `$PREFIX` from *Operating commands — set these once*.)
```bash
aws cloudformation delete-stack --stack-name "$PREFIX-cloud"     --region "$REGION"
aws cloudformation delete-stack --stack-name "$PREFIX-airgapped" --region "$REGION"
# foundation (only after both envs are gone); buckets/ECR are RETAINED by policy:
aws cloudformation delete-stack --stack-name "$PREFIX-foundation-iam"     --region "$REGION"
aws cloudformation delete-stack --stack-name "$PREFIX-foundation-storage" --region "$REGION"
aws cloudformation delete-stack --stack-name "$PREFIX-foundation-network" --region "$REGION"
```
The two S3 buckets and the ECR repository use `DeletionPolicy: Retain` — empty and delete
them manually if you want them gone.

# Appendix

## What this folder deliberately omits
Relative to the original project, the token-counting stage (`11-*`), its webhook/example/docs,
the duplicate `outputs.yaml`, and the `AITK-*`/`TOKEN-COUNTING-*`/`DEPLOYMENT-CHECKLIST`
files are **not** carried over, to keep this a lean rebuild. They remain in the original tree.

## Airgap caveats
`dnf` works airgapped (Amazon Linux 2023 repos are S3-backed). The NVIDIA container-toolkit
repo and the manual Docker-Compose GitHub download are **not** reachable airgapped — the
NVIDIA DLAMI ships both, and the bootstrap scripts detect `AIRGAPPED=true` and refuse the
internet fallbacks with a clear message rather than hanging.
