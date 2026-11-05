#!/usr/bin/env python3
"""Keep a set of bot comments on an issue or PR in sync with files 1.md, 2.md, ... in a directory.

Used by .github/workflows/release-notes.yml for the output of scripts/release-notes.py. Each file
starts with a marker line `<!-- <prefix>:<n> -->`; the comment with the same marker is edited in
place, missing ones are created, and leftover ones (from a longer digest) are deleted. Only comments
by the token's own bot (github-actions[bot]) are touched.

  post-comments.py <issue or PR number> <dir> [--prefix release-notes-digest] [--skip-if "text"]

--skip-if: when the first file contains this text and no comment exists yet, post nothing (a PR
without version changes gets no comment). Needs GITHUB_TOKEN and GITHUB_REPOSITORY.

Bodies quote upstream release notes, so every body is defanged before posting: @mentions, issue/PR
references and issue/PR URLs outside code are wrapped in inline code. Otherwise GitHub notifies the
people credited in those notes and adds "mentioned this" links to the upstream issues.
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


CODE = re.compile(r"(```.*?```|`[^`\n]*`)", re.S)
GH_ISSUE_URL = r"https?://github\.com/[\w.-]+/[\w.-]+/(?:issues|pull|discussions)/\d+[^\s)\]>]*"
PING = re.compile(
    rf"\[([^\]\n]*)\]\(({GH_ISSUE_URL})\)"                  # [text](issue url)
    rf"|<?({GH_ISSUE_URL})>?"                                  # bare issue url
    r"|(?<![\w`/.@&-])([\w.-]+/[\w.-]+)?(#\d+)\b"             # owner/repo#N, #N
    r"|(?<![\w`/.@-])(@[A-Za-z0-9][A-Za-z0-9-]*(?:/[\w.-]+)?)"  # @user, @org/team
)


def defang_text(text):
    def sub(m):
        if m.group(1) is not None:
            ref = re.match(r"https?://github\.com/([\w.-]+/[\w.-]+)/\w+/(\d+)", m.group(2))
            short = f"{ref.group(1)}#{ref.group(2)}"
            text = defang_text(m.group(1))
            return f"`{short}`" if text.strip("`") in (f"#{ref.group(2)}", short) else f"{text} (`{short}`)"
        whole = m.group(3) or ((m.group(4) or "") + m.group(5) if m.group(5) else m.group(6))
        return f"`{whole}`"
    return PING.sub(sub, text)


def defang(body):
    """Wrap pings outside code in inline code; text already in code is left alone."""
    return "".join(part if i % 2 else defang_text(part) for i, part in enumerate(CODE.split(body)))


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
    bodies = {int(f.stem): defang(f.read_text()) for f in files}

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
