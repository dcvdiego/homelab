#!/usr/bin/env python3
"""Breaking changes and upgrade notes for pending image updates, quoted from each project's official
release notes. Sources per image: scripts/image-policy.json "release_notes". Rules: docs/image-versions.md.

  --dashboard N   every update listed in the Renovate dashboard issue N ("Renovate: image updates")
  --base REF      a PR: every image whose tag changed between git REF and the work tree

For each update it reads every release between the running version and the target (not just the
newest one), keeps the sections about breaking changes / upgrade steps / deprecations, and prints
Markdown for GitHub comments (stdout, or one file per comment with --out-dir). Read-only: posting
is the workflow's job (.github/workflows/release-notes.yml). Quotes only, no summaries: what's
written is what the project wrote, with a link to the full notes. --root reads another checkout's
compose files and sources (CI runs main's copy of this script against a PR's checkout).

Source kinds (scripts/image-policy.json "release_notes"):
  {"github": "owner/repo", "tag_prefix": "version/"}   GitHub releases (prereleases skipped)
  {"changelog": raw URL, "section": regex}             one file, a section per version; the regex
                                                       matches the line that starts a section
  {"pages": URL with {line}, "line": n, "lines": {...}} one page per release line (n version parts,
                                                       e.g. 1 = per major); "lines" is a github
                                                       spec or "ha_blog" that lists the lines
  {"link": URL}                                        no machine-readable notes: link only
Add "all": true when the whole section/page is upgrade notes (no filtering), "version": regex with
one group when the tag holds more than one version, "url" for a changelog's human-readable page. An
image can have a list of sources (e.g. the app's changelog and its Docker image's).
"""
import argparse
import fnmatch
import json
import os
import pathlib
import re
import subprocess
import sys
import urllib.error
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from imagelib import norm_repo, parse_ref, services  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
TOKEN = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
# A version number, not digits inside a word or a commit hash (sha-57d556f has none)
VER = re.compile(r"(?<![\w.])v?(\d+(?:\.\d+)*)(?![0-9A-Za-z])")
PRE = re.compile(r"(?i)alpha|beta|\brc|-rc|\.rc|dev\b|nightly|preview|\d+b\d+$")
# Headings worth quoting: what an admin has to act on before or after upgrading
BREAK = re.compile(r"(?i)breaking|backward[- ]?incompatible|upgrade notes|migrat|deprecat|"
                   r"remov|important|action required|before (?:you )?upgrad|known issues|attention|caution|"
                   r"\bnotes? for\b|must read")
# Single bullets worth quoting outside such a section. Not "fixed X breaking Y" or "removed unused code":
# those are bug fixes and cleanups, the full notes are one click away.
BREAK_LINE = re.compile(r"(?i)\bbreaking[ -]changes?\b|⚠|\[CHANGE\]|backward[- ]?incompatible|"
                        r"no longer (?:supported|works?|available|possible)|\bdeprecated\b|"
                        r"\*\*(?:removed|breaking|changed)\*\*|manual (?:action|step|migration)|back ?up (?:your|before)")
BREAK_WORD = re.compile(r"\bBREAKING\b")  # conventional-commit style, upper case only
MD_HEAD = re.compile(r"^(#{1,6})\s+(.*)$")
BULLET = re.compile(r"^\s*[-*+]\s")
TOC = re.compile(r"^\s*[-*+]\s*\[[^\]]*\]\(#")  # table-of-contents link to an anchor
BOLD_HEAD = re.compile(r"^\*\*([^*]+)\*\*:?\s*$")
RST_RULE = re.compile(r"^([=\-~^\"'`#*+])\1{2,}\s*$")
PER_RELEASE, PER_UPDATE, TOTAL = 1500, 6000, 60000

_cache = {}


def fetch(url, accept=None):
    if url in _cache:
        return _cache[url]
    headers = {"User-Agent": "homelab-release-notes"}
    if accept:
        headers["Accept"] = accept
    if TOKEN and url.startswith("https://api.github.com/"):
        headers["Authorization"] = f"Bearer {TOKEN}"
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as r:
            body = r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        body = None if e.code == 404 else _raise(url, e)
    _cache[url] = body
    return body


def _raise(url, e):
    raise RuntimeError(f"{url}: HTTP {e.code}")


