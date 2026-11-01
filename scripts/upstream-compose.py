#!/usr/bin/env python3
"""Keep companion images (database, cache, queue) in line with each project's own compose file.

Immich, authentik and Zulip publish a compose file per release and their docs say to use the images
in it. For every stack under "upstream_compose" in scripts/image-policy.json this reads the app
version we pin, downloads the project's compose file for that version, and compares the companion
images with ours.

  --check  (default) report; exit 1 on drift that isn't listed under allow_drift
  --fix    rewrite drifting companion image lines to the upstream image (tag@digest; the digest is
           upstream's, or the registry's current one for that tag when upstream has none)
  --root   repo checkout to read and write (default: this repo); the CI sync job runs main's copy
           of this script against the PR checkout
  --report write a Markdown report to this file (used for the weekly drift issue)

Exit 2: upstream added or removed a companion service. That needs a person: --fix doesn't touch it.
"""
import argparse
import json
import pathlib
import sys
import urllib.error
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from imagelib import IMAGE_LINE, digest_of, norm_repo, parse_ref, services  # noqa: E402

ap = argparse.ArgumentParser()
mode = ap.add_mutually_exclusive_group()
mode.add_argument("--check", action="store_true")
mode.add_argument("--fix", action="store_true")
ap.add_argument("--root", default=str(pathlib.Path(__file__).resolve().parent.parent))
ap.add_argument("--report")
ap.add_argument("--stack", action="append", help="only these stacks")
args = ap.parse_args()
root = pathlib.Path(args.root)
policy = json.loads((pathlib.Path(__file__).resolve().parent / "image-policy.json").read_text())

report, worst, failed = [], 0, False


def fetch(urls, version):
    for u in urls:
        url = u.format(version=version)
        try:
            return url, urllib.request.urlopen(url, timeout=30).read().decode()
        except urllib.error.HTTPError as e:
            if e.code != 404:
                raise
    return None, None


for stack, cfg in policy["upstream_compose"].items():
    if stack.startswith("_") or (args.stack and stack not in args.stack):
        continue
    path = root / "docker-compose" / stack / "docker-compose.yml"
    text = path.read_text()
    ours = {svc: (n, ref) for svc, n, ref in services(text)}
    app_repo, version, _ = parse_ref(ours[cfg["app"]["service"]][1])
    lines = [f"### `{stack}`: {cfg['app']['image']} {version} ([upgrade docs]({cfg['docs']}))", ""]
    for svc in cfg.get("same_version", []):
        if parse_ref(ours[svc][1])[1] != version:
            lines.append(f"- **drift**: `{svc}` is not on {version} (must match `{cfg['app']['service']}`)")
            worst, failed = max(worst, 1), True

    url, upstream_text = fetch(cfg["urls"], version)
    if not upstream_text:
        lines.append(f"- **error**: no upstream compose found for {version} (tried {', '.join(cfg['urls'])})")
        report += lines + [""]
        worst, failed = max(worst, 1), True
        continue
    lines[0] += f", [upstream compose]({url})"
    theirs = {svc: ref for svc, _, ref in services(upstream_text)}
    edits = {}
    for our_svc, their_svc in cfg["companions"].items():
        if their_svc not in theirs:
            lines.append(f"- **structural**: upstream {version} no longer has `{their_svc}`: remove `{our_svc}` "
                         f"from the stack by hand (check the release notes first)")
            worst = 2
            continue
        if our_svc not in ours:
            lines.append(f"- **structural**: our stack has no `{our_svc}` (upstream `{their_svc}`)")
            worst = 2
            continue
        n, our_ref = ours[our_svc]
        t_repo, t_tag, t_digest = parse_ref(theirs[their_svc])
        o_repo, o_tag, o_digest = parse_ref(our_ref)
        same = norm_repo(t_repo) == norm_repo(o_repo) and t_tag == o_tag and (not t_digest or t_digest == o_digest)
        if same:
            lines.append(f"- ok: `{our_svc}` = `{t_repo}:{t_tag}`" + (" (upstream digest)" if t_digest else ""))
            continue
        why = cfg.get("allow_drift", {}).get(our_svc)
        if why:
            lines.append(f"- allowed drift: `{our_svc}` is `{our_ref}`, upstream `{theirs[their_svc]}`. {why}")
            continue
        lines.append(f"- **drift**: `{our_svc}` is `{our_ref}`, upstream {version} uses `{theirs[their_svc]}`")
        worst = max(worst, 1)
        edits[n] = f"{t_repo}:{t_tag}@{t_digest or digest_of(t_repo, t_tag)}"
    mapped = set(cfg["companions"].values()) | {cfg["app"]["service"]} | set(cfg.get("same_version", []))
    for svc in sorted(set(theirs) - mapped):
        if cfg["app"]["image"].split("/")[-1] in theirs[svc]:
            continue  # another service on the app image
        lines.append(f"- **structural**: upstream {version} has a service we don't map: `{svc}` (`{theirs[svc]}`)")
        worst = 2

    if args.fix and edits:
        out = text.split("\n")
        for n, new in edits.items():
            m = IMAGE_LINE.match(out[n - 1])
            out[n - 1] = f"{m.group('indent')}image: {new}{m.group('rest')}"
            lines.append(f"- fixed: line {n} -> `{new}`")
        path.write_text("\n".join(out))
    report += lines + [""]

body = "\n".join(report)
print(body)
if args.report:
    pathlib.Path(args.report).write_text(body)
if args.fix and worst == 1 and not failed:
    worst = 0  # every companion drift was rewritten
sys.exit(worst)
