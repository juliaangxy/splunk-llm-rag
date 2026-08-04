# Demo data: Splunk incidents + Bedrock knowledge base

Tools that stand up demo/test data for the Splunk AI + RAG stack. All can **run at bootstrap or
manually**. The Splunk events and the KB documents share `incident_id` values
(`INC-2026-0101`…`0120`), so an analyst can pivot from a log line to its postmortem in the KB.

| Tool | Does | How it runs |
|---|---|---|
| [`populate-splunk-data.sh`](populate-splunk-data.sh) | **One-shot** backfill of N minutes of history into `app`/`infra`/`security`, in a container that exits when done. | bootstrap stage (default on) |
| [`datagen-live.sh`](datagen-live.sh) | **Long-running** container emitting fresh data; sends to itself by default, can fan out to a list of nodes; pause/resume/stop. | **manual only** (never at boot) |
| [`setup-bedrock-kb.sh`](setup-bedrock-kb.sh) | Creates a Bedrock Knowledge Base (S3 Vectors) over an S3 doc prefix and runs ingestion. | operator-run |
| [`incident_datagen.py`](incident_datagen.py) + [`Dockerfile`](Dockerfile) + [`lib.sh`](lib.sh) | Shared engine, image, and helpers. | — |

Only **populate** runs at bootstrap — a stage on the search head and the GPU host, gated by CFN
`SplunkDataTargets` (**default `search-head,gpu`**); a node acts only if its role (`SPLUNK_DATA_SELF`
= `search-head`/`gpu`) is in the list. **`datagen-live.sh` is manual-only** — it never auto-starts,
so continuous data can't accumulate unbounded. A manual run (any flag) always runs.

## Architecture

```
                 shared engine — scripts/datagen/
        incident_datagen.py + Dockerfile  (image: splunk-datagen)
        20 incident scenarios, INC-2026-0101 … INC-2026-0120
                 |                                   |
          backfill mode                         live mode
                 v                                   v
  +--------------------------+        +------------------------------+
  | populate-splunk-data.sh  |        | datagen-live.sh              |
  | one-shot container       |        | long-running container       |
  | - runs at BOOTSTRAP      |        | - MANUAL only ( --start )    |
  |   per SplunkDataTargets  |        | - sends to SELF by default   |
  | - clean -> backfill Nmin |        | - --target -> fan out to a   |
  |   -> EXIT (spins down)   |        |   list of Splunk nodes       |
  | - --duration/--end-offset|        | - pause/resume/set-interval  |
  +------------+-------------+        +------+----------------+-------+
               |  HEC :8088                  |                | fan-out
               v                             v                v
  ============ Splunk node VM (search head OR gpu host) ====   == other node ==
  ||  Splunk Enterprise                                   ||   || app / infra ||
  ||  indexes:  app    infra    security                  ||   ||  / security ||
  ||  every event carries  incident_id = INC-2026-01xx    ||   ===============
  =============================+===========================
                               |  correlated by incident_id
                               v
  +-------- Bedrock KB  (setup-bedrock-kb.sh, us-east-1) ---------+
  |  s3://.../kb-documents/  ->  KB  (Titan embeddings, S3 Vectors)|
  |  the SAME 20 incident case notes                              |
  +-------------------------------+------------------------------+
                                  |  bedrock_kb_retrieve
                                  v
  +-------------------------------+------------------------------+
  |  MCP server (mcp/)   tools: bedrock_kb_retrieve, web_search  |
  |  reached by Splunk SAIA / AITK over the VPC (bearer token)   |
  +-------------------------------------------------------------+
```

The two generators share one engine/image; **populate** runs once per node at boot and exits,
while **live** is started by hand and can fan the same stream out to several nodes. Splunk logs and
the Bedrock KB documents share `incident_id`, so the MCP server can pull a log's postmortem on demand.

---

## 1a. Populate by duration — `populate-splunk-data.sh`

Ensures the indexes + a scoped HEC token, then runs a **one-shot container that backfills the
window and exits** (spins down).

```bash
# 4 hours of history into the local Splunk (cleans first — see below)
sudo SPLUNK_ADMIN_PASSWORD='...' bash scripts/datagen/populate-splunk-data.sh --duration-min 240

# keep existing data, and back-date the window so it ends 24h ago
sudo SPLUNK_ADMIN_PASSWORD='...' bash scripts/datagen/populate-splunk-data.sh \
  --duration-min 240 --append --end-offset-min 1440
```
Flags: `--duration-min N` (1–1440), `--end-offset-min N` (back-date: window ends N min ago),
`--append` (keep existing data), `--clean` (default), `--splunk-host`, `--hec-port`, `--mgmt-port`,
`--hec-token`.

**Rerun behaviour:** by **default it CLEANS** the `app`/`infra`/`security` indexes first (delete +
recreate), so each run is a fresh, deterministic dataset with no duplicate incidents. Pass
`--append` to accumulate instead. (Cleaning wipes those demo-only indexes entirely — including any
live-generated data sitting in them.)

