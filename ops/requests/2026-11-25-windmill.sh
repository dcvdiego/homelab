# Windmill (docker-compose/windmill) on docker-prod: https://windmill.$DOMAIN
#
# 1. CT 101: /docker/windmill/db (Postgres data; root 700, the postgres image chowns its own subdir).
#    Install this commit's scripts/db-dumps.sh (adds windmill-db to the nightly dumps); the current one
#    is kept as /docker/scripts/db-dumps.sh.bak-2026-11-25.
# 2. DNS on both Technitium instances: windmill.homelab.lan and windmill.$DOMAIN (split DNS, A only)
#    -> 192.168.1.224 (Traefik). No Cloudflare record or tunnel rule: the *.$DOMAIN tunnel wildcard
#    already reaches Traefik, behind Cloudflare Access (like frigate, zigbee2mqtt).
# 3. Komodo: stack "windmill" on docker-prod from git (docker-compose/windmill, Pre Deploy =
#    scripts/pre-deploy-backup.sh windmill), env DOMAIN (copied from the traefik stack, never printed)
#    and WINDMILL_DB_PASSWORD (generated here, never printed). An existing stack is left alone (a new DB
#    password would not match the initialised cluster). Deploy.
# 4. Instance setting Base Url = https://windmill.$DOMAIN (the docs' reverse-proxy step).
#    Windmill ships a superadmin admin@windmill.dev / changeme. Right after the first start its password
#    is replaced by a random one, written to /root/windmill-initial-password in CT 101 (mode 600, never
#    printed), so the default login never works on this instance. Skipped if changeme no longer works.
#
# Undo: Komodo -> Stacks -> windmill -> Destroy, delete the stack; CT 101 `rm -r /docker/windmill
# /root/windmill-initial-password` and `mv /docker/scripts/db-dumps.sh.bak-2026-11-25
# /docker/scripts/db-dumps.sh`; delete both records on both Technitium instances
# (/api/zones/records/delete). Named volumes: `docker volume rm windmill_worker_dependency_cache
# windmill_worker_logs windmill_windmill_index windmill_lsp_cache`.
set -u
PVE() { ssh -F "$OPS_SSH_CONFIG" pve "$@"; }

echo "== 1. CT 101: directory, db-dumps.sh"
if PVE 'pct exec 101 -- sh -c "set -e; mkdir -p /docker/windmill/db; chmod 700 /docker/windmill /docker/windmill/db
        ls -ld /docker/windmill/db"'; then
  echo "dirs: ok"
else
  echo "dirs: FAILED"; exit 1
fi
if PVE 'set -e; umask 077; cat > /root/db-dumps.sh' < scripts/db-dumps.sh \
   && PVE 'set -e
           pct exec 101 -- sh -c "[ -e /docker/scripts/db-dumps.sh.bak-2026-11-25 ] || cp -p /docker/scripts/db-dumps.sh /docker/scripts/db-dumps.sh.bak-2026-11-25"
           pct push 101 /root/db-dumps.sh /docker/scripts/db-dumps.sh.new --perms 700 --user 0 --group 0
           rm -f /root/db-dumps.sh
           pct exec 101 -- bash -n /docker/scripts/db-dumps.sh.new
           pct exec 101 -- mv /docker/scripts/db-dumps.sh.new /docker/scripts/db-dumps.sh'; then
  echo "db-dumps.sh: installed (windmill-db added)"
else
  echo "db-dumps.sh: FAILED (previous script left in place)"; exit 1
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

def env_of(stack):
    env = komodo("read", "GetStack", {"stack": stack})["config"].get("environment", "")
    return dict(l.split("=", 1) for l in env.splitlines() if "=" in l and not l.lstrip().startswith("#"))

ok = True
NAME, SERVER, RUN_DIR = "windmill", "docker-prod", "docker-compose/windmill"
PRE = "sh ../../scripts/pre-deploy-backup.sh windmill"

stacks = {s["name"] for s in komodo("read", "ListStacks", {"limit": 500})}
# DOMAIN: the one Traefik serves (its certificate covers *.$DOMAIN). Never printed.
domain = env_of("traefik").get("DOMAIN", "").strip() if "traefik" in stacks else ""
if not domain:
    sys.exit("DOMAIN: not found in the traefik stack's env; nothing changed in Komodo or DNS")

for ip, tok in (("192.168.1.248", os.environ["TECHNITIUM_TOWER_TOKEN"]),
                ("192.168.1.224", os.environ["TECHNITIUM_PROD_TOKEN"])):
    for zone, label in (("homelab.lan", "windmill.homelab.lan"), (domain, "windmill.$DOMAIN")):
        q = urllib.parse.urlencode({"token": tok, "zone": zone, "domain": f"windmill.{zone}", "type": "A",
                                    "ipAddress": "192.168.1.224", "ttl": 3600, "overwrite": "true"})
        try:
            st = call(f"http://{ip}:5380/api/zones/records/add?{q}").get("status")
        except Exception as e:
            st = f"error ({e.__class__.__name__})"
        print(f"technitium {ip}: {label} -> 192.168.1.224: {st}")
        # The agents box and LAN resolve through docker-tower: that one must succeed. docker-prod's
        # instance (tailnet DNS) only warns, so a rejected token there doesn't block the stack.
        if ip == "192.168.1.248":
            ok &= st == "ok"
        elif st != "ok":
            print("  WARNING: record missing on 192.168.1.224 (tailnet clients won't resolve it locally)")

if NAME in stacks:
    print("komodo: stack 'windmill' already exists; config and DB password left as they are")
