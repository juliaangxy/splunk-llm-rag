#!/usr/bin/env python3
"""Create Splunk AITK agents + their reusable skills from the definitions in this directory.

Model (modular): reusable **skills** live as standalone files in `agents/skills/*.md`, each with a
`<!--skill name: … -->` block and a markdown body (the skill text). **Agents** live in `*-agent.md`
with a short `## System prompt` and an `<!--agent … skills: a, b, c  mcp_connections: … -->` block
that references skills by name. Many agents share the same skills (tools, data model, standards), so
the tool/data-model detail lives once in a skill instead of bloating every system prompt.

What this does:
  - SKILLS  -> created/updated in the KV Store (…/storage/collections/data/aitk_agent_skills).
  - PROMPTS -> exported as paste-ready .txt via --emit-prompts.
  - AGENTS  -> prints a copy-paste "Create Agent" recipe (system prompt + MCP connections + skills).

Why agents aren't created programmatically: a *provisioned* AITK agent is created through AITK's
cloud-side flow (Splunk Cloud "Agent Launchpad" -> an AWS Bedrock AgentCore runtime), not a plain
REST insert. A raw KV insert leaves it stuck in "Draft". So create each agent once in the UI using
the recipe this prints; the skills it creates plug straight in. Stdlib only; dry-run unless --apply.

Usage:
  python3 agents/apply-agents.py --list                                   # agents + their skills
  python3 agents/apply-agents.py --emit-prompts agents/prompts            # export system prompts
  python3 agents/apply-agents.py --splunk-url https://<gpu>:8089 -u admin -p '<pw>' --apply
  python3 agents/apply-agents.py --agents threatdetection --apply -u admin -p '<pw>'    # one agent's skills
"""
import argparse
import base64
import json
import os
import re
import ssl
import sys
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SKILLS_DIR = os.path.join(HERE, "skills")
SKILL_COLL = "aitk_agent_skills"


# ---------------------------------------------------------------------------- parsing
def extract_block(md, tag):
    """Parse an HTML-comment config block `<!--tag key: value ... -->` into a dict."""
    m = re.search(r"<!--%s\s*(.*?)-->" % re.escape(tag), md, re.S)
    cfg = {}
    if m:
        for line in m.group(1).splitlines():
            line = line.strip()
            if line and ":" in line:
                k, _, v = line.partition(":")
                cfg[k.strip()] = v.strip()
    return cfg


def _csv(s):
    return [x.strip() for x in (s or "").split(",") if x.strip()]


def extract_prompt(md):
    """The blockquoted text under `## System prompt`."""
    prompt, capturing, seen = [], False, False
    for ln in md.splitlines():
        if not capturing:
            if ln.strip().lower() == "## system prompt":
                capturing = True
            continue
        if ln.startswith(">"):
            seen = True
            s = ln[1:]
            prompt.append(s[1:] if s.startswith(" ") else s)
        elif not seen and ln.strip() == "":
            continue
        else:
            break
    return "\n".join(prompt).strip()


def load_skills():
    """Every reusable skill in agents/skills/*.md -> {name: {name, description, category, skill_text}}."""
    skills = {}
    if not os.path.isdir(SKILLS_DIR):
        return skills
    for fn in sorted(os.listdir(SKILLS_DIR)):
        if not fn.endswith(".md"):
            continue
        md = open(os.path.join(SKILLS_DIR, fn), encoding="utf-8").read()
        cfg = extract_block(md, "skill")
        if not cfg.get("name"):
            continue
        end = md.find("-->", md.find("<!--skill"))
        body = md[end + 3:].strip() if end != -1 else ""
        skills[cfg["name"]] = {"name": cfg["name"], "description": cfg.get("description", ""),
                               "category": cfg.get("category", ""), "skill_text": body, "_file": fn}
    return skills