def ver(s, rx=None):
    """Version tuple from a tag or heading; rx (a spec's "version") picks it when the tag holds two."""
    m = re.search(rx, s or "") if rx else VER.search(s or "")
    return tuple(int(x) for x in m.group(1).split(".")) if m else None


def in_range(v, cur, tgt):
    """cur < v <= tgt. tgt may be shorter (v2025 = anything in 2025); v may be a release line."""
    if not v or (cur and not v > cur):
        return False
    return tgt is None or v[:len(tgt)] <= tgt


def vstr(v):
    return ".".join(map(str, v))


# ---------------------------------------------------------------- extraction

def headings(lines):
    """[(index, level, text)] for Markdown, bold-line and reStructuredText headings."""
    out, rst_levels = [], []
    for i, line in enumerate(lines):
        if m := MD_HEAD.match(line):
            out.append((i, len(m.group(1)), m.group(2).strip()))
        elif (m := BOLD_HEAD.match(line.strip())) and (i == 0 or not lines[i - 1].strip()):
            out.append((i, 7, m.group(1).strip()))
        elif i + 1 < len(lines) and line.strip() and RST_RULE.match(lines[i + 1]) \
                and len(lines[i + 1].strip()) >= len(line.strip()) and not RST_RULE.match(line):
            ch = lines[i + 1].strip()[0]
            if ch not in rst_levels:
                rst_levels.append(ch)
            out.append((i, rst_levels.index(ch) + 1, line.strip()))
    return out


def cap(text, n):
    text = text.strip()
    return text if len(text) <= n else text[:n].rsplit("\n", 1)[0] + "\n…"


def ha_details(text):
    """Home Assistant posts: the backward-incompatible section is one {% details "Integration" %} each."""
    names = re.findall(r'\{%\s*details\s+"([^"]+)"', text)
    return ("Affected integrations/features: " + ", ".join(names)) if names else None


def extract(text, everything=False):
    """The parts of one release's notes that matter for an upgrade, or '' if none."""
    text = re.sub(r"<!--.*?-->", "", text or "", flags=re.S).strip()
    text = re.sub(r"\A---\n.*?\n---\n", "", text, flags=re.S)  # docs front matter
    text = re.sub(r"^\s*\{\{[<%].*?[>%]\}\}\s*$", "", text, flags=re.M)  # docs-site shortcodes
    if not text.strip():
        return ""
    if everything:
        lines = text.split("\n")
        heads = headings(lines)
        if len(heads) > 3:  # long upgrade page: list its sections, first line of each
            out = []
            for k, (i, _, title) in enumerate(heads):
                end = heads[k + 1][0] if k + 1 < len(heads) else len(lines)
                body = [ln.strip() for ln in lines[i + 1:end] if ln.strip() and not RST_RULE.match(ln)]
                first = body[0] if body else ""
                out.append(f"- **{title}**" + (f": {first}" if first and not MD_HEAD.match(first) else ""))
            return "\n".join(out)
        return text
    lines = text.split("\n")
    heads = headings(lines)
    keep, used = [], set()
    for k, (i, level, title) in enumerate(heads):
        if i in used or not BREAK.search(title):  # nested in a section already quoted
            continue
        end = next((j for j, lv, _ in heads[k + 1:] if lv <= level), len(lines))
        section = "\n".join(lines[i:end]).strip()
        if section.count("\n") == 0:  # heading with nothing under it
            continue
        keep.append(ha_details(section) or section)
        used.update(range(i, end))
    for i, line in enumerate(lines):
        if i in used or not (BREAK_LINE.search(line) or BREAK_WORD.search(line)) or not BULLET.match(line) \
                or TOC.match(line):
            continue
        # the whole bullet: its wrapped continuation lines too
        indent, j = len(line) - len(line.lstrip()), i + 1
        while j < len(lines) and lines[j].strip() and not BULLET.match(lines[j]) \
                and len(lines[j]) - len(lines[j].lstrip()) > indent:
            j += 1
        keep.append(" ".join(ln.strip() for ln in lines[i:j]))
        used.update(range(i, j))
    return "\n".join(keep)


# ---------------------------------------------------------------- sources

