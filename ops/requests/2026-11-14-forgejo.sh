# Forgejo (docker-compose/forgejo) on docker-tower, and the private repo diego/homelab-private in it.
# Phases 1 and 2a of docs/forgejo-split.md.
#
# 1. CT 104: /docker/forgejo/{data,runner}, owned by uid/gid 1000 (both images run as 1000).
# 2. DNS: git.homelab.lan -> 192.168.1.248 on both Technitium instances. No Cloudflare record or
#    tunnel rule: Forgejo is LAN only.
# 3. Komodo: stack "forgejo" on docker-tower from git (docker-compose/forgejo, Pre Deploy =
#    scripts/pre-deploy-backup.sh forgejo), env FORGEJO_SECRET_KEY generated here (never printed). If
#    the stack exists it is left alone (a new secret key would break sessions and stored 2FA). Deploy.
# 4. Users (forgejo admin CLI inside the container): diego (admin), homelabsito (agents, write on
#    homelab-private, no merge), renovate-bot (Renovate, Phase 3). diego's random initial password goes to
#    /root/forgejo-initial-password on CT 104 (mode 600, never printed); change it at first sign-in.
#    Bots get no usable password (random, discarded): they use tokens.
# 5. Repo diego/homelab-private (private): main of dcvdiego/homelab pushed with full history (branches
#    other than main and GitHub's refs/pull/* are not copied). Branch protection on main: only diego
#    pushes or merges. homelabsito added as a write collaborator.
# 6. homelabsito token (scopes write:repository, write:issue, read:user) installed on the agents box
#    (CT 102) at /home/diego/.config/homelab/forgejo-token (mode 600, owner diego). Never printed.
# 7. Runner: registered offline with scope diego/homelab-private and label homelab-private-ci (host
#    executor); config written to /docker/forgejo/runner/config.yml (mode 600); runner restarted.
#
# Leaves behind an admin token "ops-setup" for diego: delete it in Forgejo (Settings > Applications)
# after Phase 4 of docs/forgejo-split.md, it is only needed until then.
#
# Undo: Komodo -> Stacks -> forgejo -> Destroy, delete the stack; CT 104 `rm -r /docker/forgejo
# /root/forgejo-initial-password`; CT 102 `rm /home/diego/.config/homelab/forgejo-token`; delete
# git.homelab.lan on both Technitium instances (/api/zones/records/delete). Nothing else uses Forgejo
# until Phase 4 repoints stacks to it.
set -u
PVE() { ssh -F "$OPS_SSH_CONFIG" pve "$@"; }
FJ() { PVE "pct exec 104 -- docker exec -u 1000 forgejo forgejo $*"; }   # forgejo CLI in the container
rc=0

echo "== 1. CT 104: directories"
if PVE 'pct exec 104 -- sh -c "set -e; mkdir -p /docker/forgejo/data /docker/forgejo/runner
        chown 1000:1000 /docker/forgejo/data /docker/forgejo/runner; chmod 700 /docker/forgejo/runner
        ls -ld /docker/forgejo/data /docker/forgejo/runner"'; then
  echo "dirs: ok"
else
  echo "dirs: FAILED"; exit 1
fi

echo "== 2+3. DNS, Komodo stack, deploy"
python3 - <<'PY' || exit 1
import json, os, secrets, sys, time, urllib.parse, urllib.request

def call(url, data=None, headers=None, method=None, timeout=60):
    req = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read() or "null")

def komodo(kind, typ, params, timeout=60):
    return call(f"{os.environ['KOMODO_URL']}/{kind}/{typ}", json.dumps(params).encode(),
                {"Content-Type": "application/json", "x-api-key": os.environ["KOMODO_API_KEY"],
                 "x-api-secret": os.environ["KOMODO_API_SECRET"]}, "POST", timeout)

ok = True
NAME, SERVER, RUN_DIR = "forgejo", "docker-tower", "docker-compose/forgejo"
PRE = "sh ../../scripts/pre-deploy-backup.sh forgejo"

for ip, tok in (("192.168.1.248", os.environ["TECHNITIUM_TOWER_TOKEN"]),
                ("192.168.1.224", os.environ["TECHNITIUM_PROD_TOKEN"])):
    q = urllib.parse.urlencode({"token": tok, "zone": "homelab.lan", "domain": "git.homelab.lan", "type": "A",
                                "ipAddress": "192.168.1.248", "ttl": 3600, "overwrite": "true"})
    try:
        st = call(f"http://{ip}:5380/api/zones/records/add?{q}").get("status")
    except Exception as e:
        st = f"error ({e.__class__.__name__})"
    print(f"technitium {ip}: git.homelab.lan -> 192.168.1.248: {st}")
    ok &= st == "ok"

existing = {s["name"] for s in komodo("read", "ListStacks", {"limit": 500})}
if NAME in existing:
    print("komodo: stack 'forgejo' already exists; config and secret key left as they are")
