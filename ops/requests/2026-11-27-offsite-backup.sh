# Off-site encrypted backups: rustic + rclone (docker-compose/offsite-backup) on docker-prod.
# docs/backups.md#off-site-rustic--rclone has what is backed up, the owner's setup steps and restores.
#
# 1. CT 101: /docker/offsite-backup/rclone (root 700) for rclone.conf, which the owner writes (OAuth,
#    needs a browser). Until it exists the container idles and every run is skipped.
# 2. CT 101: install this commit's scripts/db-dumps.sh (adds immich_postgres to the 01:30 dumps); the
#    current one is kept as /docker/scripts/db-dumps.sh.bak-2026-11-27.
# 3. pvehost: /usr/local/sbin/pve-config-export.sh + pve-config-export.{service,timer} (daily 00:45),
#    run once now: tarball of /etc (+ /etc/pve), the cluster DB, /root and /usr/local into
#    /docker/backups/pvehost (owner = CT root, mode 600), newest 14 kept.
# 4. Komodo: stack "offsite-backup" on docker-prod from git (docker-compose/offsite-backup, run_build so
#    a version bump rebuilds the image), env RUSTIC_PASSWORD (generated here, never printed),
#    RCLONE_BWLIMIT=8M (Google Drive's 750 GiB/day cap), KUMA_PUSH_URL empty. An existing stack is left
#    alone (a new password would not open the existing repository). Deploy.
#
# Undo: Komodo -> Stacks -> offsite-backup -> Destroy, delete the stack (docker volume rm
# offsite-backup_rustic-cache); CT 101 `rm -r /docker/offsite-backup` and `mv
# /docker/scripts/db-dumps.sh.bak-2026-11-27 /docker/scripts/db-dumps.sh`; pvehost `systemctl disable
# --now pve-config-export.timer; rm /etc/systemd/system/pve-config-export.{service,timer}
# /usr/local/sbin/pve-config-export.sh; systemctl daemon-reload; rm -r
# /flash/subvols/subvol-100-disk-0/backups/pvehost`. The off-site repository itself is deleted in the
# cloud drive (folder homelab-rustic).
set -u
PVE() { ssh -F "$OPS_SSH_CONFIG" pve "$@"; }

echo "== 1. CT 101: /docker/offsite-backup/rclone"
if PVE 'pct exec 101 -- sh -s' <<'SH'
set -e
mkdir -p /docker/offsite-backup/rclone
chmod 700 /docker/offsite-backup /docker/offsite-backup/rclone
ls -ld /docker/offsite-backup/rclone
SH
then echo "dirs: ok"; else echo "dirs: FAILED"; exit 1; fi

echo "== 2. CT 101: db-dumps.sh"
if PVE 'set -e; umask 077; cat > /root/db-dumps.sh' < scripts/db-dumps.sh \
   && PVE 'set -e
           pct exec 101 -- sh -c "[ -e /docker/scripts/db-dumps.sh.bak-2026-11-27 ] || cp -p /docker/scripts/db-dumps.sh /docker/scripts/db-dumps.sh.bak-2026-11-27"
           pct push 101 /root/db-dumps.sh /docker/scripts/db-dumps.sh.new --perms 700 --user 0 --group 0
           rm -f /root/db-dumps.sh
           pct exec 101 -- bash -n /docker/scripts/db-dumps.sh.new
           pct exec 101 -- mv /docker/scripts/db-dumps.sh.new /docker/scripts/db-dumps.sh'; then
  echo "db-dumps.sh: installed (immich_postgres added; first dump at 01:30)"
else
  echo "db-dumps.sh: FAILED (previous script left in place)"; exit 1
fi

echo "== 3. pvehost: pve-config-export"
D=ops/pvehost/pve-config-export
if PVE 'set -e; umask 022; cat > /usr/local/sbin/pve-config-export.sh.new' < "$D/pve-config-export.sh" \
   && PVE 'set -e; umask 022; cat > /etc/systemd/system/pve-config-export.service' < "$D/pve-config-export.service" \
   && PVE 'set -e; umask 022; cat > /etc/systemd/system/pve-config-export.timer' < "$D/pve-config-export.timer" \
   && PVE 'sh -s' <<'SH'