def gh_releases(spec):
    repo, prefix = spec["github"], spec.get("tag_prefix", "")
    out = []
    for page in range(1, 6):
        body = fetch(f"https://api.github.com/repos/{repo}/releases?per_page=100&page={page}")
        rels = json.loads(body or "[]")
        for r in rels:
            tag = r["tag_name"]
            if r["draft"] or r["prerelease"] or not tag.startswith(prefix) or PRE.search(tag[len(prefix):]):
                continue
            if v := ver(tag[len(prefix):], spec.get("version")):
                out.append((v, tag, r["html_url"], r.get("body") or ""))
        if len(rels) < 100:
            break
    return sorted(out)


def ha_blog_lines():
    tree = json.loads(fetch("https://api.github.com/repos/home-assistant/home-assistant.io/git/trees/"
                            "current:source/_posts") or '{"tree": []}')
    out = {}
    for t in tree["tree"]:
        if m := re.search(r"^(\d{4})-(\d\d)-(\d\d)-release-(\d{4})(\d{1,2})\.markdown$", t["path"]):
            y, mo, d, ry, rm = m.groups()
            out[(int(ry), int(rm))] = (
                f"https://raw.githubusercontent.com/home-assistant/home-assistant.io/current/source/_posts/{t['path']}",
                f"https://www.home-assistant.io/blog/{y}/{mo}/{d}/release-{ry}{rm}/")
    return out


def notes(spec, cur, tgt):
    """[(label, url, excerpt)] for every release (or release line) in (cur, tgt]."""
    everything = spec.get("all", False)
    if "link" in spec:
        return [("release notes", spec["link"], None)]
    if "github" in spec:
        rels = [r for r in gh_releases(spec) if in_range(r[0], cur, tgt)]
        if not cur:  # running tag isn't a version (e.g. a commit tag): newest release only
            rels = rels[-1:]
        return [(tag, url, extract(body, everything)) for _, tag, url, body in rels]
    if "changelog" in spec:
        text = fetch(spec["changelog"]) or ""
        start = re.compile(spec["section"], re.M)
        marks = [m.start() for m in start.finditer(text)] + [len(text)]
        out = []
        for a, b in zip(marks, marks[1:]):
            section = text[a:b]
            first = section.split("\n", 1)[0]
            if in_range(ver(first, spec.get("version")), cur, tgt):
                out.append((first.strip("# ").strip(), spec.get("url", spec["changelog"]), extract(section, everything)
                            or (cap(section, PER_RELEASE) if BREAK.search(first) else "")))
        return out
    if "pages" in spec:
        n = spec["line"]
        if spec["lines"] == "ha_blog":
            blog = ha_blog_lines()
            lines = sorted(v for v in blog if in_range(v, cur[:n] if cur else None, tgt[:n] if tgt else None))
            if not lines and cur and tgt and cur[:n] == tgt[:n] and cur[:n] in blog:
                # patch release in the running line: HA only ships breaking changes in the monthly release
                return [(f"{vstr(cur[:n])} patch releases", blog[cur[:n]][1], "")]
            return [(vstr(v), blog[v][1], extract(fetch(blog[v][0]) or "", everything)) for v in lines]
        lines = sorted({r[0][:n] for r in gh_releases(spec["lines"]) if in_range(r[0], cur, tgt)
                        and (not cur or r[0][:n] > cur[:n])})
        if not lines:  # patch update inside the running line: the line's upgrade page was read already
            return notes(spec["lines"], cur, tgt)
        out = []
        for v in lines:
            fields = {"line": vstr(v), "major": v[0], "minor": v[1] if len(v) > 1 else 0}
            raw, html = spec["pages"].format(**fields), spec.get("html", spec["pages"]).format(**fields)
            out.append((vstr(v), html, extract(fetch(raw) or "", everything) if fetch(raw) else "(page not found)"))
        return out
    return []


# ---------------------------------------------------------------- what's pending

def renovate_skips():
    """(ignored path globs, [(file globs, package patterns)] of rules that switch updates off entirely)."""
    cfg = json.loads((ROOT / "renovate.json").read_text())
    off = [(r.get("matchFileNames", ["**"]), r.get("matchPackageNames", []))
           for r in cfg.get("packageRules", [])
           if r.get("enabled") is False and set(r) <= {"description", "matchFileNames", "matchPackageNames", "enabled"}]
    return cfg.get("ignorePaths", []), off


def _match(name, pattern):
    if pattern.startswith("/") and pattern.endswith("/"):
        return re.search(pattern[1:-1], name) is not None
    return fnmatch.fnmatchcase(name, pattern)