else:
    servers = {s["name"]: s["id"] for s in komodo("read", "ListServers", {"limit": 500})}
    if SERVER not in servers:
        sys.exit(f"komodo: server {SERVER} not found; stack not created")
    config = {"server_id": servers[SERVER], "project_name": NAME,
              "git_provider": "github.com", "git_https": True, "repo": "dcvdiego/homelab", "branch": "main",
              "run_directory": RUN_DIR, "file_paths": ["docker-compose.yml"],
              "env_file_path": ".env",
              "environment": f"DOMAIN={domain}\nWINDMILL_DB_PASSWORD={secrets.token_hex(24)}\n",
              "pre_deploy": {"path": "", "command": PRE},
              "auto_pull": False, "webhook_enabled": False, "send_alerts": True}
    komodo("write", "CreateStack", {"name": NAME, "config": config})
    got = komodo("read", "GetStack", {"stack": NAME})["config"]
    good = (got.get("run_directory") == RUN_DIR and (got.get("pre_deploy") or {}).get("command") == PRE
            and "WINDMILL_DB_PASSWORD=" in got.get("environment", ""))
    print(f"komodo: stack 'windmill' created: {'ok' if good else 'FAILED (config reads back different)'}")
    if not good:
        sys.exit(1)

# First deploy: the pre-deploy skips windmill-db (not running yet). Images are ~1.5 GB: allow 20 min.
uid = komodo("execute", "DeployStack", {"stack": NAME}, timeout=300)["_id"]["$oid"]
u = {}
for _ in range(240):
    u = komodo("read", "GetUpdate", {"id": uid})
    if u.get("status") == "Complete":
        break
    time.sleep(5)
print(f"komodo: deploy windmill: {'ok' if u.get('success') else 'FAILED'}")
# Failed stages: name and error tail only, every stack env value redacted (results are agent-readable)
vals = [v.strip() for v in env_of(NAME).values() if len(v.strip()) >= 4]
for log in u.get("logs", []):
    if not log.get("success"):
        err = (log.get("stderr") or "")[-1500:]
        for v in vals:
            err = err.replace(v, "<redacted>")
        print(f"  stage {log.get('stage')}: {err}")
ok &= bool(u.get("success"))

# Hand the domain to step 4 through a root-only file (not argv, not output)
fd = os.open("/tmp/windmill-domain", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, domain.encode()); os.close(fd)
sys.exit(0 if ok else 1)
PY

echo "== 4. Default superadmin password"
# Through Traefik on docker-prod (forced IPv4 + --resolve: never out through Cloudflare)
D=$(cat /tmp/windmill-domain); rm -f /tmp/windmill-domain
W="https://windmill.$D"
CURL() { curl -4 -fsS --max-time 20 --resolve "windmill.$D:443:192.168.1.224" "$@"; }
up=no
for _ in $(seq 1 60); do
  if CURL -o /dev/null "$W/api/version"; then up=yes; break; fi
  sleep 5
done
[ "$up" = yes ] && echo "windmill: up ($(CURL "$W/api/version"))" || { echo "windmill: not reachable through Traefik after 5 min"; exit 1; }

TOKEN=$(CURL -X POST -H 'Content-Type: application/json' \
          -d '{"email":"admin@windmill.dev","password":"changeme"}' "$W/api/auth/login" 2>/dev/null) || TOKEN=
if [ -z "$TOKEN" ]; then
  echo "superadmin: default login (admin@windmill.dev / changeme) refused: already changed; password and Base Url left as they are"
  exit 0
fi
NEWPW=$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')
# Save it in CT 101 first, so a set password is never one nobody has. Token and body go through
# root-only files (curl -H @file / --data-binary @file), never argv.
if ! printf '%s\n' "$NEWPW" | PVE 'set -e; umask 077; cat > /root/wm-pw
       pct push 101 /root/wm-pw /root/windmill-initial-password --perms 600 --user 0 --group 0
       rm -f /root/wm-pw'; then
  echo "superadmin: could not save a new password in CT 101; default left: change it at first sign-in"
  exit 1
fi
umask 077
trap 'rm -f /tmp/wm-auth /tmp/wm-body' EXIT
printf 'Authorization: Bearer %s\n' "$TOKEN" > /tmp/wm-auth
printf '{"password":"%s"}' "$NEWPW" > /tmp/wm-body
# Base Url (Instance settings > Core): the docs' one setting for running behind a reverse proxy
# (links in emails, webhooks, OAuth redirects). Not secret, but holds the domain: not printed.
if CURL -X POST -H 'Content-Type: application/json' -H @/tmp/wm-auth \
     -d "{\"value\":\"$W\"}" -o /dev/null "$W/api/settings/global/base_url"; then
  echo "instance setting base_url: set to https://windmill.\$DOMAIN"
else
  echo "instance setting base_url: FAILED (set it in Instance settings > Core > Base Url)"
fi
if CURL -X POST -H 'Content-Type: application/json' -H @/tmp/wm-auth --data-binary @/tmp/wm-body \
     -o /dev/null "$W/api/users/setpassword"; then
  echo "superadmin admin@windmill.dev: password replaced; it's in CT 101 /root/windmill-initial-password"
else
  PVE 'pct exec 101 -- rm -f /root/windmill-initial-password'
  echo "superadmin: setpassword FAILED (default password still active: change it at first sign-in)"
  exit 1
fi
CURL -X POST -H @/tmp/wm-auth -o /dev/null "$W/api/auth/logout" || true
PVE 'pct exec 101 -- docker ps --filter name=windmill --format "{{.Names}}: {{.Status}}"'
