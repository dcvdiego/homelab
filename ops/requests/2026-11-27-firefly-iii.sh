# Firefly III + Data Importer (docker-compose/firefly-iii) on docker-prod:
#   https://firefly.$DOMAIN and https://firefly-importer.$DOMAIN
#
# 1. CT 101: /docker/firefly-iii/db (MariaDB; the image chowns it) and /docker/firefly-iii/upload
#    (attachments, owned by 33:33 = www-data, the user Firefly III runs as). Nightly dumps need no
#    change: scripts/db-dumps.sh finds every mariadb container by image.
# 2. DNS on both Technitium instances: firefly / firefly-importer .homelab.lan and .$DOMAIN (split DNS,
#    A only) -> 192.168.1.224 (Traefik). No Cloudflare record or tunnel rule: the *.$DOMAIN tunnel
#    wildcard already reaches Traefik, behind Cloudflare Access (like windmill).
# 3. Komodo: stack "firefly-iii" on docker-prod from git (docker-compose/firefly-iii, Pre Deploy =
#    scripts/pre-deploy-backup.sh firefly-iii), env DOMAIN (copied from the traefik stack) and
#    FIREFLY_APP_KEY, FIREFLY_STATIC_CRON_TOKEN (32 hex chars each), FIREFLY_DB_PASSWORD,
#    FIREFLY_DB_ROOT_PASSWORD (generated here, never printed). An existing stack is left alone (new DB
#    passwords would not match the initialised database, a new APP_KEY would break sessions). Deploy.
#    The provider keys (ENABLE_BANKING_*, LUNCH_FLOW_API_KEY) are added later by the owner in Komodo.
#
# After it runs (owner, docs/firefly-iii.md): register the first user at https://firefly.$DOMAIN right
# away (the first account registered becomes the owner/admin), turn on 2FA, and create the importer's
# OAuth client.
#
# Undo: Komodo -> Stacks -> firefly-iii -> Destroy, delete the stack; CT 101 `rm -r /docker/firefly-iii`;
# delete the four records on both Technitium instances (/api/zones/records/delete).
set -u
PVE() { ssh -F "$OPS_SSH_CONFIG" pve "$@"; }

echo "== 1. CT 101: directories"
if PVE 'pct exec 101 -- sh -s' <<'SH'
set -eu
mkdir -p /docker/firefly-iii/db /docker/firefly-iii/upload
chmod 700 /docker/firefly-iii
chown 33:33 /docker/firefly-iii/upload
chmod 750 /docker/firefly-iii/upload
ls -ld /docker/firefly-iii /docker/firefly-iii/db /docker/firefly-iii/upload
SH
then
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

def env_of(stack):
    env = komodo("read", "GetStack", {"stack": stack})["config"].get("environment", "")
    return dict(l.split("=", 1) for l in env.splitlines() if "=" in l and not l.lstrip().startswith("#"))

ok = True
NAME, SERVER, RUN_DIR = "firefly-iii", "docker-prod", "docker-compose/firefly-iii"
PRE = "sh ../../scripts/pre-deploy-backup.sh firefly-iii"

stacks = {s["name"] for s in komodo("read", "ListStacks", {"limit": 500})}
# DOMAIN: the one Traefik serves (its certificate covers *.$DOMAIN). Never printed.
domain = env_of("traefik").get("DOMAIN", "").strip() if "traefik" in stacks else ""
if not domain:
    sys.exit("DOMAIN: not found in the traefik stack's env; nothing changed in Komodo or DNS")

for ip, tok in (("192.168.1.248", os.environ["TECHNITIUM_TOWER_TOKEN"]),
                ("192.168.1.224", os.environ["TECHNITIUM_PROD_TOKEN"])):
    for host in ("firefly", "firefly-importer"):
        for zone, label in (("homelab.lan", f"{host}.homelab.lan"), (domain, f"{host}.$DOMAIN")):
            q = urllib.parse.urlencode({"token": tok, "zone": zone, "domain": f"{host}.{zone}", "type": "A",
                                        "ipAddress": "192.168.1.224", "ttl": 3600, "overwrite": "true"})
            try:
                st = call(f"http://{ip}:5380/api/zones/records/add?{q}").get("status")
            except Exception as e:
                st = f"error ({e.__class__.__name__})"
            print(f"technitium {ip}: {label} -> 192.168.1.224: {st}")
            # LAN and the agents box resolve through docker-tower: that one must succeed. docker-prod's
            # instance (tailnet DNS) only warns, so a rejected token there doesn't block the stack.
            if ip == "192.168.1.248":
                ok &= st == "ok"
            elif st != "ok":
                print("  WARNING: record missing on 192.168.1.224 (tailnet clients won't resolve it locally)")