def current_tags(rev=None):
    """{normalized repo: {"file:service": tag}} for the images Renovate updates the version of: ignored
    paths, images whose updates renovate.json switches off, and upstream-compose companions are left out."""
    ignored, off = renovate_skips()
    policy = json.loads((ROOT / "scripts/image-policy.json").read_text())
    # companions follow their app's upstream compose (scripts/upstream-compose.py), not their own releases
    companions = {(stack, svc) for stack, cfg in policy["upstream_compose"].items() if not stack.startswith("_")
                  for svc in cfg["companions"]}
    files = subprocess.run(["git", "-C", str(ROOT), "ls-files" if not rev else "ls-tree"]
                           + ([] if not rev else ["-r", "--name-only", rev]) + ["docker-compose"],
                           capture_output=True, text=True, check=True).stdout.split()
    out = {}
    for rel in files:
        if any(fnmatch.fnmatch(rel, g) for g in ignored):
            continue
        text = (subprocess.run(["git", "-C", str(ROOT), "show", f"{rev}:{rel}"], capture_output=True,
                               text=True).stdout if rev else (ROOT / rel).read_text())
        name = rel.rsplit("/", 1)[-1]
        refs = []
        if re.fullmatch(r"(docker-)?compose[^/]*\.ya?ml", name):
            refs = [(f"{rel}:{svc}", ref) for svc, _, ref in services(text)]
        elif name.startswith("Dockerfile"):
            refs = [(f"{rel}:FROM", m) for m in re.findall(r"^\s*FROM\s+(?:--\S+\s+)*(\S+)", text, re.M | re.I)]
        for key, ref in refs:
            repo, tag, _ = parse_ref(ref)
            if (rel.split("/")[1], key.rsplit(":", 1)[1]) in companions:
                continue
            if any(any(fnmatch.fnmatch(rel, g) for g in globs) and any(_match(repo, p) for p in pkgs)
                   for globs, pkgs in off):
                continue
            out.setdefault(norm_repo(repo), {})[key] = tag
    return out


