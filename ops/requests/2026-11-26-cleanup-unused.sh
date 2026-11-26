# Clean up apps that are no longer used, and report how Grafana uses InfluxDB.
#   1. Report (read-only): Grafana's data sources and, per dashboard, how many panels query each one;
#      InfluxDB's buckets. Decides whether influxdb + telegraf can go (a later PR).
#   2. backend_cms (Strapi's Postgres 12, stopped, the Strapi app itself long gone): archive its data
#      directory, then destroy and delete the Komodo stack and remove the data directory.
#   3. Portainer (replaced by Komodo on 2026-10-07, stopped since): remove portainer on docker-tower
#      (data volume archived first) and portainer_agent on docker-prod, their images, and the
#      portainer.homelab.lan DNS record on both Technitium servers.
#   4. Stop the dev stack (Termix). Containers and /docker/termix-data stay; start it again in Komodo.
#   5. Install this commit's scripts/db-dumps.sh (skips stopped databases instead of alerting nightly).
# Archives: /etc/komodo/pre-deploy-backups/<name>/<timestamp>/ in the CT that ran it (root-only).
# Undo:
#   backend_cms: untar the archive into /data/backend_db, restore docker-compose/backend_cms with
#     `git revert`, recreate the stack in Komodo.
#   portainer: `docker volume create portainer_data`, untar the archive into its _data directory,
#     `docker run` portainer again (it was portainer/portainer-ee:latest).
#   dev: Start the stack in Komodo.
#   db-dumps: `pct exec 101 -- mv /docker/scripts/db-dumps.sh.bak-2026-11-26 /docker/scripts/db-dumps.sh`.
set -euo pipefail
PVE() { ssh -F "$OPS_SSH_CONFIG" pve "$@"; }
TS=$(date +%Y%m%d-%H%M%S)
GDB=/docker/grafana-monitoring/grafana/grafana.db

komodo() {  # komodo <read|write|execute> <Type> <json params>
  curl -fsS -m 300 -X POST "$KOMODO_URL/$1/$2" -H "Content-Type: application/json" \
    -H "x-api-key: $KOMODO_API_KEY" -H "x-api-secret: $KOMODO_API_SECRET" -d "$3"
}
wait_update() {  # wait_update <update json>: prints ok/FAILED
  local id; id=$(jq -r '._id["$oid"]' <<<"$1")
  for _ in $(seq 120); do
    u=$(komodo read GetUpdate "{\"id\":\"$id\"}")
    [ "$(jq -r .status <<<"$u")" = Complete ] && break
    sleep 5
  done
  [ "$(jq -r .success <<<"$u")" = true ] && echo ok || echo FAILED
}
stack_dir() { komodo read GetStack "{\"stack\":\"$1\"}" | jq -r '.config.run_directory // ""'; }

echo "== 1. Grafana and InfluxDB report"
report() {
PVE "pct exec 101 -- sqlite3 -readonly -json $GDB 'select uid, name, type, is_default from data_source;'" > /tmp/ds.json
PVE "pct exec 101 -- sqlite3 -readonly -json $GDB 'select title, uid, updated, cast(data as text) as data from dashboard where is_folder = 0;'" > /tmp/db.json
PVE "pct exec 101 -- sqlite3 -readonly $GDB 'select max(last_seen_at) from user;'" | sed 's/^/last Grafana sign-in: /'
python3 - /tmp/ds.json /tmp/db.json <<'PY'
import json, sys, collections
ds = json.loads(open(sys.argv[1]).read() or "[]")
dbs = json.loads(open(sys.argv[2]).read() or "[]")
by_uid = {d["uid"]: d for d in ds}
by_name = {d["name"]: d for d in ds}
default = next((d for d in ds if d["is_default"]), None)
print("data sources:")
for d in ds:
    print(f"  {d['name']} ({d['type']}){' default' if d['is_default'] else ''}")
def ref(x):
    if isinstance(x, dict):
        if x.get("uid") in by_uid: return by_uid[x["uid"]]["name"]
        if str(x.get("uid", "")).startswith("$"): return f"variable {x['uid']} ({x.get('type', '?')})"
        return f"? {x.get('type', '')} {x.get('uid', '')}".strip()
    if isinstance(x, str):
        return by_name[x]["name"] if x in by_name else (by_uid[x]["name"] if x in by_uid else f"? {x}")
    return default["name"] + " (default)" if default else "default"
def panels(ps):
    for p in ps or []:
        yield p
        yield from panels(p.get("panels"))
print("dashboards (panels per data source):")
for d in sorted(dbs, key=lambda d: d["title"].lower()):
    j = json.loads(d["data"]); c = collections.Counter()
    for p in panels(j.get("panels")):
        if p.get("type") == "row" or not (p.get("targets") or p.get("datasource")): continue
        srcs = {ref(t.get("datasource", p.get("datasource"))) for t in p.get("targets") or []} or {ref(p.get("datasource"))}
        c.update(srcs)
    print(f"  {d['title']} (edited {d['updated'][:10]}): " + (", ".join(f"{k} {v}" for k, v in c.most_common()) or "no panels"))
PY
PVE "pct exec 101 -- docker exec influxdb influx bucket list --hide-headers" 2>&1 | awk '{print "  influx bucket:", $2, "retention", $3}' || echo "  influx bucket list: unavailable"
}
report || echo "report: FAILED (nothing else depends on it; carrying on)"

