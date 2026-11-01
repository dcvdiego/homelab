# Komodo "Pre Deploy" backups for the critical stacks (scripts/pre-deploy-backup.sh, docs/backups.md).
# Sets each stack's pre_deploy command to `sh ../../scripts/pre-deploy-backup.sh <stack>` (run from the
# stack's run directory, docker-compose/<dir>, inside its repo clone). From then on every deploy of these
# stacks backs up first, and a failed backup stops the deploy.
# Read before write: a stack whose pre_deploy is already set to something else is left alone and reported.
# Nothing is deployed here; the first backups happen on each stack's next deploy.
# Undo: clear "Pre Deploy" on these stacks in the Komodo UI (Stack -> Config -> Pre Deploy).
python3 - <<'PY'
import json, os, urllib.request

def komodo(kind, typ, params):
    req = urllib.request.Request(
        f"{os.environ['KOMODO_URL']}/{kind}/{typ}", method="POST", data=json.dumps(params).encode(),
        headers={"Content-Type": "application/json", "x-api-key": os.environ["KOMODO_API_KEY"],
                 "x-api-secret": os.environ["KOMODO_API_SECRET"]})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read() or "null")

STACKS = ["photos", "security", "haos", "matter-hub", "network-prod", "network-tower",
          "frigate", "nextcloud", "zulip", "recipes", "open-webui"]
failed = False
for name in STACKS:
    want = f"sh ../../scripts/pre-deploy-backup.sh {name}"
    try:
        stack = komodo("read", "GetStack", {"stack": name})
        cfg = stack["config"]
        sid = stack.get("_id") or name
        sid = sid.get("$oid", name) if isinstance(sid, dict) else sid
        cur = (cfg.get("pre_deploy") or {}).get("command", "").strip()
        if cur == want:
            print(f"{name}: already set")
            continue
        if cur:
            print(f"{name}: SKIPPED, pre_deploy already has another command (left as is)")
            failed = True
            continue
        komodo("write", "UpdateStack", {"id": sid, "config": {"pre_deploy": {"path": "", "command": want}}})
        got = (komodo("read", "GetStack", {"stack": name})["config"].get("pre_deploy") or {}).get("command", "")
        print(f"{name}: set" if got.strip() == want else f"{name}: FAILED (reads back as {got!r})")
        failed |= got.strip() != want
    except Exception as e:
        print(f"{name}: FAILED ({e.__class__.__name__})")
        failed = True
raise SystemExit(1 if failed else 0)
PY
