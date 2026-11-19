# Copy the homelab.lan A records that docker-tower's Technitium (192.168.1.248) has and docker-prod's
# (192.168.1.224) lacks onto docker-prod.
#
# Why: TECHNITIUM_PROD_TOKEN was rejected (invalid-token) from 2026-11-07 until the owner replaced it on
# 2026-11-19, so every request in between added its records to docker-tower only. The tailnet
# (phone) resolves through docker-prod and couldn't find them (4 names: Forgejo plus private stacks).
#
# Add only: nothing is deleted or overwritten on either instance; a name that exists on docker-prod
# with a different address is reported (count only) and left alone. Prints counts, never names, so
# private stacks aren't named in this public repo's logs. Fails if either token is rejected.
#
# Undo: delete the added records on 192.168.1.224 (/api/zones/records/delete, or the web UI). Their
# names are the diff of the zone between the two instances before this ran.
set -euo pipefail
python3 - <<'EOF'
import json, os, sys, urllib.parse, urllib.request

ZONE = "homelab.lan"
TOWER = ("http://192.168.1.248:5380", os.environ["TECHNITIUM_TOWER_TOKEN"])
PROD = ("http://192.168.1.224:5380", os.environ["TECHNITIUM_PROD_TOKEN"])

def call(inst, path, **params):
    base, token = inst
    q = urllib.parse.urlencode({"token": token, **params})
    with urllib.request.urlopen(f"{base}{path}?{q}", timeout=15) as r:
        d = json.load(r)
    if d.get("status") != "ok":
        sys.exit(f"{base}{path}: {d.get('status')} ({d.get('errorMessage', '')[:80]})")
    return d["response"]

def a_records(inst):
    recs = call(inst, "/api/zones/records/get", zone=ZONE, domain=ZONE, listZone="true")["records"]
    out = {}
    for r in recs:
        if r["type"] == "A":
            out.setdefault(r["name"].lower(), set()).add(r["rData"]["ipAddress"])
    return out

tower, prod = a_records(TOWER), a_records(PROD)
print(f"A records: docker-tower {len(tower)} names, docker-prod {len(prod)} names")

missing = {n: ips for n, ips in tower.items() if n not in prod}
differ = sum(1 for n, ips in tower.items() if n in prod and prod[n] != ips)
only_prod = sum(1 for n in prod if n not in tower)

added = 0
for name, ips in sorted(missing.items()):
    for ip in sorted(ips):
        call(PROD, "/api/zones/records/add", zone=ZONE, domain=name, type="A", ipAddress=ip, ttl=3600)
        added += 1

after = a_records(PROD)
still = sum(1 for n in tower if n not in after)
print(f"added on docker-prod: {added} records for {len(missing)} names")
print(f"left alone: {differ} names with a different address, {only_prod} names only on docker-prod")
print(f"names still missing on docker-prod: {still}")
sys.exit(1 if still else 0)
EOF
