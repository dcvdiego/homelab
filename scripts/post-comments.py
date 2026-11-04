#!/usr/bin/env python3
"""Keep a set of bot comments on an issue or PR in sync with files 1.md, 2.md, ... in a directory.

Used by .github/workflows/release-notes.yml for the output of scripts/release-notes.py. Each file
starts with a marker line `<!-- <prefix>:<n> -->`; the comment with the same marker is edited in
place, missing ones are created, and leftover ones (from a longer digest) are deleted. Only comments
by the token's own bot (github-actions[bot]) are touched.

  post-comments.py <issue or PR number> <dir> [--prefix release-notes-digest] [--skip-if "text"]

--skip-if: when the first file contains this text and no comment exists yet, post nothing (a PR
without version changes gets no comment). Needs GITHUB_TOKEN and GITHUB_REPOSITORY.
"""
import argparse
import json
import os
import pathlib
import re
import sys
import urllib.request

API = "https://api.github.com"
REPO = os.environ["GITHUB_REPOSITORY"]
TOKEN = os.environ["GITHUB_TOKEN"]
BOT = "github-actions[bot]"


def call(method, path, body=None):
    req = urllib.request.Request(f"{API}{path}", method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": f"Bearer {TOKEN}", "Accept": "application/vnd.github+json",
                                          "User-Agent": "homelab-post-comments",
                                          "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        data = r.read()
        return (json.loads(data) if data else None), r.headers.get("Link", "")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("number", type=int)
    ap.add_argument("dir")
    ap.add_argument("--prefix", default="release-notes-digest")
    ap.add_argument("--skip-if")
    args = ap.parse_args()

    marker = re.compile(rf"^<!-- {re.escape(args.prefix)}:(\d+) -->")
    files = sorted(pathlib.Path(args.dir).glob("*.md"), key=lambda p: int(p.stem))
    bodies = {int(f.stem): f.read_text() for f in files}

    existing, page = {}, f"/repos/{REPO}/issues/{args.number}/comments?per_page=100"
    while page:
        comments, link = call("GET", page)
        for c in comments:
            m = marker.match(c["body"] or "")
            if m and c["user"]["login"] == BOT:
                existing[int(m.group(1))] = c["id"]
        nxt = re.search(r'<https://api\.github\.com([^>]+)>;\s*rel="next"', link)
        page = nxt.group(1) if nxt else None

    if args.skip_if and not existing and args.skip_if in bodies.get(1, ""):
        print("nothing to post")
        return
    for n, body in sorted(bodies.items()):
        if n in existing:
            call("PATCH", f"/repos/{REPO}/issues/comments/{existing[n]}", {"body": body})
            print(f"updated comment {n}")
        else:
            call("POST", f"/repos/{REPO}/issues/{args.number}/comments", {"body": body})
            print(f"created comment {n}")
    for n, cid in sorted(existing.items()):
        if n not in bodies:
            call("DELETE", f"/repos/{REPO}/issues/comments/{cid}")
            print(f"deleted comment {n}")


if __name__ == "__main__":
    sys.exit(main())