def dashboard_updates(issue):
    repo = os.environ.get("GITHUB_REPOSITORY") or subprocess.run(
        ["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
        capture_output=True, text=True, check=True, cwd=ROOT).stdout.strip()
    body = json.loads(fetch(f"https://api.github.com/repos/{repo}/issues/{issue}"))["body"]
    updates, seen = [], set()
    for m in re.finditer(r"<!--\s*[\w-]+-branch=(renovate/[^\s]+)\s*-->\s*(.+)", body):
        branch, title = m.group(1), re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", m.group(2)).strip()
        if branch in seen or "digest" in title.lower():
            continue
        seen.add(branch)
        pkgs = re.findall(r"`([^`]+)`", title)
        t = re.match(r"Update (\S+) Docker tag to v?(\S+)", title)
        if t:
            pkgs, to = [t.group(1)], t.group(2)
        else:
            t = re.search(r"\bto v?(\d[\w.\-]*)", title)
            to = t.group(1) if t else None
        if pkgs:
            updates.append({"title": title.split(" (`")[0], "branch": branch, "pkgs": pkgs, "to": to})
    return updates


def pr_updates(base):
    before, after = current_tags(base), current_tags()
    out = []
    for repo, keys in after.items():
        for key, tag in keys.items():
            old = before.get(repo, {}).get(key)
            if old and tag and old != tag:
                out.append({"title": f"{repo} {old} → {tag}", "pkgs": [repo], "to": tag, "from": old})
    # one entry per repo and version change
    uniq = {(u["pkgs"][0], u["from"], u["to"]): u for u in out}
    return list(uniq.values())


# ---------------------------------------------------------------- report

def render(updates, sources, tags, header, marker):
    """Comment bodies: the first has the header and the full summary table, the rest the quoted notes,
    packed under GitHub's comment size limit (one comment per chunk, each with its own marker)."""
    blocks_all, rows = [], []
    for u in updates:
        tgt = ver(u["to"]) if u.get("to") else None
        done, blocks, found, read, links, missing = set(), [], 0, 0, 0, []
        for pkg in u["pkgs"]:
            repo = norm_repo(pkg)
            specs = sources.get(repo)
            if specs is None:
                missing.append(pkg)
                continue
            currents = {u["from"]} if u.get("from") else set(tags.get(repo, {}).values())
            for spec, cur_tag in [(sp, c) for sp in (specs if isinstance(specs, list) else [specs])
                                  for c in sorted(c for c in currents if c)]:
                key = json.dumps(spec, sort_keys=True)
                if (key, cur_tag) in done:
                    continue
                done.add((key, cur_tag))
                cur = ver(cur_tag, spec.get("version"))
                # the weekly batch is minor/patch only (renovate.json): stay in the running major
                upper = tgt if tgt else ((cur[0],) if cur and "weekly" in u.get("branch", "") else None)
                try:
                    items = notes(spec, cur, upper)
                except Exception as e:  # one broken source shouldn't hide the rest
                    blocks.append(f"**{pkg}**: couldn't read release notes ({e})")
                    continue
                if not items:
                    continue
                to = u.get("to") or (f"newest {cur[0]}.x" if upper else "newest")
                lines, quiet = [f"**{pkg}** `{cur_tag}` → `{to}`"], []
                for label, url, text in items:
                    if text is None:
                        links += 1
                        lines.append(f"- no machine-readable notes: read [{label}]({url})")
                    elif text:
                        found += 1
                        lines.append(f"- [{label}]({url}):\n\n" + "\n".join(
                            "  " + ln for ln in cap(text, PER_RELEASE).split("\n")))
                    else:
                        read += 1
                        quiet.append(f"[{label}]({url})")
                if quiet:
                    lines.append("- nothing marked breaking in " + ", ".join(quiet))
                blocks.append(cap("\n".join(lines), PER_UPDATE))
        if found:
            status = f"⚠️ upgrade notes in {found} release{'s' if found > 1 else ''}"
        elif read:
            status = f"nothing marked breaking ({read} release{'s' if read > 1 else ''} read)"
        elif links:
            status = "no machine-readable notes: read the link"
        else:
            status = "no releases found in range"
        if missing:
            status += f"; no source for {', '.join(missing)}"
        rows.append(f"| {u['title']} | {status} |")
        if blocks:
            blocks_all.append(f"<details><summary><b>{u['title']}</b> ({status})</summary>\n\n"
                              + "\n\n".join(blocks) + "\n\n</details>")
    first = f"{marker.format(n=1)}\n{header}\n\n| Update | Release notes |\n|---|---|\n" + "\n".join(rows)
    bodies = [first]
    for b in blocks_all:
        if len(bodies[-1]) + len(b) + 2 > TOTAL:
            bodies.append(marker.format(n=len(bodies) + 1))
        bodies[-1] += "\n\n" + b
    return bodies


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--dashboard", type=int, help="Renovate dashboard issue number")
    g.add_argument("--base", help="git ref the PR is compared against, e.g. origin/main")
    ap.add_argument("--out-dir", help="write one file per comment (1.md, 2.md, ...) instead of stdout")
    ap.add_argument("--root", help="repo checkout to read (default: the one this script is in)")
    args = ap.parse_args()
    global ROOT
    if args.root:
        ROOT = pathlib.Path(args.root).resolve()

    policy = json.loads((ROOT / "scripts/image-policy.json").read_text())
    sources = {norm_repo(k): v for k, v in policy["release_notes"].items() if not k.startswith("_")}
    tags = current_tags()
    marker = "<!-- release-notes-digest:{n} -->"
    if args.dashboard:
        updates = dashboard_updates(args.dashboard)
        header = ("## Upgrade notes for the updates above\n"
                  "Quoted from each project's official release notes, for every release between what runs now "
                  "and the update (scripts/release-notes.py). Only the sections about breaking changes, upgrade "
                  "steps, deprecations and removals; follow the links for the rest. Rules and order per app: "
                  "docs/image-versions.md.")
    else:
        updates = pr_updates(args.base)
        header = ("## Upgrade notes for this update\n"
                  "Quoted from the official release notes of every release this PR moves past "
                  "(scripts/release-notes.py). Only breaking changes, upgrade steps, deprecations and removals.")
    bodies = render(updates, sources, tags, header, marker) if updates else \
        [marker.format(n=1) + "\n" + header + "\n\nNo version changes."]
    if args.out_dir:
        out = pathlib.Path(args.out_dir)
        out.mkdir(parents=True, exist_ok=True)
        for i, body in enumerate(bodies, 1):
            (out / f"{i}.md").write_text(body)
    else:
        print("\n\n---\n\n".join(bodies))


if __name__ == "__main__":
    main()
