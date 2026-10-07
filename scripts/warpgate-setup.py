#!/usr/bin/env python3
"""Configure Warpgate (LXC 106) for agent access. Idempotent: safe to re-run.

Creates the targets, roles and users described in docs/agent-access.md:
  pve-ro, docker-prod-ro, docker-tower-ro   ai-agent, read-only sudo, no approval     (user agent)
  pve-root                                  root on pvehost, every session approved   (user agent)
  pve-root-ops                              root on pvehost, no approval               (user ops: the
                                            GitHub runner, only after the owner approved the job)
The ops user is created once ~/.config/homelab/ops-runner.pub exists (the runner's public key).

Needs a Warpgate API token for an admin (Warpgate UI -> your profile -> API tokens), in
~/.config/homelab/warpgate-api-token or $WARPGATE_TOKEN. Give it a short expiry.

  scripts/warpgate-setup.py                   apply
  scripts/warpgate-setup.py --lock-host-keys  after every target has connected once: reject unknown host keys
"""
import argparse
import json
import os
import ssl
import sys
import urllib.error
import urllib.request
from pathlib import Path

API = "https://192.168.1.227:8888/@warpgate/admin/api"
CTX = ssl._create_unverified_context()  # Warpgate's self-signed cert; LAN only

AGENT_KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKMxL3xqQwmywQfDUCXYYwgVxBbzHzx/nD8L4Kc+Raex agent@agents (warpgate)"
OPS_KEY_FILE = Path.home() / ".config/homelab/ops-runner.pub"
USERS = {  # name: (description, allowed source, roles, public key or None)
    "agent": ("AI agents on the agents box (LXC 102)", ["192.168.1.226/32"], ["agent-ro", "agent-root"], AGENT_KEY),
    "ops": ("GitHub runner on docker-tower, applies approved PRs", ["192.168.1.248/32"], ["ops-root"],
            OPS_KEY_FILE.read_text().strip() if OPS_KEY_FILE.exists() else None),
}

TARGETS = {  # name: (host, user, needs approval, role)
    "pve-ro": ("192.168.1.148", "ai-agent", False, "agent-ro"),
    "docker-prod-ro": ("192.168.1.224", "ai-agent", False, "agent-ro"),
    "docker-tower-ro": ("192.168.1.248", "ai-agent", False, "agent-ro"),
    "pve-root": ("192.168.1.148", "root", True, "agent-root"),
    "pve-root-ops": ("192.168.1.148", "root", False, "ops-root"),
}
PARAMETERS = {
    "admin_approval_timeout_seconds": 900,         # a pending session waits 15 min for you
    "admin_approval_grace_period_seconds": 3600,   # "remember" an approval for at most 1 h
}


def token():
    t = os.environ.get("WARPGATE_TOKEN") or (Path.home() / ".config/homelab/warpgate-api-token").read_text()
    return t.strip()


def call(method, path, body=None, ok_conflict=False):
    req = urllib.request.Request(f"{API}{path}", method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"X-Warpgate-Token": token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, context=CTX, timeout=20) as r:
            raw = r.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        if ok_conflict and e.code in (400, 409):
            return None
        sys.exit(f"{method} {path}: HTTP {e.code} {e.read()[:300].decode(errors='replace')}")


PUT_PATH = {"/roles": "/role", "/targets": "/targets", "/users": "/users"}  # roles update at /role/{id}


def ensure(collection, name, body, key="name"):
    existing = {x[key]: x for x in call("GET", collection)}
    if name in existing:
        oid = existing[name]["id"]
        print(f"updated {collection[1:-1]} {name}")
    else:
        oid = call("POST", collection, body)["id"]
        print(f"created {collection[1:-1]} {name}")
    # Always PUT the full body: create endpoints ignore some fields (users: credential_policy,
    # allowed_ip_ranges), so a create alone silently leaves them unset.
    call("PUT", f"{PUT_PATH[collection]}/{oid}", body)
    return oid


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--lock-host-keys", action="store_true", help="switch SSH host key verification to AutoReject")
    args = ap.parse_args()

    params = dict(PARAMETERS)
    if args.lock_host_keys:
        params["ssh_host_key_verification"] = "AutoReject"
    call("PUT", "/parameters", params)
    print(f"parameters: {params}")

    roles = {r: ensure("/roles", r, {"name": r, "description": "agent access, see homelab docs/agent-access.md"})
             for r in sorted({t[3] for t in TARGETS.values()})}

    for name, (host, user, approval, role) in TARGETS.items():
        tid = ensure("/targets", name, {
            "name": name,
            "description": f"{user}@{host}" + (" (needs approval)" if approval else " (read-only)"),
            "options": {"kind": "Ssh", "host": host, "port": 22, "username": user,
                        "allow_insecure_algos": False, "auth": {"kind": "PublicKey"}},
            "require_approval": approval,
            "ticket_requests_disabled": True,
            "ticket_require_approval": True,
        })
        call("POST", f"/targets/{tid}/roles/{roles[role]}", ok_conflict=True)

    for username, (desc, sources, user_roles, key) in USERS.items():
        if key is None:
            print(f"skipped user {username}: no public key yet ({OPS_KEY_FILE})")
            continue
        uid = ensure("/users", username, {
            "username": username, "description": desc,
            "credential_policy": {"ssh": ["PublicKey"]}, "allowed_ip_ranges": sources,
        }, key="username")
        keys = call("GET", f"/users/{uid}/credentials/public-keys")
        if not any(k["openssh_public_key"].split()[:2] == key.split()[:2] for k in keys):
            call("POST", f"/users/{uid}/credentials/public-keys", {"label": username, "openssh_public_key": key})
            print(f"added public key for {username}")
        for r in user_roles:
            call("POST", f"/users/{uid}/roles/{roles[r]}", {}, ok_conflict=True)
    print("done: from the agents box, try `ssh pve-ro hostname`")


if __name__ == "__main__":
    main()
