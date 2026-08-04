#!/usr/bin/env bash
set -euo pipefail

# Offline pre-deploy gate for this project. Runs everything that does NOT
# need AWS: shell syntax, Python compile, JSON validity, CloudFormation lint, and the
# cross-stack parameter checks. Safe to run anywhere (CI or laptop). Exits non-zero on
# any hard failure so it can gate a deploy.

PLATFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${PLATFORM_DIR}"
rc=0
note() { echo "[validate] $*"; }

note "1/6 shell syntax (bash -n)"
for f in deploy.sh validate.sh $(find scripts -name '*.sh'); do bash -n "$f" || { echo "FAIL bash -n $f"; rc=1; }; done

note "2/6 python compile"
for f in $(find scripts -name '*.py') token-meter-proxy/app.py; do python3 -m py_compile "$f" || { echo "FAIL py_compile $f"; rc=1; }; done

note "3/6 JSON validity"
for f in config/*.json scripts/dsdl/dsdl-default-images.json; do jq empty "$f" || { echo "FAIL jq $f"; rc=1; }; done

note "4/6 shellcheck (optional)"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning deploy.sh scripts/*.sh || { echo "shellcheck reported issues"; rc=1; }
else
  echo "shellcheck not installed; skipping (install for deeper shell checks)"
fi

note "5/6 cfn-lint (optional but recommended)"
if command -v cfn-lint >/dev/null 2>&1; then
  cfn-lint cloudformation/*.yaml || { echo "cfn-lint reported issues"; rc=1; }
else
  echo "cfn-lint not installed; skipping. Install: pip install cfn-lint"
fi

note "6/6 cross-stack parameter + deploy coverage checks"
python3 - <<'PY' || rc=1
import yaml, json, re, sys, glob
class L(yaml.SafeLoader): pass
def mk(l,s,n):
    if isinstance(n,yaml.ScalarNode): return l.construct_scalar(n)
    if isinstance(n,yaml.SequenceNode): return l.construct_sequence(n)
    return l.construct_mapping(n)
L.add_multi_constructor('!',mk)
def load(f): return yaml.load(open("cloudformation/"+f),Loader=L)
problems=0
for f in sorted(glob.glob("cloudformation/*.yaml")):
    d=yaml.load(open(f),Loader=L)
    if "Resources" not in d: print("no Resources:",f); problems+=1
main=load("main.yaml")
for lg,res in main["Resources"].items():
    props=res.get("Properties",{})
    if "TemplateURL" not in props: continue
    passed=set((props.get("Parameters") or {}).keys())
    ch=load(props["TemplateURL"]); cp=ch.get("Parameters",{})
    req={k for k,v in cp.items() if "Default" not in v}
    mr=req-passed; un=passed-set(cp)
    if mr: print(f"{lg}: MISSING required {sorted(mr)}"); problems+=1
    if un: print(f"{lg}: UNKNOWN params {sorted(un)}"); problems+=1
mp=main["Parameters"]; defined=set(mp); required={k for k,v in mp.items() if "Default" not in v}
jkeys={p["ParameterKey"] for p in json.load(open("config/cloud.json"))}
computed=set(json.loads(re.search(r"COMPUTED_KEYS='(\[.*?\])'", open('deploy.sh').read()).group(1)))
dep=open("deploy.sh").read()
# Scope to the MAIN stack deploy call so foundation-stack params aren't miscounted.
_marker='--stack-name "${MAIN_STACK}"'
dep_main=dep[dep.index(_marker):] if _marker in dep else dep
injected=set(re.findall(r'^\s{4}([A-Z][A-Za-z0-9]+)="',dep_main,re.M))
provided=(jkeys-computed)|injected
for label,val in [("MISSING required in deploy",required-provided),
                  ("UNKNOWN provided",provided-defined),
                  ("JSON key not in main",jkeys-defined)]:
    if val: print(label, sorted(val)); problems+=1
print("cross-checks problems:", problems)
sys.exit(1 if problems else 0)
PY

if [[ "${rc}" -eq 0 ]]; then note "OK — all offline checks passed"; else note "FAILED — see messages above"; fi
exit "${rc}"