def load_agents():
    agents = []
    for fn in sorted(os.listdir(HERE)):
        if not fn.endswith("-agent.md"):
            continue
        md = open(os.path.join(HERE, fn), encoding="utf-8").read()
        cfg = extract_block(md, "agent")
        if not cfg.get("name"):
            continue
        cfg["_file"] = fn
        cfg["_prompt"] = extract_prompt(md)
        cfg["_skills"] = _csv(cfg.get("skills"))
        cfg["_mcps"] = _csv(cfg.get("mcp_connections") or cfg.get("mcp_connection"))
        agents.append(cfg)
    return agents


# ---------------------------------------------------------------------------- REST
class Splunk:
    def __init__(self, url, app, user, password, token, insecure):
        self.ns = f"{url.rstrip('/')}/servicesNS/nobody/{app}"
        self.kv = f"{self.ns}/storage/collections/data"
        self.user, self.password, self.token = user, password, token
        self.ctx = ssl.create_default_context()
        if insecure:
            self.ctx.check_hostname = False
            self.ctx.verify_mode = ssl.CERT_NONE

    def _req(self, method, full_url, body=None):
        req = urllib.request.Request(full_url, method=method,
                                     data=json.dumps(body).encode() if body is not None else None)
        req.add_header("Content-Type", "application/json")
        if self.token:
            req.add_header("Authorization", f"Bearer {self.token}")
        else:
            cred = base64.b64encode(f"{self.user}:{self.password}".encode()).decode()
            req.add_header("Authorization", f"Basic {cred}")
        try:
            with urllib.request.urlopen(req, timeout=600, context=self.ctx) as r:
                raw = r.read().decode()
                return r.status, (json.loads(raw) if raw.strip() else None)
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode()[:400]

    def kv_key(self, coll, name):
        q = urllib.parse.quote(json.dumps({"name": name}))
        _, rows = self._req("GET", f"{self.kv}/{coll}?query={q}&output_mode=json")
        return rows[0]["_key"] if isinstance(rows, list) and rows else None

    def kv_upsert(self, coll, name, payload, overwrite):
        key = self.kv_key(coll, name)
        if key and not overwrite:
            return "exists (skipped)"
        if key:
            self._req("POST", f"{self.kv}/{coll}/{key}", payload)
            return "updated"
        self._req("POST", f"{self.kv}/{coll}", payload)
        return "created"


# ---------------------------------------------------------------------------- payloads
def skill_payload(sk):
    return {
        "name": sk["name"],
        "description": sk["description"],
        "category": sk.get("category", ""),
        "skill_text": sk["skill_text"],
        "acl": {"sharing": "owner", "app": "SPLUNK_ML_TOOLKIT", "owner": "admin",
                "perms": {"read": [], "write": []}},
    }