if NAME in stacks:
    print("komodo: stack 'firefly-iii' already exists; config and secrets left as they are")
else:
    servers = {s["name"]: s["id"] for s in komodo("read", "ListServers", {"limit": 500})}
    if SERVER not in servers:
        sys.exit(f"komodo: server {SERVER} not found; stack not created")
    env = (f"DOMAIN={domain}\n"
           f"FIREFLY_APP_KEY={secrets.token_hex(16)}\n"            # exactly 32 chars, [0-9a-f]
           f"FIREFLY_STATIC_CRON_TOKEN={secrets.token_hex(16)}\n"  # exactly 32 chars
           f"FIREFLY_DB_PASSWORD={secrets.token_hex(24)}\n"
           f"FIREFLY_DB_ROOT_PASSWORD={secrets.token_hex(24)}\n"
           "ENABLE_BANKING_APP_ID=\nENABLE_BANKING_PRIVATE_KEY=\nLUNCH_FLOW_API_KEY=\nSIMPLEFIN_TOKEN=\n")
    config = {"server_id": servers[SERVER], "project_name": NAME,
              "git_provider": "github.com", "git_https": True, "repo": "dcvdiego/homelab", "branch": "main",
              "run_directory": RUN_DIR, "file_paths": ["docker-compose.yml"],
              "env_file_path": ".env", "environment": env,
              "pre_deploy": {"path": "", "command": PRE},
              "auto_pull": False, "webhook_enabled": False, "send_alerts": True}
    komodo("write", "CreateStack", {"name": NAME, "config": config})
    got = komodo("read", "GetStack", {"stack": NAME})["config"]
    good = (got.get("run_directory") == RUN_DIR and (got.get("pre_deploy") or {}).get("command") == PRE
            and all(f"{k}=" in got.get("environment", "") for k in
                    ("FIREFLY_APP_KEY", "FIREFLY_STATIC_CRON_TOKEN", "FIREFLY_DB_PASSWORD", "FIREFLY_DB_ROOT_PASSWORD")))
    print(f"komodo: stack 'firefly-iii' created: {'ok' if good else 'FAILED (config reads back different)'}")
    if not good:
        sys.exit(1)

# First deploy: the pre-deploy skips (nothing running yet). Allow 20 min for the image pulls.
uid = komodo("execute", "DeployStack", {"stack": NAME}, timeout=300)["_id"]["$oid"]
u = {}
for _ in range(240):
    u = komodo("read", "GetUpdate", {"id": uid})
    if u.get("status") == "Complete":
        break
    time.sleep(5)
print(f"komodo: deploy firefly-iii: {'ok' if u.get('success') else 'FAILED'}")
# Failed stages: name and error tail only, every stack env value redacted (results are agent-readable)
vals = [v.strip() for v in env_of(NAME).values() if len(v.strip()) >= 4]
for log in u.get("logs", []):
    if not log.get("success"):
        err = (log.get("stderr") or "")[-1500:]
        for v in vals:
            err = err.replace(v, "<redacted>")
        print(f"  stage {log.get('stage')}: {err}")
ok &= bool(u.get("success"))

fd = os.open("/tmp/firefly-domain", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, domain.encode()); os.close(fd)
sys.exit(0 if ok else 1)
PY

echo "== 4. Reachable through Traefik"
D=$(cat /tmp/firefly-domain); rm -f /tmp/firefly-domain
# First start runs the migrations: allow 5 min. Forced IPv4 + --resolve: never out through Cloudflare.
for host in firefly firefly-importer; do
  code=000
  for _ in $(seq 1 60); do
    code=$(curl -4 -sS -o /dev/null -w '%{http_code}' --max-time 10 \
             --resolve "$host.$D:443:192.168.1.224" "https://$host.$D/" 2>/dev/null) || code=000
    case "$code" in 2*|3*) break ;; esac
    sleep 5
  done
  echo "$host.\$DOMAIN: HTTP $code"
done
PVE 'pct exec 101 -- docker ps --filter name=firefly-iii --format "{{.Names}}: {{.Status}}"'
