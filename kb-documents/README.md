# kb-documents — Bedrock knowledge base source docs

20 **synthetic, fictional** incident postmortems (`INC-2026-0101` … `INC-2026-0120`) used as the
source corpus for the Bedrock Knowledge Base. Each has a consistent structure (summary, timeline,
root cause, resolution, impact, action items, tags) and is clearly marked as test data.

These `incident_id`s match the events produced by `scripts/datagen/` — so a log line in Splunk and
its postmortem in the KB share the same id, and the MCP server can pull one from the other.

## How they reach the KB

`scripts/datagen/setup-bedrock-kb.sh` **stages this directory to S3** (in the KB's region) and then
builds + ingests the knowledge base from that S3 prefix:

```bash
bash scripts/datagen/setup-bedrock-kb.sh --region us-east-1 \
  --data-s3-uri s3://<kb-region-bucket>/kb-documents/
# (defaults to staging ./kb-documents; use --stage-dir <dir> or --no-stage to change)
```