**At bootstrap** (default on): CFN `SplunkDataTargets` picks which nodes populate; `SplunkDataDurationMin`
sets the window. Each node populates **its own** Splunk (container runs inside that node's VM).

## 1b. Long-running live data — `datagen-live.sh`

A container that keeps emitting fresh baseline + rotating new-incident bursts. **Sends to itself by
default**; fan out the same data to more nodes with repeated `--target`.

```bash
# start on this node, sending to itself
sudo SPLUNK_ADMIN_PASSWORD='...' bash scripts/datagen/datagen-live.sh --start --interval-sec 30

# fan out: send the SAME data to this node AND another Splunk VM (needs that node's HEC token)
sudo SPLUNK_ADMIN_PASSWORD='...' bash scripts/datagen/datagen-live.sh --start \
  --target self --target 10.0.1.9:<hec-token>

# manage a RUNNING container (no restart, no creds):
sudo bash scripts/datagen/datagen-live.sh --status
sudo bash scripts/datagen/datagen-live.sh --pause
sudo bash scripts/datagen/datagen-live.sh --resume
sudo bash scripts/datagen/datagen-live.sh --set-interval 30
sudo bash scripts/datagen/datagen-live.sh --stop
```
`--pause`/`--resume`/`--set-interval` edit a runtime file (`/opt/splunk-ai/datagen.runtime`, mounted
read-only) that the container re-reads **every loop** — changes apply within one interval, no
`docker restart`. Pausing is the runtime equivalent of dropping that node from the live set.

**Not a bootstrap stage** — it never auto-starts, so continuous data can't grow unbounded. Run it
with `--start` when you want live data; fan-out is a manual operation.

**Verify in Splunk:**
```
index=app OR index=infra OR index=security earliest=-240m
index=* incident_id=INC-2026-0104        | pivot a log to its postmortem
```

---

## 2. Bedrock knowledge base — `setup-bedrock-kb.sh`

Provisions (idempotently): stages the repo's [`kb-documents/`](../../kb-documents) case notes into
the KB's docs bucket, then creates an **S3 Vectors** bucket + index, an IAM role, the **Bedrock KB**,
an **S3 data source**, and starts + waits on an **ingestion job**.

The version-controlled `kb-documents/` is the source of truth: `--stage-dir` (default) uploads it to
`--data-s3-uri` in the KB's region before ingestion (`--no-stage` to skip, `--source-s3-uri` to copy
from another S3 prefix instead).

> **Run it with admin credentials** (like the S3 upload step). It needs `iam:CreateRole`/`PutRolePolicy`,
> `s3vectors:*`, `bedrock:*`, and `s3:Get/List` on the doc bucket — broader than an instance role
> normally has. Preview first with `--dry-run`.

**Manual:**
```bash
bash scripts/datagen/setup-bedrock-kb.sh --region us-east-1 \
  --data-s3-uri s3://<kb-region-docs-bucket>/kb-documents/ \
  --source-s3-uri s3://ai-splunk-ai-bucket/kb-documents/
```
The script ensures the docs bucket exists **in the KB's region**, syncs `--source-s3-uri` into it,
then refuses to ingest 0 documents (a missing/empty bucket previously produced an empty KB with no
error). It also sets up CloudWatch log delivery for the KB automatically.

> **Region + model gotcha:** the embedding model must exist in the KB's region *and* be allowed by
> any org SCP. If an SCP blocks Cohere but allows Titan, use a Titan region (e.g. `us-east-1`) —
> Titan isn't offered in `ap-southeast-1`. Because Bedrock reads docs from a bucket in the KB's own
> region, `--source-s3-uri` copies them across for you. View ingestion logs with
> `aws logs tail /aws/vendedlogs/bedrock/knowledge-base/<kb-name> --region <kb-region> --since 1h`.

**Bring your own config** — any flag, or a sourced env file:
```bash
bash scripts/datagen/setup-bedrock-kb.sh --config my-kb.env
# or individual overrides:
bash scripts/datagen/setup-bedrock-kb.sh \
  --kb-name my-kb --data-s3-uri s3://my-bucket/docs/ \
  --embed-model amazon.titan-embed-text-v2:0 --embed-dim 1024 \
  --vector-bucket my-vectors --vector-index my-index \
  --kb-role-arn arn:aws:iam::123456789012:role/my-existing-kb-role   # skip role creation
```
`my-kb.env` is just shell assignments, e.g. `KB_NAME=my-kb`, `DATA_S3_URI=s3://…`, `EMBED_DIM=512`.

On success it prints the KB id to feed the MCP deploy:
```
BedrockKnowledgeBaseId=<kb-id>
```

**At bootstrap:** the script is toggle-aware (`CREATE_BEDROCK_KB=true`) but is **not** in the
default stage list, because the search-head instance role lacks the IAM/S3-Vectors/Bedrock
permissions above. To run it at bootstrap anyway, grant those permissions to the instance role
and add `"datagen/setup-bedrock-kb.sh"` to the `stages` array in `bootstrap-searchhead.sh`.

---

## End-to-end demo

```bash
# 1) synthetic case notes already in s3://ai-splunk-ai-bucket/kb-documents/ (see repo history)
# 2) build the KB over them
bash scripts/datagen/setup-bedrock-kb.sh --region ap-southeast-1        # -> prints BedrockKnowledgeBaseId

# 3) populate Splunk with matching incident logs
sudo SPLUNK_ADMIN_PASSWORD='...' bash scripts/datagen/populate-splunk-data.sh --duration-min 240

# 4) deploy the MCP server with that KB id (see ../../mcp/README.md)
```