set -e
chmod 700 /usr/local/sbin/pve-config-export.sh.new
bash -n /usr/local/sbin/pve-config-export.sh.new
mv /usr/local/sbin/pve-config-export.sh.new /usr/local/sbin/pve-config-export.sh
systemctl daemon-reload
systemctl enable --now pve-config-export.timer
systemctl start pve-config-export.service
journalctl -u pve-config-export.service -n 3 --no-pager -o cat
systemctl list-timers pve-config-export.timer --no-pager | head -2
SH
then echo "pve-config-export: installed, first export done"
else echo "pve-config-export: FAILED"; exit 1; fi
# The off-site container reads it as CT 101's root: check that it can.
PVE 'pct exec 101 -- sh -c "ls -ln /docker/backups/pvehost | tail -n 2; head -c1 /docker/backups/pvehost/pvehost-config-*.tar.gz >/dev/null && echo readable from CT 101: ok"' \
  || { echo "export not readable from CT 101"; exit 1; }

echo "== 4. Komodo stack, deploy"
python3 - <<'PY' || exit 1
import json, os, secrets, sys, time, urllib.request

def komodo(kind, typ, params, timeout=60):
    req = urllib.request.Request(f"{os.environ['KOMODO_URL']}/{kind}/{typ}", json.dumps(params).encode(),
        {"Content-Type": "application/json", "x-api-key": os.environ["KOMODO_API_KEY"],
         "x-api-secret": os.environ["KOMODO_API_SECRET"]}, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read() or "null")

def env_of(stack):
    env = komodo("read", "GetStack", {"stack": stack})["config"].get("environment", "")
    return dict(l.split("=", 1) for l in env.splitlines() if "=" in l and not l.lstrip().startswith("#"))

NAME, SERVER, RUN_DIR = "offsite-backup", "docker-prod", "docker-compose/offsite-backup"
stacks = {s["name"] for s in komodo("read", "ListStacks", {"limit": 500})}
if NAME in stacks:
    print(f"komodo: stack '{NAME}' already exists; config and password left as they are")
else:
    servers = {s["name"]: s["id"] for s in komodo("read", "ListServers", {"limit": 500})}
    if SERVER not in servers:
        sys.exit(f"komodo: server {SERVER} not found; stack not created")
    env = (f"RUSTIC_PASSWORD={secrets.token_urlsafe(32)}\n"
           "KUMA_PUSH_URL=\n"
           "RCLONE_BWLIMIT=8M\n")
    config = {"server_id": servers[SERVER], "project_name": NAME,
              "git_provider": "github.com", "git_https": True, "repo": "dcvdiego/homelab", "branch": "main",
              "run_directory": RUN_DIR, "file_paths": ["docker-compose.yml"], "env_file_path": ".env",
              "environment": env, "run_build": True,
              "auto_pull": False, "webhook_enabled": False, "send_alerts": True}
    komodo("write", "CreateStack", {"name": NAME, "config": config})
    got = komodo("read", "GetStack", {"stack": NAME})["config"]
    good = (got.get("run_directory") == RUN_DIR and got.get("run_build") is True
            and "RUSTIC_PASSWORD=" in got.get("environment", ""))
    print(f"komodo: stack '{NAME}' created: {'ok' if good else 'FAILED (config reads back different)'}")
    if not good:
        sys.exit(1)

uid = komodo("execute", "DeployStack", {"stack": NAME}, timeout=300)["_id"]["$oid"]
u = {}
for _ in range(120):
    u = komodo("read", "GetUpdate", {"id": uid})
    if u.get("status") == "Complete":
        break
    time.sleep(5)
print(f"komodo: deploy {NAME}: {'ok' if u.get('success') else 'FAILED'}")
# Failed stages: name and error tail only, every stack env value redacted (results are agent-readable)
vals = [v.strip() for v in env_of(NAME).values() if len(v.strip()) >= 4]
for log in u.get("logs", []):
    if not log.get("success"):
        err = (log.get("stderr") or "")[-1500:]
        for v in vals:
            err = err.replace(v, "<redacted>")
        print(f"  stage {log.get('stage')}: {err}")
sys.exit(0 if u.get("success") else 1)
PY

sleep 5
PVE 'pct exec 101 -- sh -s' <<'SH'
docker ps --filter name=offsite-backup --format '{{.Names}}: {{.Status}}'
docker logs offsite-backup 2>&1 | tail -n 3
docker exec offsite-backup rustic --version
docker exec offsite-backup rclone version | head -n 1
SH
