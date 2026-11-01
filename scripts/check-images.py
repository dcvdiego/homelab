#!/usr/bin/env python3
"""Image version policy check (CI, and before opening a PR). Rules: docs/image-versions.md.

For every image in a compose file or Dockerfile that Renovate watches (renovate.json ignorePaths
excluded) it checks:
  1. pinned as tag@sha256:<digest>, no ${VARS} (Renovate can't read them);
  2. an exact version tag, not latest/stable/main/a bare major (companions that copy their app's
     upstream compose verbatim are exempt: scripts/image-policy.json "upstream_compose");
  3. a row in docs/image-versions.md, i.e. someone read that project's docs;
  4. named in a renovate.json packageRule, i.e. it has an update rule;
  5. with --base <ref>: images under "sequential" in scripts/image-policy.json move at most one
     release line per PR (authentik, Nextcloud, MongoDB docs forbid skipping).
Exit 1 on any failure; prints GitHub annotations.
"""
import argparse
import fnmatch
import json
import pathlib
import re
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from imagelib import norm_repo, parse_ref, services, tags_of  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
ROLLING = {"latest", "stable", "main", "master", "release", "develop", "dev", "nightly", "edge", "beta", "next", "testing"}
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")

ap = argparse.ArgumentParser()
ap.add_argument("--base", help="git ref to compare against for the sequential-release rule, e.g. origin/main")
args = ap.parse_args()

renovate = json.loads((ROOT / "renovate.json").read_text())
policy = json.loads((ROOT / "scripts/image-policy.json").read_text())
docs = (ROOT / "docs/image-versions.md").read_text()
documented = {norm_repo(m) for m in re.findall(r"^\|\s*`([^`]+)`", docs, re.M)}
ignored = renovate.get("ignorePaths", [])
companions = {(stack, svc) for stack, cfg in policy["upstream_compose"].items() if not stack.startswith("_")
              for svc in cfg["companions"]}
errors = []


def fail(path, line, msg):
    errors.append(f"::error file={path},line={line}::{msg}")


def rule_names(rule):
    return rule.get("matchPackageNames", [])


def matches(name, pattern):
    if pattern.startswith("/") and pattern.endswith("/"):
        return re.search(pattern[1:-1], name) is not None
    return fnmatch.fnmatchcase(name, pattern)


def has_rule(name):
    return any(matches(name, p) for r in renovate.get("packageRules", []) for p in rule_names(r))


def watched(rel):
    return not any(fnmatch.fnmatch(rel, g) for g in ignored)


def images(rev=None):
    """{(file, service or 'FROM'): (line, ref)} for watched files, from the work tree or a git ref."""
    out = {}
    if rev:
        files = subprocess.run(["git", "-C", str(ROOT), "ls-tree", "-r", "--name-only", rev, "docker-compose"],
                               capture_output=True, text=True, check=True).stdout.split()
        read = lambda f: subprocess.run(["git", "-C", str(ROOT), "show", f"{rev}:{f}"],  # noqa: E731
                                        capture_output=True, text=True).stdout
    else:
        files = [str(p.relative_to(ROOT)) for p in (ROOT / "docker-compose").rglob("*") if p.is_file()]
        read = lambda f: (ROOT / f).read_text()  # noqa: E731
    for rel in sorted(files):
        if not watched(rel):
            continue
        name = rel.rsplit("/", 1)[-1]
        if re.fullmatch(r"(docker-)?compose[^/]*\.ya?ml", name):
            for svc, n, ref in services(read(rel)):
                out[(rel, svc)] = (n, ref)
        elif name == "Dockerfile" or name.startswith("Dockerfile."):
            for n, line in enumerate(read(rel).split("\n"), 1):
                m = re.match(r"^\s*FROM\s+(?:--\S+\s+)*(\S+)", line, re.I)
                if m and m.group(1) != "scratch":
                    out[(rel, f"FROM:{n}")] = (n, m.group(1))
    return out


current = images()
for (rel, svc), (n, ref) in current.items():
    stack = rel.split("/")[1]
    if "${" in ref:
        fail(rel, n, f"{svc}: image uses a variable ({ref}); write the image literally so Renovate can update it")
        continue
    repo, tag, digest = parse_ref(ref)
    if not tag or not digest or not DIGEST.match(digest):
        fail(rel, n, f"{svc}: pin as {repo}:<version>@sha256:<digest> (got {ref})")
    is_companion = (stack, svc) in companions
    if tag and not is_companion and (tag.lower() in ROLLING or re.fullmatch(r"v?\d+(-[a-z0-9]+)?", tag)):
        fail(rel, n, f"{svc}: '{tag}' is a moving tag; pin the exact version the project releases")
    if norm_repo(repo) not in documented:
        fail(rel, n, f"{svc}: {repo} has no row in docs/image-versions.md: read the project's install/upgrade "
                     f"docs and add its rule (AGENTS.md, 'Adding or updating a stack')")
    if not has_rule(repo):
        fail(rel, n, f"{svc}: {repo} isn't named in any renovate.json packageRule; classify it (weekly batch "
                     f"or review) as docs/image-versions.md says")

if args.base:
    before = images(args.base)
    for key, (n, ref) in current.items():
        repo, tag, _ = parse_ref(ref)
        rule = policy["sequential"].get(norm_repo(repo)) or policy["sequential"].get(repo)
        if not rule or key not in before:
            continue
        old_tag = parse_ref(before[key][1])[1]
        if not old_tag or old_tag == tag:
            continue
        line = re.compile(rule["line"])
        old_m, new_m = line.match(old_tag), line.match(tag or "")
        if not new_m:
            fail(key[0], n, f"{repo}: {tag} doesn't look like a release ({rule['line']})")
            continue
        if not old_m:  # the base wasn't pinned to a release yet (e.g. a moving tag): nothing to compare
            print(f"::notice file={key[0]},line={n}::{repo}: {old_tag} -> {tag}, release-line check skipped")
            continue
        lines = sorted({m.group(1) for t in tags_of(repo) if (m := line.match(t))},
                       key=lambda s: [int(x) for x in s.split(".")])
        a, b = old_m.group(1), new_m.group(1)
        if a in lines and b in lines and lines.index(b) - lines.index(a) > 1:
            skipped = lines[lines.index(a) + 1:lines.index(b)]
            fail(key[0], n, f"{repo}: {old_tag} -> {tag} skips release line(s) {', '.join(skipped)}; its docs "
                            f"say upgrade through each one ({rule['docs']}). Change this PR to the newest "
                            f"{skipped[0]}.x first.")

print("\n".join(errors) if errors else f"image policy: {len(current)} images ok")
sys.exit(1 if errors else 0)
