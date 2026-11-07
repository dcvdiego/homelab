# Follow-up to 2026-11-07-romm.sh (apply run 42413791771), which deployed RomM but failed on DNS:
#   - Technitium docker-tower: romm.homelab.lan added; romm.$DOMAIN returned "error" (message not logged)
#   - Technitium docker-prod: "invalid-token" for both records (TECHNITIUM_PROD_TOKEN is stale)
#   - Cloudflare: HTTPError. Not needed: the *.$DOMAIN tunnel wildcard already routes romm.$DOMAIN
#     through Cloudflare Access (checked 2026-11-07: public 302 to Access, LAN Traefik 200), so this
#     request leaves Cloudflare alone.
#   - Komodo: a "romm" stack already existed, so the request skipped its config, including Pre Deploy.
#
# This request:
# 1. Adds romm.homelab.lan and romm.$DOMAIN (split DNS) -> 192.168.1.224 on both Technitium instances,
#    printing Technitium's error message (domain masked) and the $DOMAIN zone's type when one fails.
# 2. Prints the romm stack's non-secret config (server, run directory, Pre Deploy, env var names) and
#    sets Pre Deploy to `sh ../../scripts/pre-deploy-backup.sh romm` if it's empty (read before write).
# Undo: Technitium /api/zones/records/delete for those names; clear Pre Deploy on the romm stack.
set -u
rc=0
python3 - <<'PY' || rc=1
import json, os, sys, urllib.parse, urllib.request

def call(url, data=None, headers=None, method=None):
    req = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read() or "null")

def technitium(ip, path, params):
    """Technitium API call. Its token is in the query string, so errors print the class only."""
    try:
        return call(f"http://{ip}:5380/api/{path}?{urllib.parse.urlencode(params)}")
    except Exception as e:
        return {"status": "request-failed", "errorMessage": e.__class__.__name__}

def komodo(kind, typ, params):
    return call(f"{os.environ['KOMODO_URL']}/{kind}/{typ}", json.dumps(params).encode(),
                {"Content-Type": "application/json", "x-api-key": os.environ["KOMODO_API_KEY"],
                 "x-api-secret": os.environ["KOMODO_API_SECRET"]}, "POST")

ok = True
def env_domain(stack):
    env = komodo("read", "GetStack", {"stack": stack})["config"].get("environment", "")
    return next((l.split("=", 1)[1].strip().strip('"') for l in env.splitlines()
                 if l.strip().startswith("DOMAIN=")), "")

# DOMAIN from the romm stack itself (2026-11-07-romm.sh copied it there), else from notes
domain = env_domain("romm") or env_domain("notes")
if not domain:
    sys.exit("DOMAIN not found in the romm or notes stack env; nothing changed")
mask = lambda s: str(s).replace(domain, "<DOMAIN>")

print("== 1. Technitium")
for ip, var in (("192.168.1.248", "TECHNITIUM_TOWER_TOKEN"), ("192.168.1.224", "TECHNITIUM_PROD_TOKEN")):
    tok = os.environ.get(var, "")
    zones = technitium(ip, "zones/list", {"token": tok})
    if zones.get("status") == "request-failed":
        print(f"{ip}: unreachable ({zones['errorMessage']})"); ok = False; continue
    if zones.get("status") != "ok":
        print(f"{ip}: {zones.get('status')}: {var} doesn't work; rotate it (Technitium -> Administration -> Sessions -> Create Token) and update the GitHub secret")
        ok = False; continue
    ztype = {z["name"]: z.get("type") for z in zones["response"]["zones"]}
    print(f"{ip}: zones homelab.lan={ztype.get('homelab.lan')}, <DOMAIN>={ztype.get(domain)}")
    for zone, name in (("homelab.lan", "romm.homelab.lan"), (domain, f"romm.{domain}")):
        r = technitium(ip, "zones/records/add", {"token": tok, "zone": zone, "domain": name, "type": "A",
                                                  "ipAddress": "192.168.1.224", "ttl": 3600, "overwrite": "true"})
        msg = "" if r.get("status") == "ok" else f" ({mask(r.get('errorMessage', ''))})"
        print(f"{ip}: {mask(name)} -> 192.168.1.224: {r.get('status')}{msg}")
        ok &= r.get("status") == "ok"

print("== 2. Komodo romm stack")
want = "sh ../../scripts/pre-deploy-backup.sh romm"
stack = komodo("read", "GetStack", {"stack": "romm"})
cfg = stack["config"]
servers = {s["id"]: s["name"] for s in komodo("read", "ListServers", {"limit": 500})}
names = [l.split("=", 1)[0].strip() for l in cfg.get("environment", "").splitlines() if "=" in l and not l.strip().startswith("#")]
print(f"server={servers.get(cfg.get('server_id'), '?')} repo={cfg.get('repo')}@{cfg.get('branch')} "
      f"run_directory={cfg.get('run_directory')} project={cfg.get('project_name') or '(default)'} auto_pull={cfg.get('auto_pull')}")
print(f"env var names: {', '.join(names) or '(none)'}")
if cfg.get("run_directory", "").strip("/") != "docker-compose/romm":
    sys.exit("run_directory isn't docker-compose/romm; Pre Deploy left alone")
sid = stack.get("_id") or stack.get("id")
sid = sid.get("$oid") if isinstance(sid, dict) else sid
cur = (cfg.get("pre_deploy") or {}).get("command", "").strip()
if cur == want:
    print("pre_deploy: already set")
elif cur:
    print("pre_deploy: SKIPPED, another command is set (left as is)")
else:
    # UpdateStack takes a partial config and merges it (same call as 2026-11-07-vikunja-backup-komodo-diff.sh);
    # the read-back also checks that the env and run directory are still there.
    komodo("write", "UpdateStack", {"id": sid, "config": {"pre_deploy": {"path": "", "command": want}}})
    after = komodo("read", "GetStack", {"stack": "romm"})["config"]
    got = (after.get("pre_deploy") or {}).get("command", "").strip()
    kept = (after.get("run_directory") == cfg.get("run_directory")
            and after.get("environment", "") == cfg.get("environment", ""))
    print("pre_deploy: set" if got == want else f"pre_deploy: FAILED (reads back as {got!r})")
    print("rest of the config: unchanged" if kept else "rest of the config: CHANGED (check the stack in Komodo)")
    ok &= got == want and kept
sys.exit(0 if ok else 1)
PY
exit $rc
