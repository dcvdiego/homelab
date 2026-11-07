# Deploy the stacks whose merges never reached the servers: their apply runs were cancelled while
# waiting for approval (GitHub keeps one pending run per concurrency group; fixed by ops/bin/apply-base.py
# in this same PR, but that only covers merges from now on).
#   - traefik      (#32: v3.6.13 -> v3.7.16)
#   - recipes      (#33: Tandoor 2.0.3 -> 2.7.2, Traefik port 8080 -> 80; pre-deploy backup runs first)
#   - network-prod, network-tower (#41: cloudflared 2024.10.1 -> 2026.x; Technitium backup runs first)
# Same calls as ops/bin/redeploy-stacks.py, for the stacks whose run_directory is listed below.
# Traefik restarts: every site blips for a few seconds. cloudflared restarts: tunnel blips.
# Undo: revert the PR in question; the next apply run redeploys the old version.
python3 - <<'PY'
import json, os, time, urllib.request

DIRS = ["docker-compose/traefik", "docker-compose/recipes", "docker-compose/network"]

def komodo(kind, typ, params):
    req = urllib.request.Request(
        f"{os.environ['KOMODO_URL']}/{kind}/{typ}", method="POST", data=json.dumps(params).encode(),
        headers={"Content-Type": "application/json", "x-api-key": os.environ["KOMODO_API_KEY"],
                 "x-api-secret": os.environ["KOMODO_API_SECRET"]})
    with urllib.request.urlopen(req, timeout=300) as r:
        return json.loads(r.read() or "null")

failed, found = False, []
for ks in komodo("read", "ListStacks", {"limit": 500}):
    run_dir = (komodo("read", "GetStack", {"stack": ks["name"]}).get("config") or {}).get("run_directory", "")
    if run_dir.rstrip("/") not in DIRS:
        continue
    found.append(ks["name"])
    try:
        uid = komodo("execute", "DeployStack", {"stack": ks["name"]})["_id"]["$oid"]
        for _ in range(180):
            u = komodo("read", "GetUpdate", {"id": uid})
            if u.get("status") == "Complete":
                break
            time.sleep(5)
        ok = bool(u.get("success"))
        print(f"{ks['name']}: {'deployed' if ok else 'FAILED'}")
        failed |= not ok
    except Exception as e:
        print(f"{ks['name']}: FAILED ({e.__class__.__name__})")
        failed = True
print("stacks:", ", ".join(sorted(found)) or "none found")
raise SystemExit(1 if failed or len(found) < 4 else 0)
PY