echo "== 2. backend_cms"
if [ "$(stack_dir backend_cms 2>/dev/null)" = docker-compose/backend_cms ]; then
  PVE "pct exec 101 -- sh -c 'set -e; d=/etc/komodo/pre-deploy-backups/backend_cms/$TS; mkdir -p \$d; chmod 700 /etc/komodo/pre-deploy-backups/backend_cms
       [ \"\$(docker inspect -f {{.State.Running}} strapiDB 2>/dev/null || echo false)\" = false ]
       tar czf \$d/backend_db.tar.gz -C /data backend_db && tar tzf \$d/backend_db.tar.gz >/dev/null && du -h \$d/backend_db.tar.gz'"
  r=$(wait_update "$(komodo execute DestroyStack '{"stack":"backend_cms"}')"); echo "destroy: $r"
  [ "$r" = ok ] || exit 1
  komodo write DeleteStack '{"id":"backend_cms"}' >/dev/null && echo "komodo stack deleted"
  PVE "pct exec 101 -- sh -c '! docker inspect strapiDB >/dev/null 2>&1 && rm -rf /data/backend_db && echo data dir removed'"
else
  echo "backend_cms: no such Komodo stack (already removed?)"
fi

echo "== 3. Portainer"
PVE "pct exec 104 -- sh -c 'set -e
  if docker inspect portainer >/dev/null 2>&1; then
    [ \"\$(docker inspect -f {{.State.Running}} portainer)\" = false ]
    d=/etc/komodo/pre-deploy-backups/portainer/$TS; mkdir -p \$d; chmod 700 /etc/komodo/pre-deploy-backups/portainer
    tar czf \$d/portainer_data.tar.gz -C /var/lib/docker/volumes/portainer_data _data && tar tzf \$d/portainer_data.tar.gz >/dev/null
    du -h \$d/portainer_data.tar.gz
    docker rm portainer >/dev/null && docker volume rm portainer_data >/dev/null && echo docker-tower: portainer and its volume removed
  else echo docker-tower: no portainer container; fi
  docker image rm portainer/portainer-ee:latest >/dev/null 2>&1 && echo docker-tower: image removed || true'"
PVE "pct exec 101 -- sh -c 'if docker inspect portainer_agent >/dev/null 2>&1; then
    [ \"\$(docker inspect -f {{.State.Running}} portainer_agent)\" = false ] && docker rm portainer_agent >/dev/null && echo docker-prod: portainer_agent removed
  else echo docker-prod: no portainer_agent; fi
  docker image rm portainer/agent:2.21.4 >/dev/null 2>&1 && echo docker-prod: image removed || true'"
for pair in "192.168.1.248 $TECHNITIUM_TOWER_TOKEN" "192.168.1.224 $TECHNITIUM_PROD_TOKEN"; do
  read -r host token <<<"$pair"
  n=$(curl -fsS "http://$host:5380/api/zones/records/get?token=$token&zone=homelab.lan&domain=portainer.homelab.lan" | jq '[.response.records[]? | select(.type == "A")] | length')
  if [ "$n" -gt 0 ]; then
    st=$(curl -fsS "http://$host:5380/api/zones/records/delete?token=$token&zone=homelab.lan&domain=portainer.homelab.lan&type=A&ipAddress=192.168.1.248" | jq -r .status)
    echo "technitium $host: portainer record delete: $st"
  else echo "technitium $host: no portainer record"; fi
done

echo "== 4. dev (Termix)"
if [ "$(stack_dir dev)" = docker-compose/dev ]; then
  echo "stop: $(wait_update "$(komodo execute StopStack '{"stack":"dev"}')")"
else echo "dev: not found"; fi

echo "== 5. db-dumps"
PVE 'set -e; umask 077; cat > /root/db-dumps.sh' < scripts/db-dumps.sh
PVE 'set -e
     pct exec 101 -- sh -c "[ -e /docker/scripts/db-dumps.sh.bak-2026-11-26 ] || cp -p /docker/scripts/db-dumps.sh /docker/scripts/db-dumps.sh.bak-2026-11-26"
     pct push 101 /root/db-dumps.sh /docker/scripts/db-dumps.sh.new --perms 700 --user 0 --group 0
     rm -f /root/db-dumps.sh
     pct exec 101 -- bash -n /docker/scripts/db-dumps.sh.new
     pct exec 101 -- mv /docker/scripts/db-dumps.sh.new /docker/scripts/db-dumps.sh'
echo "db-dumps: installed"
