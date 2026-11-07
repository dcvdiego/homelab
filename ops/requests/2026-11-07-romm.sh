# Install RomM (docker-compose/romm) on docker-prod as a new Komodo stack.
#
# 1. CT 101: create the bind-mount dirs (owned by uid/gid 1000, the image's `romm` user; the DB dir is
#    left to MariaDB's entrypoint):
#      /data/romm/library/{roms,bios}  ROM library, Structure A from the RomM docs (16TB HDD)
#      /data/romm/resources            covers/screenshots (re-downloadable)
#      /docker/romm/{assets,config,redis-data,mysql}  saves/states, config.yml, Valkey, MariaDB
# 2. CT 101: install this commit's scripts/db-dumps.sh at /docker/scripts/db-dumps.sh (adds romm-db
#    to the nightly dumps). The old one is kept as db-dumps.sh.bak-2026-11-07.
# 3. DNS: romm.homelab.lan and romm.$DOMAIN (split DNS) -> 192.168.1.224 on both Technitium
#    instances. Cloudflare: a proxied CNAME and a tunnel ingress rule for romm.$DOMAIN, only if
#    neither an exact nor a wildcard (*.$DOMAIN) entry already covers it.
# 4. Komodo: create stack "romm" on docker-prod from git (docker-compose/romm, project "romm",
#    auto_pull off, Pre Deploy = scripts/pre-deploy-backup.sh romm). Its env gets DOMAIN (copied from
#    the notes stack) and three secrets generated here (ROMM_AUTH_SECRET_KEY, ROMM_DB_PASSWORD,
#    ROMM_DB_ROOT_PASSWORD: 32 random bytes, hex, like `openssl rand -hex 32`), plus empty metadata
#    provider keys for the owner to fill in. Secrets are never printed. If the stack already exists it
#    is left alone (regenerating the DB password would lock RomM out of its database).
# 5. Deploy the stack and report the result.
#
# Undo: Komodo -> Stacks -> romm -> Destroy, then delete the stack; in CT 101
# `rm -r /docker/romm /data/romm` (only if no ROMs were added) and
# `mv /docker/scripts/db-dumps.sh.bak-2026-11-07 /docker/scripts/db-dumps.sh`; delete the DNS records
# (Technitium /api/zones/records/delete; Cloudflare record + ingress rule, if this created them).
set -u
PVE() { ssh -F "$OPS_SSH_CONFIG" pve "$@"; }
rc=0

