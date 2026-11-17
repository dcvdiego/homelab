# Phase 4 of docs/forgejo-split.md: Komodo deploys the private stacks from Forgejo instead of GitHub.
#
# 1. Komodo git account for Forgejo (CreateGitProviderAccount; no Core config edit or restart):
#    domain 192.168.1.248:3200 (an IP, so deploys don't depend on either Technitium), http, user
#    homelabsito with a read:repository-only token named "komodo", made here and never printed.
#    Skipped if the account exists. The fixed name means Forgejo refuses a second one, so a run that
#    failed after making it stops here instead of piling up tokens (delete the old one in Forgejo).
# 2. The stacks to move are the ones the private repo has: every docker-compose/<dir> in
#    diego/homelab-private (read from the bare repo in the container), so this public file names none of them. Each Komodo
#    stack whose run_directory is one of those and that still deploys from dcvdiego/homelab gets
#    git_provider/git_https/git_account/repo switched; branch, run directory, files, env and
#    pre-deploy stay as they are. Running stacks are deployed one at a time (pre-deploy backup
#    first, as on every deploy) and should come up unchanged. Stopped stacks are only repointed.
# 3. Before any deploy, Komodo must read each stack's compose file from Forgejo (RefreshStackCache);
#    if it can't, that stack goes back to GitHub undeployed and the request stops. If a deploy fails,
#    that stack is pointed back at GitHub and deployed again, and the request stops: the remaining
#    stacks keep deploying from GitHub.
#
# Undo: for each moved stack, Komodo -> Stacks -> <stack> -> Config: Git provider github.com, https on,
# account empty, repo dcvdiego/homelab; deploy. Then Settings -> Providers: delete the 192.168.1.248:3200
# account, and delete homelabsito's "komodo" token in Forgejo.
set -u
PVE() { ssh -F "$OPS_SSH_CONFIG" pve "$@"; }
FJ() { PVE "pct exec 104 -- docker exec -u 1000 forgejo forgejo $(printf '%q ' "$@")"; }
DOMAIN=192.168.1.248:3200

komodo_has_account() {
  python3 - "$DOMAIN" <<'PY'
import json, os, sys, urllib.request
req = urllib.request.Request(f"{os.environ['KOMODO_URL']}/read/ListGitProviderAccounts",
        json.dumps({"domain": sys.argv[1], "username": "homelabsito"}).encode(),
        {"Content-Type": "application/json", "x-api-key": os.environ["KOMODO_API_KEY"],
         "x-api-secret": os.environ["KOMODO_API_SECRET"]}, method="POST")
with urllib.request.urlopen(req, timeout=60) as r:
    sys.exit(0 if json.loads(r.read()) else 3)
PY
}

# The private repo's stack directories, read from the bare repo inside the container (no token needed)
PRIVATE_DIRS=$(PVE 'pct exec 104 -- docker exec -u 1000 forgejo git --git-dir=/var/lib/gitea/git/repositories/diego/homelab-private.git ls-tree -d --name-only main docker-compose/') \
  && [ -n "$PRIVATE_DIRS" ] || { echo "forgejo: cannot list the private repo's stacks"; exit 1; }
echo "private repo stacks: $(printf "%s\n" "$PRIVATE_DIRS" | grep -c .)"

echo "== 1. Komodo git account for Forgejo"
st=0; komodo_has_account || st=$?
case $st in
  0) echo "komodo account homelabsito@$DOMAIN: exists (left as is)"; KOMODO_FJ_TOKEN= ;;
  3) KOMODO_FJ_TOKEN=$(FJ admin user generate-access-token -u homelabsito -t komodo \
                         --scopes read:repository --raw 2>/dev/null) || KOMODO_FJ_TOKEN=
     [ -n "$KOMODO_FJ_TOKEN" ] || { echo "homelabsito read token: FAILED"; exit 1; } ;;
  *) echo "komodo: cannot list git accounts"; exit 1 ;;
esac
export KOMODO_FJ_TOKEN DOMAIN PRIVATE_DIRS

python3 - <<'PY'
import json, os, sys, time, urllib.request

def komodo(kind, typ, params, timeout=60):
    req = urllib.request.Request(f"{os.environ['KOMODO_URL']}/{kind}/{typ}", json.dumps(params).encode(),
            {"Content-Type": "application/json", "x-api-key": os.environ["KOMODO_API_KEY"],
             "x-api-secret": os.environ["KOMODO_API_SECRET"]}, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read() or "null")