# ---------------------------------------------------------------------------- main
def main():
    p = argparse.ArgumentParser(description="Create AITK agents/skills from agents/*.md + agents/skills/*.md")
    p.add_argument("--agents", default="", help="comma list of agent names (default: all)")
    p.add_argument("--splunk-url", default=os.environ.get("SPLUNK_URL", "https://localhost:8089"))
    p.add_argument("--app", default="Splunk_ML_Toolkit")
    p.add_argument("-u", "--user", default=os.environ.get("SPLUNK_USER", "admin"))
    p.add_argument("-p", "--password", default=os.environ.get("SPLUNK_PASSWORD", ""))
    p.add_argument("--token", default=os.environ.get("SPLUNK_TOKEN", ""))
    p.add_argument("--apply", action="store_true", help="actually create the skills (default: dry-run)")
    p.add_argument("--overwrite", action="store_true", help="update an existing skill of the same name")
    p.add_argument("--verify-tls", action="store_true")
    p.add_argument("--emit-prompts", metavar="DIR", help="write paste-ready system-prompt .txt files and exit")
    p.add_argument("--list", action="store_true")
    a = p.parse_args()

    agents = load_agents()
    skills = load_skills()
    wanted = {n.strip() for n in a.agents.split(",") if n.strip()}
    if wanted:
        agents = [c for c in agents if c["name"] in wanted]
    if not agents:
        print("No matching agents found in", HERE, file=sys.stderr)
        sys.exit(1)

    # Skills referenced by the selected agents (create only what's needed; warn on unknown refs).
    referenced, unknown = [], []
    for c in agents:
        for s in c["_skills"]:
            if s in skills and s not in referenced:
                referenced.append(s)
            elif s not in skills and s not in unknown:
                unknown.append(s)

    if a.list:
        print(f"Skills in {os.path.relpath(SKILLS_DIR)}:")
        for name, sk in skills.items():
            print(f"  - {name:26} [{sk.get('category','')}]  {sk['description']}  ({sk['_file']})")
        print("\nAgents:")
        for c in agents:
            print(f"  - {c['name']:20} llm={c.get('llm_connection')}  mcps={','.join(c['_mcps']) or '-'}")
            print(f"      skills: {', '.join(c['_skills']) or '-'}")
        if unknown:
            print("\nWARNING: agents reference skills not found in skills/:", ", ".join(unknown), file=sys.stderr)
        return

    if a.emit_prompts:
        os.makedirs(a.emit_prompts, exist_ok=True)
        for c in agents:
            path = os.path.join(a.emit_prompts, c["name"] + ".txt")
            open(path, "w", encoding="utf-8").write(c["_prompt"] + "\n")
            print(f"wrote {path} ({len(c['_prompt'])} chars)")
        return

    if unknown:
        print("WARNING: agents reference skills not found in skills/:", ", ".join(unknown), file=sys.stderr)

    print(f"Target: {a.splunk_url}  app={a.app}  mode={'APPLY' if a.apply else 'dry-run'}")
    sp = None
    if a.apply:
        if not (a.token or a.password):
            print("ERROR: --apply needs --token or --password", file=sys.stderr)
            sys.exit(2)
        sp = Splunk(a.splunk_url, a.app, a.user, a.password, a.token, insecure=not a.verify_tls)

    # 1) create/update the referenced skills in KV
    print(f"\n== Skills ({len(referenced)} referenced) ==")
    for name in referenced:
        sk = skills[name]
        if not a.apply:
            print(f"  [dry-run] KV {SKILL_COLL}  {name}  ({len(sk['skill_text'])} chars)")
        else:
            try:
                print(f"  {name} -> {sp.kv_upsert(SKILL_COLL, name, skill_payload(sk), a.overwrite)}")
            except Exception as exc:  # noqa: BLE001
                print(f"  {name} -> ERROR {exc}", file=sys.stderr)

    # 2) print the per-agent Create-Agent recipe (the agent itself is created in the UI)
    for c in agents:
        print(f"\n=== Create in AITK UI (Apps -> AI Toolkit -> Agents -> Create): {c['name']} ===")
        print(f"  Name            : {c['name']}")
        print(f"  Description     : {c.get('description','')}")
        print(f"  System prompt   : paste agents/prompts/{c['name']}.txt  (--emit-prompts writes it)")
        print(f"  LLM connection  : {c.get('llm_connection')}")
        print(f"  MCP connections : {', '.join(c['_mcps']) or '-'}  (self_mcp = Splunk search; custom_mcp = KB + web)")
        print(f"  Skills          : {', '.join(c['_skills']) or '-'}  (created above)")
        print(f"  Settings        : response_variability {c.get('response_variability','0.7')}, "
              f"max_tokens {c.get('max_tokens','50000')}, "
              f"maximum_result_rows {c.get('maximum_result_rows','10')}, "
              f"reasoning_effort {c.get('reasoning_effort','NONE')}, "
              f"agent_timeout {c.get('agent_timeout','450')}")

    print("\nCreate the AGENTS in the UI with the recipe(s) above (that provisions the AgentCore runtime);")
    print("attach the listed MCP connections + skills. Skills are created programmatically above.")


if __name__ == "__main__":
    main()
