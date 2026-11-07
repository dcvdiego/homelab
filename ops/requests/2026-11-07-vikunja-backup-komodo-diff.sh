# 1. Pre-deploy backup for the notes stack (Vikunja), before merging the Vikunja 2.7.1 PR (#34):
#    - sets the notes stack's Komodo "Pre Deploy" to `sh ../../scripts/pre-deploy-backup.sh notes`
#      (read before write, same as 2026-10-24-komodo-pre-deploy-backups.sh), so every later deploy,
#      including #34's, backs up first;
#    - runs that backup once now on docker-prod (CT 101): mariadb-dump of notes-db-1 and a tar of
#      /docker/vikunja/files into /etc/komodo/pre-deploy-backups/notes/<timestamp>/. Nothing is stopped.
# 2. Read-only: compare the Komodo Core / Periphery compose files on the hosts with the repo's, before
#    anyone runs the manual Komodo deploy in docs/image-versions.md ("Komodo itself"). Values of
#    secret-looking keys are masked; only the diff is printed.
# Undo: clear "Pre Deploy" on the notes stack in Komodo; rm -r /etc/komodo/pre-deploy-backups/notes in CT 101.
set -u
PVE() { ssh -F "$OPS_SSH_CONFIG" pve "$@"; }
rc=0

echo "== 1a. notes stack: Pre Deploy"
python3 - <<'PY' || rc=1
import json, os, urllib.request

def komodo(kind, typ, params):
    req = urllib.request.Request(
        f"{os.environ['KOMODO_URL']}/{kind}/{typ}", method="POST", data=json.dumps(params).encode(),
        headers={"Content-Type": "application/json", "x-api-key": os.environ["KOMODO_API_KEY"],
                 "x-api-secret": os.environ["KOMODO_API_SECRET"]})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read() or "null")

name, want = "notes", "sh ../../scripts/pre-deploy-backup.sh notes"
stack = komodo("read", "GetStack", {"stack": name})
cfg = stack["config"]
if cfg.get("run_directory", "").strip("/") != "docker-compose/notes":
    raise SystemExit(f"{name}: run_directory is {cfg.get('run_directory')!r}, not docker-compose/notes; left alone")
sid = stack.get("_id") or name
sid = sid.get("$oid", name) if isinstance(sid, dict) else sid
cur = (cfg.get("pre_deploy") or {}).get("command", "").strip()
if cur == want:
    print(f"{name}: already set")
elif cur:
    raise SystemExit(f"{name}: SKIPPED, pre_deploy already has another command (left as is)")
else:
    komodo("write", "UpdateStack", {"id": sid, "config": {"pre_deploy": {"path": "", "command": want}}})
    got = (komodo("read", "GetStack", {"stack": name})["config"].get("pre_deploy") or {}).get("command", "")
    print(f"{name}: set" if got.strip() == want else f"{name}: FAILED (reads back as {got!r})")
    raise SystemExit(0 if got.strip() == want else 1)
PY

echo "== 1b. notes backup now (CT 101)"
# This commit's script, copied in for one run and removed again
if PVE 'cat > /root/pre-deploy-backup.sh' < scripts/pre-deploy-backup.sh \
   && PVE 'pct push 101 /root/pre-deploy-backup.sh /root/pre-deploy-backup.sh && rm -f /root/pre-deploy-backup.sh
           pct exec 101 -- sh /root/pre-deploy-backup.sh notes; r=$?
           pct exec 101 -- rm -f /root/pre-deploy-backup.sh
           pct exec 101 -- sh -c "ls -l /etc/komodo/pre-deploy-backups/notes/*/"
           exit $r'; then
  echo "backup: ok"
else
  echo "backup: FAILED"; rc=1
fi

echo "== 2. Komodo compose files: host vs repo (secret values masked)"
mask() { sed -E -e 's/^([^#]*(PASS|SECRET|KEY|TOKEN)[A-Z_]*["]?[[:space:]]*[:=][[:space:]]*).+$/\1<masked>/I' \
                 -e 's#(://[^/:@[:space:]]*:)[^@[:space:]]*@#\1<masked>@#g'; }
for pair in "104 /etc/komodo/core/docker-compose.yml docker-compose/komodo/docker-compose.yml" \
            "104 /etc/komodo/periphery/docker-compose.yml docker-compose/komodo-periphery/docker-compose.yml" \
            "101 /etc/komodo/periphery/docker-compose.yml docker-compose/komodo-periphery/docker-compose.yml"; do
  read -r ct host repo <<<"$pair"
  echo "--- CT $ct $host vs repo $repo"
  if PVE "pct exec $ct -- cat $host" > /tmp/komodo-host.yml; then
    diff -u <(mask < "$repo") <(mask < /tmp/komodo-host.yml) --label "repo:$repo" --label "CT$ct:$host" \
      && echo "(identical)"
  else
    echo "could not read $host"; rc=1
  fi
  echo "files next to it: $(PVE "pct exec $ct -- ls $(dirname "$host")" | tr '\n' ' ')"
done
rm -f /tmp/komodo-host.yml
exit $rc
