#!/usr/bin/env python3
"""Redeploy the Portainer git-backed stacks whose directory changed in this push.

Keeps each stack's stored env (omitting it wipes the env, see AGENTS.md). Prints stack names and
results only: the job log is public.
"""
import json
import os
import ssl
import subprocess
import sys
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
for stack in api("GET", "/api/stacks"):
    git = stack.get("GitConfig") or {}
    if REPO.lower() not in (git.get("URL") or "").lower():
        continue
    stack_dir = os.path.dirname(git.get("ConfigFilePath") or "")
    hit = {d for d in changed_dirs if d == stack_dir or d.startswith(stack_dir + "/")}
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
    print(f"::warning::{d} changed but no git-backed stack uses it; apply it with an ops request")
sys.exit(1 if failed else 0)
