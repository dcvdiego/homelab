#!/usr/bin/env python3
"""Move Portainer stacks to Komodo, keeping the running containers (docs/komodo-migration.md).

Runs on the homelab-ops runner from an ops request; prints names, never env values.

  komodo-migrate.py check   <stack>@<server> ...   read-only: drift between Portainer's live compose
                                                   file and the repo, and the env var names
  komodo-migrate.py migrate <stack>@<server>[+drift] ...   create the Komodo stack from git (same compose
                                                   project name, env copied from Portainer), deploy,
                                                   report which services were recreated

<server> is the Komodo server name (docker-tower, docker-prod). The Komodo stack is named after the
Portainer stack, with "-<server>" appended when the same name exists on both hosts (network).
Deploys never pull images (auto_pull off), so adopting a stack doesn't upgrade it. The Portainer
stack is left as is: never redeploy it from Portainer afterwards (compose would fight Komodo).
"""
import difflib
import json
import os
import re
import ssl
import sys
import time
import urllib.request
from pathlib import Path

REPO = "dcvdiego/homelab"
ENDPOINTS = {"docker-tower": 2, "docker-prod": 3}            # Portainer endpoint id per server
DUPLICATE_NAMES = {"network"}                                  # same stack name on both hosts
INSECURE = ssl._create_unverified_context()                    # Portainer's self-signed LAN cert


def http(url, headers, body=None, method=None, ctx=None):
    req = urllib.request.Request(url, method=method or ("POST" if body is not None else "GET"),
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Content-Type": "application/json", **headers})
    with urllib.request.urlopen(req, timeout=300, context=ctx) as r:
        raw = r.read()
        return json.loads(raw) if raw else None


def portainer(path):
    return http(os.environ["PORTAINER_URL"] + path, {"x-api-key": os.environ["PORTAINER_TOKEN"]}, ctx=INSECURE)


def komodo(kind, typ, params):
    return http(f"{os.environ['KOMODO_URL']}/{kind}/{typ}",
                {"x-api-key": os.environ["KOMODO_API_KEY"], "x-api-secret": os.environ["KOMODO_API_SECRET"]},
                body=params)


def env_file(env):
    """Portainer env -> .env text. Single quotes keep values literal ($ is not interpolated)."""
    lines = []
    for e in env:
        v = e.get("value", "")
        if "'" not in v:
            lines.append(f"{e['name']}='{v}'")
        else:
            lines.append(f'{e["name"]}="' + v.replace("\\", "\\\\").replace('"', '\\"').replace("$", "$$") + '"')
    return "\n".join(lines) + ("\n" if lines else "")


def drift(live, repo):
    """Changed lines; values masked except image tags: enough to judge, nothing secret."""
    # image tags and bind-mount paths are shown as-is; everything else after ":" or "=" is masked
    mask = lambda l: l.rstrip() if re.match(r"^[+-]\s*(image:|- /)", l) else re.sub(r"([:=]\s*).+", r"\1…", l.rstrip())
    norm = lambda s: [l.rstrip() for l in s.strip().splitlines() if l.strip() and not l.strip().startswith("#")]
    d = [l for l in difflib.unified_diff(norm(live), norm(repo), "portainer", "repo", lineterm="", n=0)
         if l[:1] in "+-" and not l.startswith(("+++", "---"))]
    return [mask(l) for l in d]


def containers(server, project):
    out = {}
    for c in komodo("read", "ListContainers", {"server": server}) or []:   # "ListDockerContainers" before v2.3.0
        labels = c.get("labels") or {}
        if labels.get("com.docker.compose.project") == project:
            out[labels.get("com.docker.compose.service", c.get("name"))] = c.get("id")
    return out


def wait(update):
    uid = update["_id"]["$oid"]   # Update ids serialize as {"_id": {"$oid": ...}}
    for _ in range(180):
        u = komodo("read", "GetUpdate", {"id": uid})
        if u.get("status") == "Complete":
            return u
        time.sleep(5)
    raise TimeoutError("deploy did not finish in 15 min")


def main():
    mode, targets = sys.argv[1], sys.argv[2:]
    assert mode in ("check", "migrate") and targets, __doc__
    stacks = portainer("/api/stacks")
    servers = {s["name"]: s["id"] for s in komodo("read", "ListServers", {"limit": 500})}
    rc = 0
    for t in targets:
        accept_drift = t.endswith("+drift")          # owner reviewed the drift; repo is the intended state
        name, server = t.removesuffix("+drift").split("@")
        ps = [s for s in stacks if s["Name"] == name and s["EndpointId"] == ENDPOINTS[server]]
        if len(ps) != 1:
            print(f"!! {t}: {len(ps)} Portainer stacks match"); rc = 1; continue
        ps = ps[0]
        repo_file = Path("docker-compose") / name / "docker-compose.yml"
        live = portainer(f"/api/stacks/{ps['Id']}/file")["StackFileContent"]
        d = drift(live, repo_file.read_text()) if repo_file.exists() else ["(no repo file)"]
        env = ps.get("Env") or []
        kname = f"{name}-{server.split('-')[-1]}" if name in DUPLICATE_NAMES else name
        print(f"== {t}  (Portainer #{ps['Id']}, {'git' if ps.get('GitConfig') else 'web editor'}) -> Komodo '{kname}'")
        print(f"   env: {', '.join(e['name'] for e in env) or '(none)'}")
        print(f"   compose drift vs repo: {'none' if not d else str(len(d)) + ' line(s)'}")
        for l in d[:40]:
            print(f"     {l}")
        if mode == "check":
            continue
        if d and not accept_drift:
            print("   SKIP: live compose differs from the repo; sync the repo first (or mark it +drift)"); rc = 1; continue
        if server not in servers:
            print(f"   SKIP: Komodo server {server} not found"); rc = 1; continue
        before = containers(server, name)
        config = {"server_id": servers[server], "project_name": name,
                  "git_provider": "github.com", "git_https": True, "repo": REPO, "branch": "main",
                  "run_directory": f"docker-compose/{name}", "file_paths": ["docker-compose.yml"],
                  "env_file_path": ".env", "environment": env_file(env),
                  "auto_pull": False, "webhook_enabled": False, "send_alerts": True}
        existing = {s["name"]: s for s in komodo("read", "ListStacks", {"limit": 500})}
        if kname in existing:
            komodo("write", "UpdateStack", {"id": existing[kname]["id"], "config": config})
            print("   Komodo stack updated")
        else:
            komodo("write", "CreateStack", {"name": kname, "config": config})
            print("   Komodo stack created")
        u = wait(komodo("execute", "DeployStack", {"stack": kname}))
        after = containers(server, name)
        recreated = sorted(s for s in after if before.get(s) != after[s])
        ok = u.get("success")
        print(f"   deploy: {'ok' if ok else 'FAILED'}; services {len(after)}/{len(before)} running before/after; "
              f"recreated: {', '.join(recreated) or 'none'}")
        if not ok:
            rc = 1
            for log in u.get("logs", [])[-3:]:
                print(f"     [{log.get('stage')}] {(log.get('stderr') or '')[-300:]}")
    sys.exit(rc)


if __name__ == "__main__":
    main()
