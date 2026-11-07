#!/usr/bin/env python3
"""Print the commit this apply run should diff from: the head of the last apply run that really ran.

GitHub keeps at most one pending run per concurrency group: when several PRs are merged while a run
waits for approval, the waiting one is cancelled and the newest takes its place. Diffing only
github.event.before..sha would then drop the cancelled pushes' compose changes and requests
(2026-11-07: Traefik, Tandoor and cloudflared were never deployed). So diff from the head of the last
completed apply run on main that wasn't cancelled (success or failure; a failed one isn't retried,
same as before), as long as it's an ancestor of this commit. Falls back to $BEFORE.
The repo is public, so the runs list needs no token.
"""
import json
import os
import subprocess
import sys
import urllib.request

repo, sha, before = os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_SHA"], os.environ.get("BEFORE", "")
run_id = os.environ.get("GITHUB_RUN_ID", "")
base = before
try:
    url = (f"https://api.github.com/repos/{repo}/actions/workflows/apply.yml/runs"
           "?branch=main&event=push&status=completed&per_page=50")
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json",
                                               "User-Agent": "homelab-apply"})
    with urllib.request.urlopen(req, timeout=30) as r:
        runs = json.load(r)["workflow_runs"]
    for run in runs:  # newest first
        if str(run["id"]) == run_id or run["conclusion"] not in ("success", "failure"):
            continue
        head = run["head_sha"]
        if subprocess.run(["git", "merge-base", "--is-ancestor", head, sha]).returncode == 0:
            base = head
            break
except Exception as e:  # never block a deploy on this lookup
    print(f"apply-base: runs lookup failed ({e.__class__.__name__}); using the push's before", file=sys.stderr)
if base != before:
    print(f"apply-base: diffing from {base[:7]} (last applied run), not {before[:7]}", file=sys.stderr)
print(base)
