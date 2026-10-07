#!/usr/bin/env python3
"""Redeploy the stacks whose directory changed in this push: Komodo first, Portainer for the rest.

Komodo: any stack whose run_directory is a changed docker-compose/<dir> gets DeployStack (Komodo pulls
the repo, then `docker compose up -d`). Portainer (during the migration only): remaining git-backed
stacks, keeping their stored env (omitting it wipes the env, see AGENTS.md). A directory Komodo
handles is never sent to Portainer. Prints stack names and results only: the job log is public.
"""
import json
import os
import ssl
import subprocess
import sys
import time
import urllib.request

REPO = os.environ.get("GITHUB_REPOSITORY", "dcvdiego/homelab")
before, sha = os.environ.get("BEFORE", ""), os.environ["GITHUB_SHA"]
if not before or set(before) == {"0"}:
    sys.exit(print("No previous commit to diff against; nothing to redeploy.") or 0)

changed = subprocess.run(["git", "diff", "--name-only", before, sha],
                         check=True, capture_output=True, text=True).stdout.split()
changed_dirs = {os.path.dirname(f) for f in changed if f.startswith("docker-compose/")}
if not changed_dirs:
    sys.exit(print("No compose changes.") or 0)

ctx = ssl._create_unverified_context()  # Portainer's self-signed cert on the LAN


def api(method, path, body=None):
    req = urllib.request.Request(
        os.environ["PORTAINER_URL"] + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"x-api-key": os.environ["PORTAINER_TOKEN"], "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=300, context=ctx) as r:
        return json.loads(r.read() or "null")


failed, handled = False, set()


def komodo(kind, typ, params):
    req = urllib.request.Request(f"{os.environ['KOMODO_URL']}/{kind}/{typ}", method="POST",
        data=json.dumps(params).encode(), headers={"Content-Type": "application/json",
        "x-api-key": os.environ["KOMODO_API_KEY"], "x-api-secret": os.environ["KOMODO_API_SECRET"]})
    with urllib.request.urlopen(req, timeout=300) as r:
        return json.loads(r.read() or "null")


if os.environ.get("KOMODO_URL"):
    for ks in komodo("read", "ListStacks", {"limit": 500}):
        run_dir = (komodo("read", "GetStack", {"stack": ks["name"]}).get("config") or {}).get("run_directory", "")
        if run_dir not in changed_dirs:
            continue
        handled.add(run_dir)
        if run_dir == "docker-compose/ops":   # the runner itself: redeploying from this job would kill it
            print(f"::warning::{run_dir} changed: deploy the '{ks['name']}' stack from the Komodo UI")
            continue
        try:
            u = komodo("execute", "DeployStack", {"stack": ks["name"]})
            uid = u["_id"]["$oid"]
            for _ in range(180):
                u = komodo("read", "GetUpdate", {"id": uid})
                if u.get("status") == "Complete":
                    break
                time.sleep(5)
            print(f"komodo: deployed {ks['name']}: {'ok' if u.get('success') else 'FAILED'}")
            failed |= not u.get("success")
        except Exception as e:
            failed = True
            print(f"::error::komodo {ks['name']}: deploy failed ({e.__class__.__name__})")

for stack in api("GET", "/api/stacks"):
    git = stack.get("GitConfig") or {}
    if REPO.lower() not in (git.get("URL") or "").lower():
        continue
    stack_dir = os.path.dirname(git.get("ConfigFilePath") or "")
    hit = {d for d in changed_dirs - handled if d == stack_dir or d.startswith(stack_dir + "/")}
    if not hit:
        continue
    handled |= hit
    body = {"env": stack.get("Env") or [], "prune": False, "pullImage": True,
            "repositoryReferenceName": git.get("ReferenceName") or "refs/heads/main",
            "repositoryAuthentication": False}
    try:
        api("PUT", f"/api/stacks/{stack['Id']}/git/redeploy?endpointId={stack['EndpointId']}", body)
        print(f"redeployed {stack['Name']} (endpoint {stack['EndpointId']})")
    except Exception as e:  # keep going so one bad stack doesn't block the rest
        failed = True
        print(f"::error::{stack['Name']}: redeploy failed ({e.__class__.__name__} {getattr(e, 'code', '')})")

for d in sorted(changed_dirs - handled):
    print(f"::warning::{d} changed but no Komodo or git-backed Portainer stack uses it")
sys.exit(1 if failed else 0)