echo "== 1. CT 101: directories"
if PVE 'pct exec 101 -- sh -c "
      set -e
      mkdir -p /data/romm/library/roms /data/romm/library/bios /data/romm/resources \
               /docker/romm/assets /docker/romm/config /docker/romm/redis-data /docker/romm/mysql
      chown 1000:1000 /data/romm /data/romm/library /data/romm/library/roms /data/romm/library/bios \
                      /data/romm/resources /docker/romm/assets /docker/romm/config /docker/romm/redis-data
      ls -ld /data/romm/library/roms /data/romm/library/bios /data/romm/resources /docker/romm/*"'; then
  echo "dirs: ok"
else
  echo "dirs: FAILED"; exit 1   # deploying without them would let Docker create root-owned dirs
fi

echo "== 2. CT 101: db-dumps.sh"
if PVE 'cat > /root/db-dumps.sh' < scripts/db-dumps.sh \
   && PVE 'set -e
           pct exec 101 -- sh -c "[ ! -e /docker/scripts/db-dumps.sh ] || [ -e /docker/scripts/db-dumps.sh.bak-2026-11-07 ] || cp -p /docker/scripts/db-dumps.sh /docker/scripts/db-dumps.sh.bak-2026-11-07"
           pct push 101 /root/db-dumps.sh /docker/scripts/db-dumps.sh --perms 700 --user 0 --group 0
           rm -f /root/db-dumps.sh
           pct exec 101 -- bash -n /docker/scripts/db-dumps.sh
           pct exec 101 -- grep -c romm-db /docker/scripts/db-dumps.sh'; then
  echo "db-dumps: ok"
else
  echo "db-dumps: FAILED"; rc=1
fi

echo "== 3+4+5. DNS, Komodo stack, deploy"
python3 - <<'PY' || rc=1
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
NAME, SERVER, RUN_DIR = "romm", "docker-prod", "docker-compose/romm"
PRE = "sh ../../scripts/pre-deploy-backup.sh romm"

# DOMAIN from an existing stack's env (never printed)
notes_env = komodo("read", "GetStack", {"stack": "notes"})["config"].get("environment", "")
domain = next((l.split("=", 1)[1].strip().strip('"') for l in notes_env.splitlines()
               if l.strip().startswith("DOMAIN=")), "")
if not domain:
    sys.exit("DOMAIN not found in the notes stack env; nothing changed")
host = f"romm.{domain}"
print("public name: romm.<DOMAIN>")

# --- 3a. Technitium (both instances)
for ip, tok in (("192.168.1.248", os.environ["TECHNITIUM_TOWER_TOKEN"]),
                ("192.168.1.224", os.environ["TECHNITIUM_PROD_TOKEN"])):
    for zone, name in (("homelab.lan", "romm.homelab.lan"), (domain, host)):
        q = urllib.parse.urlencode({"token": tok, "zone": zone, "domain": name, "type": "A",
                                    "ipAddress": "192.168.1.224", "ttl": 3600, "overwrite": "true"})
        try:
            st = call(f"http://{ip}:5380/api/zones/records/add?{q}").get("status")
        except Exception as e:
            st = f"error ({e.__class__.__name__})"
        label = name.replace(domain, "<DOMAIN>")
        print(f"technitium {ip}: {label} -> 192.168.1.224: {st}")
        ok &= st == "ok"

# --- 3b. Cloudflare (read before write)
cf = {"Authorization": f"Bearer {os.environ['CF_TOKEN']}", "Content-Type": "application/json"}
zone, acct, tun = os.environ["CF_ZONE"], os.environ["CF_ACCOUNT"], os.environ["CF_TUNNEL"]
api = "https://api.cloudflare.com/client/v4"
try:
    recs = [r for n in (host, f"*.{domain}") for r in
            call(f"{api}/zones/{zone}/dns_records?{urllib.parse.urlencode({'name': n})}", headers=cf)["result"]]
    if recs:
        print(f"cloudflare dns: already covered ({', '.join(r['name'].replace(domain, '<DOMAIN>') for r in recs)})")
    else:
        r = call(f"{api}/zones/{zone}/dns_records", json.dumps({"type": "CNAME", "name": host,
                 "content": f"{tun}.cfargotunnel.com", "proxied": True}).encode(), cf, "POST")
        print(f"cloudflare dns: CNAME created: {r.get('success')}"); ok &= bool(r.get("success"))

    cfg = call(f"{api}/accounts/{acct}/cfd_tunnel/{tun}/configurations", headers=cf)["result"]["config"]
    ingress = cfg.get("ingress", [])
    covered = [i.get("hostname") for i in ingress if i.get("hostname") in (host, f"*.{domain}")]
    if covered:
        print(f"cloudflare tunnel: already covered ({', '.join(h.replace(domain, '<DOMAIN>') for h in covered)})")
    elif not ingress or "hostname" in ingress[-1]:
        print("cloudflare tunnel: SKIPPED, ingress has no catch-all last rule (left as is)"); ok = False
    else:
        ingress.insert(len(ingress) - 1, {"hostname": host, "service": "https://traefik",
                                          "originRequest": {"noTLSVerify": True}})
        cfg["ingress"] = ingress
        r = call(f"{api}/accounts/{acct}/cfd_tunnel/{tun}/configurations",
                 json.dumps({"config": cfg}).encode(), cf, "PUT")
        print(f"cloudflare tunnel: rule added: {r.get('success')}"); ok &= bool(r.get("success"))
except Exception as e:
    print(f"cloudflare: FAILED ({e.__class__.__name__})"); ok = False

# --- 4. Komodo stack
existing = {s["name"]: s for s in komodo("read", "ListStacks", {"limit": 500})}
if NAME in existing:
    print("komodo: stack 'romm' already exists; config and secrets left as they are")
else:
    servers = {s["name"]: s["id"] for s in komodo("read", "ListServers", {"limit": 500})}
    if SERVER not in servers:
        sys.exit(f"komodo: server {SERVER} not found; stack not created")
    env = "\n".join([
        f"DOMAIN={domain}",
        f"ROMM_AUTH_SECRET_KEY={secrets.token_hex(32)}",
        f"ROMM_DB_PASSWORD={secrets.token_hex(32)}",
        f"ROMM_DB_ROOT_PASSWORD={secrets.token_hex(32)}",
        "SCREENSCRAPER_USER=", "SCREENSCRAPER_PASSWORD=", "RETROACHIEVEMENTS_API_KEY=",
        "STEAMGRIDDB_API_KEY=", "IGDB_CLIENT_ID=", "IGDB_CLIENT_SECRET=",
    ]) + "\n"
    config = {"server_id": servers[SERVER], "project_name": NAME,
              "git_provider": "github.com", "git_https": True, "repo": "dcvdiego/homelab", "branch": "main",
              "run_directory": RUN_DIR, "file_paths": ["docker-compose.yml"],
              "env_file_path": ".env", "environment": env,
              "pre_deploy": {"path": "", "command": PRE},
              "auto_pull": False, "webhook_enabled": False, "send_alerts": True}
    komodo("write", "CreateStack", {"name": NAME, "config": config})
    got = komodo("read", "GetStack", {"stack": NAME})["config"]
    good = (got.get("run_directory") == RUN_DIR and (got.get("pre_deploy") or {}).get("command") == PRE
            and "ROMM_DB_PASSWORD=" in got.get("environment", ""))
    print(f"komodo: stack 'romm' created: {'ok' if good else 'FAILED (config reads back different)'}")
    if not good:
        sys.exit(1)

# --- 5. Deploy (pulls the pinned images: they aren't on the host yet)
uid = komodo("execute", "DeployStack", {"stack": NAME}, timeout=300)["_id"]["$oid"]
u = {}
for _ in range(180):
    u = komodo("read", "GetUpdate", {"id": uid})
    if u.get("status") == "Complete":
        break
    time.sleep(5)
print(f"komodo: deploy romm: {'ok' if u.get('success') else 'FAILED'}")
for log in u.get("logs", []):
    if not log.get("success"):
        # stage names and the error tail only; env values never appear in compose output
        print(f"  stage {log.get('stage')}: {(log.get('stderr') or '')[-1500:]}")
ok &= bool(u.get("success"))
sys.exit(0 if ok else 1)
PY

exit $rc
