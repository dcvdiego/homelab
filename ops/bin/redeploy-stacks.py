#!/usr/bin/env python3
"""Redeploy the Komodo stacks whose files changed in this push.

A stack is redeployed when any changed file sits under its run_directory (docker-compose/<dir>/...).
Komodo pulls the repo and runs `docker compose up -d`. The runner's own stack (docker-compose/ops) is
skipped: redeploying it from this job would kill the job; deploy it from the Komodo UI instead.
Prints stack names and results only: the job log is public.
"""
import json
import os
import subprocess
import sys
import time
import urllib.request

before, sha = os.environ.get("BEFORE", ""), os.environ["GITHUB_SHA"]
if not before or set(before) == {"0"}:
    sys.exit(print("No previous commit to diff against; nothing to redeploy.") or 0)

changed = subprocess.run(["git", "diff", "--name-only", before, sha],
                         check=True, capture_output=True, text=True).stdout.split()
changed = [f for f in changed if f.startswith("docker-compose/")]
if not changed:
    sys.exit(print("No compose changes.") or 0)


def komodo(kind, typ, params):
    req = urllib.request.Request(
        f"{os.environ['KOMODO_URL']}/{kind}/{typ}", method="POST", data=json.dumps(params).encode(),
        headers={"Content-Type": "application/json", "x-api-key": os.environ["KOMODO_API_KEY"],
                 "x-api-secret": os.environ["KOMODO_API_SECRET"]})
    with urllib.request.urlopen(req, timeout=300) as r:
        return json.loads(r.read() or "null")


failed, covered = False, set()
for ks in komodo("read", "ListStacks", {"limit": 500}):
    run_dir = (komodo("read", "GetStack", {"stack": ks["name"]}).get("config") or {}).get("run_directory", "")
    hits = {f for f in changed if run_dir and f.startswith(run_dir.rstrip("/") + "/")}
    if not hits:
        continue
    covered |= hits
    if run_dir == "docker-compose/ops":
        print(f"::warning::{run_dir} changed: deploy the '{ks['name']}' stack from the Komodo UI")
        continue
    try:
        uid = komodo("execute", "DeployStack", {"stack": ks["name"]})["_id"]["$oid"]
        for _ in range(180):
            u = komodo("read", "GetUpdate", {"id": uid})
            if u.get("status") == "Complete":
                break
            time.sleep(5)
        print(f"komodo: deployed {ks['name']}: {'ok' if u.get('success') else 'FAILED'}")
        failed |= not u.get("success")
    except Exception as e:  # keep going so one bad stack doesn't block the rest
        failed = True
        print(f"::error::komodo {ks['name']}: deploy failed ({e.__class__.__name__})")

for d in sorted({os.path.dirname(f) for f in set(changed) - covered}):
    print(f"::warning::{d} changed but no Komodo stack deploys from it")
sys.exit(1 if failed else 0)
