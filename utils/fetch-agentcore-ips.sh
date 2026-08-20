#!/usr/bin/env bash
set -euo pipefail

# Fetch the Splunk AI Toolkit **Agent Launchpad** region -> egress-IP mapping from the docs and write
# it to utils/agentcore-region-ips.tsv — the single source of truth that mcp/deploy-mcp.sh and
# utils/whitelist-agentcore-ips.sh read. Run this whenever Splunk updates the published IPs.
#
# Best-effort scraper: if the page can't be fetched or parsing yields too few rows (e.g. the page
# changed, or it's JS-rendered and curl only gets a shell), it KEEPS the existing file and warns —
# a bad parse never wipes a known-good mapping. Review the diff it prints before committing.
#
# Usage:
#   ./utils/fetch-agentcore-ips.sh            # scrape + update the tsv (if the parse looks sane)
#   ./utils/fetch-agentcore-ips.sh --print    # just print what was scraped; don't write the file
#   DOC_URL=<url> ./utils/fetch-agentcore-ips.sh   # override the docs URL

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${DIR}/agentcore-region-ips.tsv"
DOC_URL="${DOC_URL:-https://help.splunk.com/en/splunk-cloud-platform/apply-machine-learning/use-ai-toolkit/6.0.0/ai-toolkit-connections-containers-and-agents/ai-toolkit-agent-launchpad}"
MIN_ROWS="${MIN_ROWS:-8}"       # a sane parse must find at least this many region rows
PRINT_ONLY=false
[[ "${1:-}" == "--print" ]] && PRINT_ONLY=true

command -v curl >/dev/null 2>&1 || { echo "ERROR: curl required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 required" >&2; exit 1; }

echo "Fetching ${DOC_URL}" >&2
html="$(curl -fsSL --max-time 30 -A 'Mozilla/5.0 (agentcore-ip-fetch)' "${DOC_URL}" 2>/dev/null || true)"
if [[ -z "${html}" ]]; then
  echo "WARN: could not fetch the docs page — keeping existing ${OUT##*/}" >&2
  exit 2
fi

# Parse region-code -> IPv4 pairs from the (tag-stripped) HTML. Regions may be capitalised in the
# doc (e.g. "US-east-1"); normalise to lowercase. An IP must follow the region within a short,
# digit-free gap so we don't pair a region with the wrong row's address.
parsed="$(printf '%s' "${html}" | python3 -c '
import sys, re
text = re.sub(r"<[^>]+>", " ", sys.stdin.read())
text = text.replace("&nbsp;", " ")
seen = {}
for m in re.finditer(r"([A-Za-z]{2}-[A-Za-z]+-\d+)\b[^0-9]{0,80}?((?:\d{1,3}\.){3}\d{1,3})", text):
    seen.setdefault(m.group(1).lower(), m.group(2))
for r in sorted(seen):
    print(f"{r}\t{seen[r]}")
')"

rows="$(printf '%s\n' "${parsed}" | grep -c . || true)"
if [[ "${rows}" -lt "${MIN_ROWS}" ]]; then
  echo "WARN: parsed only ${rows} region row(s) (< ${MIN_ROWS}) — the page may have changed or be" >&2
  echo "      JS-rendered. Keeping existing ${OUT##*/}. Parsed content was:" >&2
  printf '%s\n' "${parsed}" | sed 's/^/    /' >&2
  exit 2
fi

NEW="$(
  printf '%s\n' \
    "# Splunk AI Toolkit Agent Launchpad egress IPs, one /32 per supported AWS region." \
    "# This is the single source of truth read by mcp/deploy-mcp.sh and utils/whitelist-agentcore-ips.sh." \
    "# Regenerate from the docs with: utils/fetch-agentcore-ips.sh" \
    "# Source: ${DOC_URL}" \
    "# Columns: <aws-region><TAB><ip>"
  printf '%s\n' "${parsed}"
)"

if ${PRINT_ONLY}; then
  printf '%s\n' "${NEW}"
  exit 0
fi

if [[ -f "${OUT}" ]] && diff -q <(grep -v '^#' "${OUT}" | sort) <(printf '%s\n' "${parsed}" | sort) >/dev/null 2>&1; then
  echo "No change: ${OUT##*/} already matches the docs (${rows} regions)." >&2
  exit 0
fi

if [[ -f "${OUT}" ]]; then
  echo "== changes vs current ${OUT##*/} ==" >&2
  diff <(grep -v '^#' "${OUT}" | sort) <(printf '%s\n' "${parsed}" | sort) >&2 || true
fi
printf '%s\n' "${NEW}" > "${OUT}"
echo "Wrote ${OUT} (${rows} regions)." >&2
