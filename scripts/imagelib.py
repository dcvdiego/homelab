"""Shared helpers for scripts/check-images.py and scripts/upstream-compose.py (stdlib only).

Compose files here are plain YAML with a top-level `services:` block, so a line parser is
enough and keeps the CI jobs free of pip installs.
"""
import json
import re
import urllib.error
import urllib.request

IMAGE_LINE = re.compile(r"^(?P<indent>\s*)image:\s*(?P<ref>[^\s#]+)(?P<rest>.*)$")


def services(text):
    """Yield (service, lineno, image ref) for every `image:` under the top-level services block."""
    in_services, svc_indent, svc = False, None, None
    for n, line in enumerate(text.split("\n"), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        if indent == 0:
            in_services = line.rstrip() == "services:"
            svc_indent, svc = None, None
            continue
        if not in_services:
            continue
        if svc_indent is None:
            svc_indent = indent
        if indent == svc_indent and line.rstrip().endswith(":"):
            svc = line.strip()[:-1].strip("\"'")
            continue
        m = IMAGE_LINE.match(line)
        if m and svc:
            yield svc, n, m.group("ref").strip("\"'")


def parse_ref(ref):
    """'repo:tag@sha256:x' -> (repo, tag or None, digest or None)."""
    digest = None
    if "@" in ref:
        ref, digest = ref.split("@", 1)
    tag = None
    slash = ref.rfind("/")
    colon = ref.rfind(":")
    if colon > slash:
        ref, tag = ref[:colon], ref[colon + 1:]
    return ref, tag, digest


def norm_repo(repo):
    """Docker Hub spellings compare equal: docker.io/library/postgres == postgres."""
    for prefix in ("index.docker.io/", "docker.io/", "registry-1.docker.io/"):
        if repo.startswith(prefix):
            repo = repo[len(prefix):]
    if repo.startswith("library/"):
        repo = repo[len("library/"):]
    return repo


def _registry(repo):
    repo = norm_repo(repo)
    first = repo.split("/")[0]
    if "." in first or ":" in first:
        host, path = first, repo[len(first) + 1:]
    else:
        host, path = "registry-1.docker.io", repo if "/" in repo else "library/" + repo
    if host == "lscr.io":
        host = "ghcr.io"
    return host, path


_TOKENS = {}
ACCEPT = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])


def _request(url, host, path, method="GET", accept=ACCEPT):
    """Anonymous registry request; handles the Bearer token challenge."""
    headers = {"Accept": accept}
    if (host, path) in _TOKENS:
        headers["Authorization"] = "Bearer " + _TOKENS[(host, path)]
    try:
        return urllib.request.urlopen(urllib.request.Request(url, headers=headers, method=method), timeout=30)
    except urllib.error.HTTPError as e:
        challenge = e.headers.get("WWW-Authenticate", "")
        if e.code != 401 or not challenge.startswith("Bearer ") or (host, path) in _TOKENS:
            raise
        params = dict(re.findall(r'(\w+)="([^"]*)"', challenge))
        url_t = f"{params['realm']}?service={params.get('service', '')}&scope=repository:{path}:pull"
        _TOKENS[(host, path)] = json.load(urllib.request.urlopen(url_t, timeout=30))["token"]
        return _request(url, host, path, method, accept)


def digest_of(repo, tag):
    """Current manifest (index) digest of repo:tag. HEAD requests don't count against Docker Hub's pull limit."""
    host, path = _registry(repo)
    r = _request(f"https://{host}/v2/{path}/manifests/{tag}", host, path, method="HEAD")
    return r.headers["Docker-Content-Digest"]


def tags_of(repo):
    host, path = _registry(repo)
    out, url = [], f"https://{host}/v2/{path}/tags/list?n=1000"
    while url:
        r = _request(url, host, path, accept="application/json")
        out += json.load(r).get("tags") or []
        link = r.headers.get("Link")
        url = f"https://{host}" + re.search(r"<([^>]+)>", link).group(1) if link else None
    return out