DOMAIN, tok = os.environ["DOMAIN"], os.environ.get("KOMODO_FJ_TOKEN", "")
if tok:
    komodo("write", "CreateGitProviderAccount",
           {"account": {"domain": DOMAIN, "https": False, "username": "homelabsito", "token": tok}})
    ok = bool(komodo("read", "ListGitProviderAccounts", {"domain": DOMAIN, "username": "homelabsito"}))
    print(f"komodo account homelabsito@{DOMAIN}: {'created' if ok else 'FAILED'}")
    if not ok:
        sys.exit(1)

private = {l.strip().rstrip("/") for l in os.environ["PRIVATE_DIRS"].splitlines() if l.strip()}
print(f"private repo stack directories: {', '.join(sorted(private))}")

GH = {"git_provider": "github.com", "git_https": True, "git_account": "", "repo": "dcvdiego/homelab"}
FJ = {"git_provider": DOMAIN, "git_https": False, "git_account": "homelabsito", "repo": "diego/homelab-private"}

def deploy(name):
    uid = komodo("execute", "DeployStack", {"stack": name}, timeout=300)["_id"]["$oid"]
    u = {}
    for _ in range(180):
        u = komodo("read", "GetUpdate", {"id": uid})
        if u.get("status") == "Complete":
            break
        time.sleep(5)
    # stage names only: stderr can carry stack env values, and agents read this output
    bad = [l.get("stage") for l in u.get("logs", []) if not l.get("success")]
    return bool(u.get("success")), bad

todo = []
for s in komodo("read", "ListStacks", {}):
    cfg = komodo("read", "GetStack", {"stack": s["id"]})["config"]
    rd = (cfg.get("run_directory") or "").strip("./").rstrip("/")
    if rd not in private:
        continue
    if cfg.get("repo") == FJ["repo"]:
        print(f"{s['name']}: already on Forgejo (left as is)")
        continue
    if cfg.get("repo") != GH["repo"] or cfg.get("git_provider") != GH["git_provider"]:
        print(f"{s['name']}: deploys from {cfg.get('git_provider')}/{cfg.get('repo')}, not public GitHub: left as is")
        continue
    todo.append((s["name"], s["id"], (s.get("info") or {}).get("state", "")))

# Stopped stacks first (no deploy), then running ones one at a time
todo.sort(key=lambda t: t[2].lower() in ("running", "unhealthy"))
def move(name, sid, state):
    komodo("write", "UpdateStack", {"id": sid, "config": FJ})
    got = komodo("read", "GetStack", {"stack": sid})["config"]
    if any(got.get(k) != v for k, v in FJ.items()):
        komodo("write", "UpdateStack", {"id": sid, "config": GH})
        sys.exit(f"{name}: config reads back different; pointed back at GitHub, stopping")
    # Core fetches the compose file through the new account first: a bad account stops here, before
    # any deploy (and before pre-deploy backups stop anything)
    komodo("write", "RefreshStackCache", {"stack": sid}, timeout=300)
    info = komodo("read", "GetStack", {"stack": sid}).get("info") or {}
    if info.get("remote_errors") or not info.get("remote_contents") or not info.get("latest_hash"):
        komodo("write", "UpdateStack", {"id": sid, "config": GH})
        komodo("write", "RefreshStackCache", {"stack": sid}, timeout=300)
        sys.exit(f"{name}: Komodo cannot read the compose file from Forgejo ({len(info.get('remote_errors') or [])} "
                 "error(s)); pointed back at GitHub, nothing deployed, stopping")
    print(f"{name}: compose file read from Forgejo at {info['latest_hash'][:8]}")
    if state.lower() not in ("running", "unhealthy"):
        print(f"{name}: repointed to Forgejo (state {state or 'unknown'}: not deployed)")
        return
    ok, bad = deploy(name)
    if ok:
        print(f"{name}: repointed to Forgejo, deployed: ok")
        return
    print(f"{name}: deploy from Forgejo FAILED (stages: {', '.join(map(str, bad))}); pointing back at GitHub")
    komodo("write", "UpdateStack", {"id": sid, "config": GH})
    ok2, bad2 = deploy(name)
    print(f"{name}: back on GitHub, deployed: {'ok' if ok2 else 'FAILED (stages: ' + ', '.join(map(str, bad2)) + ')'}")
    sys.exit(1)

for name, sid, state in todo:
    try:
        move(name, sid, state)
    except SystemExit:
        raise
    except Exception as e:  # API error or timeout after the switch: don't leave it on an unchecked source
        print(f"{name}: Komodo call failed ({e.__class__.__name__}); pointing back at GitHub")
        try:
            komodo("write", "UpdateStack", {"id": sid, "config": GH})
            print(f"{name}: back on GitHub (not redeployed: check it in Komodo)")
        except Exception as e2:
            print(f"{name}: could NOT point back at GitHub ({e2.__class__.__name__}): fix it in Komodo by hand")
        sys.exit(1)
print(f"done: {len(todo)} stack(s) moved")
PY