else:
    servers = {s["name"]: s["id"] for s in komodo("read", "ListServers", {"limit": 500})}
    if SERVER not in servers:
        sys.exit(f"komodo: server {SERVER} not found; stack not created")
    config = {"server_id": servers[SERVER], "project_name": NAME,
              "git_provider": "github.com", "git_https": True, "repo": "dcvdiego/homelab", "branch": "main",
              "run_directory": RUN_DIR, "file_paths": ["docker-compose.yml"],
              "env_file_path": ".env", "environment": f"FORGEJO_SECRET_KEY={secrets.token_hex(32)}\n",
              "pre_deploy": {"path": "", "command": PRE},
              "auto_pull": False, "webhook_enabled": False, "send_alerts": True}
    komodo("write", "CreateStack", {"name": NAME, "config": config})
    got = komodo("read", "GetStack", {"stack": NAME})["config"]
    good = (got.get("run_directory") == RUN_DIR and (got.get("pre_deploy") or {}).get("command") == PRE
            and "FORGEJO_SECRET_KEY=" in got.get("environment", ""))
    print(f"komodo: stack 'forgejo' created: {'ok' if good else 'FAILED (config reads back different)'}")
    if not good:
        sys.exit(1)

# First deploy: pre-deploy finds nothing to back up yet (files skips a missing/empty path is fine)
uid = komodo("execute", "DeployStack", {"stack": NAME}, timeout=300)["_id"]["$oid"]
u = {}
for _ in range(180):
    u = komodo("read", "GetUpdate", {"id": uid})
    if u.get("status") == "Complete":
        break
    time.sleep(5)
print(f"komodo: deploy forgejo: {'ok' if u.get('success') else 'FAILED'}")
for log in u.get("logs", []):
    if not log.get("success"):
        print(f"  stage {log.get('stage')}: {(log.get('stderr') or '')[-1500:]}")
ok &= bool(u.get("success"))

# Wait for the web server
for _ in range(36):
    try:
        urllib.request.urlopen("http://192.168.1.248:3200/api/healthz", timeout=5); print("forgejo: healthy"); break
    except Exception:
        time.sleep(5)
else:
    print("forgejo: not healthy after 3 min"); ok = False
sys.exit(0 if ok else 1)
PY

echo "== 4. Users"
users=$(FJ admin user list 2>/dev/null) || { echo "users: FAILED (cannot run the forgejo CLI)"; exit 1; }
for u in diego homelabsito renovate-bot; do
  if printf '%s\n' "$users" | awk 'NR>1 {print $2}' | grep -qx "$u"; then
    echo "user $u: exists (left as is)"; continue
  fi
  if [ "$u" = diego ]; then
    # Password captured on pvehost and written straight to a root-only file in CT 104
    if PVE 'set -e; umask 077
            out=$(pct exec 104 -- docker exec -u 1000 forgejo forgejo admin user create --admin \
                  --username diego --email diego@homelab.lan --random-password --random-password-length 24 \
                  --must-change-password)
            printf "%s\n" "$out" | sed -n "s/.*random password is .\(.*\).$/\1/p" | tail -n 1 > /root/fj-pw
            [ -s /root/fj-pw ]
            pct push 104 /root/fj-pw /root/forgejo-initial-password --perms 600 --user 0 --group 0
            rm -f /root/fj-pw'; then
      echo "user diego: created (admin); initial password in CT 104 /root/forgejo-initial-password"
    else
      echo "user diego: FAILED"; exit 1
    fi
  else
    if FJ admin user create --username "$u" --email "$u@homelab.lan" --random-password \
         --random-password-length 32 --must-change-password=false >/dev/null; then
      echo "user $u: created"
    else
      echo "user $u: FAILED"; rc=1
    fi
  fi
done

echo "== 5+6+7. Repo, protection, bot token, runner"
ADMIN_TOKEN=$(FJ admin user generate-access-token -u diego -t "ops-setup-$(date +%s)" --scopes all --raw 2>/dev/null)
BOT_TOKEN=$(FJ admin user generate-access-token -u homelabsito -t "agents-box-$(date +%s)" \
              --scopes write:repository,write:issue,read:user --raw 2>/dev/null)
[ -n "$ADMIN_TOKEN" ] && [ -n "$BOT_TOKEN" ] || { echo "tokens: FAILED"; exit 1; }
export ADMIN_TOKEN BOT_TOKEN
FJURL=http://192.168.1.248:3200

python3 - <<'PY' || rc=1
import json, os, subprocess, sys, tempfile, urllib.error, urllib.request
API = "http://192.168.1.248:3200/api/v1"
H = {"Authorization": f"token {os.environ['ADMIN_TOKEN']}", "Content-Type": "application/json"}

