# Renovate for diego/homelab-private on Forgejo (docker-compose/renovate). Phase 3 of docs/forgejo-split.md.
#
# 1. Forgejo (temporary admin "ops-setup", deleted on exit, which revokes its token): give renovate-bot
#    a full name (Renovate's Forgejo docs require name and email) and make it a write collaborator on
#    diego/homelab-private. Branch protection still lets only diego push or merge main.
# 2. Only if Komodo has no "renovate" stack yet: a renovate-bot token (scopes from the Renovate Forgejo
#    docs: write:repository, read:user, write:issue, read:organization), straight into a new Komodo
#    stack "renovate" on docker-tower (docker-compose/renovate, env RENOVATE_TOKEN). Never printed. An
#    existing stack is left as it is, and no token is made.
# 3. Deploy the stack and check the container runs.
#
# Undo: Komodo -> Stacks -> renovate -> Destroy, delete the stack; in Forgejo, delete renovate-bot's
# token (Site administration -> Users -> renovate-bot) and remove it from the repo's collaborators.
set -u
PVE() { ssh -F "$OPS_SSH_CONFIG" pve "$@"; }
# forgejo CLI in the container; pvehost's shell is the only one that parses it, so each argument is quoted once
FJ() { PVE "pct exec 104 -- docker exec -u 1000 forgejo forgejo $(printf '%q ' "$@")"; }

echo "== 1. Forgejo: renovate-bot name and collaborator"
drop_setup_user() {
  if FJ admin user delete --username ops-setup >/dev/null 2>&1; then echo "setup user: deleted (token revoked)"
  else echo "setup user: NOT deleted: delete user ops-setup in Forgejo (Site administration > Users)"; fi
}
FJ admin user delete --username ops-setup >/dev/null 2>&1 || true   # left over from a killed run
FJ admin user create --admin --username ops-setup --email ops-setup@homelab.lan --random-password \
   --random-password-length 32 --must-change-password=false >/dev/null || { echo "setup user: FAILED"; exit 1; }
trap drop_setup_user EXIT
ADMIN_TOKEN=$(FJ admin user generate-access-token -u ops-setup -t setup \
                --scopes write:admin,write:repository,read:user --raw 2>/dev/null) || ADMIN_TOKEN=
[ -n "$ADMIN_TOKEN" ] || { echo "admin token: FAILED"; exit 1; }
export ADMIN_TOKEN

python3 - <<'PY'
import json, os, sys, urllib.error, urllib.request
API = "http://192.168.1.248:3200/api/v1"
H = {"Authorization": f"token {os.environ['ADMIN_TOKEN']}", "Content-Type": "application/json"}
def api(method, path, body=None):
    req = urllib.request.Request(API + path, json.dumps(body).encode() if body is not None else None, H, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code
ok = True
st = api("PATCH", "/admin/users/renovate-bot", {"login_name": "renovate-bot", "source_id": 0, "full_name": "Renovate Bot"})
print(f"renovate-bot full name: {st}"); ok &= st == 200
st = api("PUT", "/repos/diego/homelab-private/collaborators/renovate-bot", {"permission": "write"})
print(f"collaborator renovate-bot (write): {st}"); ok &= st == 204
sys.exit(0 if ok else 1)
PY

echo "== 2+3. Komodo stack renovate, deploy"
# exit 0: stack exists, 3: missing, anything else: Komodo unreachable (stop before making a token)
st=0; python3 - <<'PY' || st=$?
import json, os, sys, urllib.request
req = urllib.request.Request(f"{os.environ['KOMODO_URL']}/read/ListStacks", json.dumps({}).encode(),
        {"Content-Type": "application/json", "x-api-key": os.environ["KOMODO_API_KEY"],
         "x-api-secret": os.environ["KOMODO_API_SECRET"]}, method="POST")
with urllib.request.urlopen(req, timeout=60) as r:
    sys.exit(0 if "renovate" in {s["name"] for s in json.loads(r.read())} else 3)
PY
if [ "$st" -eq 0 ]; then
  echo "komodo: stack 'renovate' already exists; config and token left as they are"; RENOVATE_TOKEN=
elif [ "$st" -ne 3 ]; then
  echo "komodo: cannot list stacks"; exit 1
else
  RENOVATE_TOKEN=$(FJ admin user generate-access-token -u renovate-bot -t "renovate-stack-$(date +%s)" \
                     --scopes write:repository,read:user,write:issue,read:organization --raw 2>/dev/null) || RENOVATE_TOKEN=
  [ -n "$RENOVATE_TOKEN" ] || { echo "renovate-bot token: FAILED"; exit 1; }
  echo "renovate-bot token: made (goes only into the stack env)"
fi
export RENOVATE_TOKEN

rc=0
python3 - <<'PY' || rc=1
import json, os, sys, time, urllib.request
def komodo(kind, typ, params, timeout=60):
    req = urllib.request.Request(f"{os.environ['KOMODO_URL']}/{kind}/{typ}", json.dumps(params).encode(),
            {"Content-Type": "application/json", "x-api-key": os.environ["KOMODO_API_KEY"],
             "x-api-secret": os.environ["KOMODO_API_SECRET"]}, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read() or "null")

NAME, SERVER, RUN_DIR = "renovate", "docker-tower", "docker-compose/renovate"
tok = os.environ.get("RENOVATE_TOKEN", "")
if tok:
    servers = {s["name"]: s["id"] for s in komodo("read", "ListServers", {})}
    if SERVER not in servers:
        sys.exit(f"komodo: server {SERVER} not found; stack not created")
    config = {"server_id": servers[SERVER], "project_name": NAME,
              "git_provider": "github.com", "git_https": True, "repo": "dcvdiego/homelab", "branch": "main",
              "run_directory": RUN_DIR, "file_paths": ["docker-compose.yml"],
              "env_file_path": ".env", "environment": f"RENOVATE_TOKEN={tok}\n",
              "auto_pull": False, "webhook_enabled": False, "send_alerts": True}
    komodo("write", "CreateStack", {"name": NAME, "config": config})
    got = komodo("read", "GetStack", {"stack": NAME})["config"]
    good = got.get("run_directory") == RUN_DIR and "RENOVATE_TOKEN=" in got.get("environment", "")
    print(f"komodo: stack 'renovate' created: {'ok' if good else 'FAILED (config reads back different)'}")
    if not good:
        sys.exit(1)

uid = komodo("execute", "DeployStack", {"stack": NAME}, timeout=300)["_id"]["$oid"]
u = {}
for _ in range(120):
    u = komodo("read", "GetUpdate", {"id": uid})
    if u.get("status") == "Complete":
        break
    time.sleep(5)
print(f"komodo: deploy renovate: {'ok' if u.get('success') else 'FAILED'}")
# Failed stages: error tail only, with every stack env value redacted (agents can read this output)
env_vals = [l.split("=", 1)[1].strip() for l in
            komodo("read", "GetStack", {"stack": NAME})["config"].get("environment", "").splitlines()
            if "=" in l and len(l.split("=", 1)[1].strip()) >= 8]
for log in u.get("logs", []):
    if not log.get("success"):
        err = (log.get("stderr") or "")[-1500:]
        for v in env_vals:
            err = err.replace(v, "<redacted>")
        print(f"  stage {log.get('stage')}: {err}")
sys.exit(0 if u.get("success") else 1)
PY
sleep 20
PVE 'pct exec 104 -- docker ps --filter name=^renovate$ --format "{{.Names}}: {{.Status}}"'
exit $rc