def api(method, path, body=None):
    req = urllib.request.Request(API + path, json.dumps(body).encode() if body is not None else None, H, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.loads(r.read() or "null")
    except urllib.error.HTTPError as e:
        return e.code, None

ok = True
st, _ = api("GET", "/repos/diego/homelab-private")
if st == 200:
    print("repo: exists (history left as is)")
else:
    st, _ = api("POST", "/user/repos", {"name": "homelab-private", "private": True, "default_branch": "main",
                                        "description": "Sensitive stacks split from dcvdiego/homelab (docs/forgejo-split.md)"})
    print(f"repo: created: {st}"); ok &= st == 201
    # Full history of main. Token via GIT_CONFIG_* env, never on argv or in a URL.
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0", GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="http.extraHeader",
               GIT_CONFIG_VALUE_0=f"Authorization: token {os.environ['ADMIN_TOKEN']}")
    with tempfile.TemporaryDirectory() as d:
        r1 = subprocess.run(["git", "clone", "-q", "--bare", "--single-branch", "--branch", "main",
                             "https://github.com/dcvdiego/homelab", d], capture_output=True)
        r2 = subprocess.run(["git", "-C", d, "push", "-q", "http://192.168.1.248:3200/diego/homelab-private.git",
                             "main:main"], env=env, capture_output=True) if r1.returncode == 0 else r1
    print(f"repo: history pushed: {'ok' if r2.returncode == 0 else 'FAILED'}"); ok &= r2.returncode == 0

st, rules = api("GET", "/repos/diego/homelab-private/branch_protections")
if st == 200 and any(r.get("rule_name") == "main" for r in rules or []):
    print("branch protection main: exists (left as is)")
else:
    st, _ = api("POST", "/repos/diego/homelab-private/branch_protections", {
        "rule_name": "main", "enable_push": True, "enable_push_whitelist": True,
        "push_whitelist_usernames": ["diego"], "enable_merge_whitelist": True,
        "merge_whitelist_usernames": ["diego"], "block_on_rejected_reviews": True})
    print(f"branch protection main: {st}"); ok &= st == 201

st, _ = api("PUT", "/repos/diego/homelab-private/collaborators/homelabsito", {"permission": "write"})
print(f"collaborator homelabsito (write): {st}"); ok &= st == 204
sys.exit(0 if ok else 1)
PY

# Bot token -> agents box, via pvehost (written root-only there first, removed after the push)
if printf '%s\n' "$BOT_TOKEN" | PVE 'set -e; umask 077; cat > /root/fj-bot
       pct push 102 /root/fj-bot /home/diego/.config/homelab/forgejo-token --perms 600 \
         --user "$(pct exec 102 -- id -u diego)" --group "$(pct exec 102 -- id -g diego)"
       rm -f /root/fj-bot'; then
  echo "bot token: installed on agents box"
else
  echo "bot token: FAILED"; rc=1
fi

# Runner: offline registration (https://forgejo.org/docs/latest/admin/actions/registration/).
# uuid = the command's output, token = the 40-hex secret. Secret read from a file, not argv.
if PVE 'pct exec 104 -- test -s /docker/forgejo/runner/config.yml'; then
  echo "runner: config exists (left as is)"
else
  SECRET=$(python3 -c 'import secrets; print(secrets.token_hex(20))')
  RUNNER_UUID=$(printf '%s' "$SECRET" | PVE 'set -e; umask 077; cat > /root/fj-rs
      pct push 104 /root/fj-rs /docker/forgejo/data/tmp-runner-secret --perms 600 --user 1000 --group 1000
      rm -f /root/fj-rs
      pct exec 104 -- docker exec -u 1000 forgejo forgejo forgejo-cli actions register \
        --name forgejo-runner --scope diego/homelab-private --labels homelab-private-ci \
        --secret-file /var/lib/gitea/tmp-runner-secret
      pct exec 104 -- rm -f /docker/forgejo/data/tmp-runner-secret' | tail -n 1)
  case "$RUNNER_UUID" in
    *-*-*-*-*) ;;
    *) echo "runner: registration FAILED"; exit 1 ;;
  esac
  CONF="log:
  level: info
runner:
  file: .runner
  capacity: 1
  timeout: 30m
  labels:
    - homelab-private-ci:host
host:
  workdir_parent: /data/work
server:
  connections:
    forgejo:
      url: http://forgejo:3000/
      uuid: $RUNNER_UUID
      token: $SECRET"
  if printf '%s\n' "$CONF" | PVE 'set -e; umask 077; cat > /root/fj-rc
       pct push 104 /root/fj-rc /docker/forgejo/runner/config.yml --perms 600 --user 1000 --group 1000
       rm -f /root/fj-rc'; then
    echo "runner: registered (scope diego/homelab-private, label homelab-private-ci), config written"
  else
    echo "runner: config FAILED"; rc=1
  fi
fi
sleep 45   # the runner container polls for config.yml every 30s
PVE 'pct exec 104 -- docker ps --filter name=forgejo --format "{{.Names}}: {{.Status}}"'
# The runner's own log never contains the token; the tail shows whether it connected
PVE 'pct exec 104 -- docker logs --tail 5 forgejo-runner 2>&1' | cut -c1-200

exit $rc
