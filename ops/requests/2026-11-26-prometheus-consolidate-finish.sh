# Finish 2026-11-26-prometheus-consolidate.sh, which stopped at step 3: its single SSH session through
# Warpgate was cut after ~5 minutes while tar was archiving InfluxDB (steps 1 and 2 had completed:
# the Proxmox InfluxDB metric server is deleted, the pve-exporter token is in place).
# State before this runs: influxdb and telegraf stopped, their data untouched in /docker/grafana-monitoring.
#   3. Archive InfluxDB + Telegraf data in the background inside CT 101 (setsid, log in the archive dir),
#      polled with short SSH calls so no session stays open; then remove containers, data dirs, images.
#      A partial archive from the cut run is replaced.
#   4./5. As in the original request: DNS record, redeploy monitoring, and fail unless container and
#      Proxmox metrics arrive.
# This PR also adds empty grafana/provisioning/{plugins,alerting} dirs (Grafana logged errors for them),
# which makes the apply job redeploy monitoring first, so pve-exporter starts with its token.
# Undo: as in the original request.
set -euo pipefail
PVE() { ssh -F "$OPS_SSH_CONFIG" pve "$@"; }
TS=$(date +%Y%m%d-%H%M%S)
PROM=http://192.168.1.224:9090
R=/docker/backups/retired

komodo() {
  curl -fsS -m 300 -X POST "$KOMODO_URL/$1/$2" -H "Content-Type: application/json" \
    -H "x-api-key: $KOMODO_API_KEY" -H "x-api-secret: $KOMODO_API_SECRET" -d "$3"
}

echo "== 3. InfluxDB and Telegraf"
if PVE 'pct exec 101 -- test -d /docker/grafana-monitoring/influxdb'; then
  PVE "pct exec 101 -- du -sh --apparent-size /docker/grafana-monitoring/influxdb /docker/grafana-monitoring/telegraf" | sed 's/^/  size: /'
  PVE "pct exec 101 -- sh -c 'docker stop telegraf influxdb >/dev/null 2>&1 || true
    mkdir -p $R && chmod 700 $R && rm -f $R/influxdb-*.tar.gz.part
    cd /docker/grafana-monitoring
    setsid sh -c \"tar czf $R/influxdb-$TS.tar.gz.part influxdb telegraf && tar tzf $R/influxdb-$TS.tar.gz.part >/dev/null && mv $R/influxdb-$TS.tar.gz.part $R/influxdb-$TS.tar.gz && echo done > $R/influxdb-$TS.status || echo failed > $R/influxdb-$TS.status\" </dev/null >/dev/null 2>&1 &'"
  st=""
  for i in $(seq 120); do  # up to 60 min, one short SSH call every 30 s
    sleep 30
    st=$(PVE "pct exec 101 -- cat $R/influxdb-$TS.status 2>/dev/null" || true)
    [ -n "$st" ] && break
    [ $((i % 4)) -eq 0 ] && echo "  still archiving ($((i / 2)) min)"
  done
  [ "$st" = done ] || { echo "  archive: ${st:-timed out}; data left in place"; exit 1; }
  PVE "pct exec 101 -- du -h --apparent-size $R/influxdb-$TS.tar.gz" | sed 's/^/  archived: /'
  PVE "pct exec 101 -- sh -c 'docker rm -f telegraf influxdb >/dev/null 2>&1 || true
    rm -rf /docker/grafana-monitoring/influxdb /docker/grafana-monitoring/telegraf $R/influxdb-$TS.status
    docker image rm influxdb:2.8.0 telegraf:1.38.2 >/dev/null 2>&1 || true'"
  echo "  containers, data dirs and images removed"
else
  echo "  already gone"
fi

echo "== 4. DNS"
for pair in "192.168.1.248 $TECHNITIUM_TOWER_TOKEN" "192.168.1.224 $TECHNITIUM_PROD_TOKEN"; do
  read -r host token <<<"$pair"
  n=$(curl -fsS "http://$host:5380/api/zones/records/get?token=$token&zone=homelab.lan&domain=influxdb.homelab.lan" | jq '[.response.records[]? | select(.type == "A")] | length')
  if [ "$n" -gt 0 ]; then
    st=$(curl -fsS "http://$host:5380/api/zones/records/delete?token=$token&zone=homelab.lan&domain=influxdb.homelab.lan&type=A&ipAddress=192.168.1.224" | jq -r .status)
    echo "  technitium $host: influxdb record delete: $st"
  else echo "  technitium $host: no influxdb record"; fi
done

echo "== 5. Redeploy monitoring and check"
stack=""
for ks in $(komodo read ListStacks '{"limit":500}' | jq -r '.[].name'); do
  [ "$(komodo read GetStack "{\"stack\":\"$ks\"}" | jq -r '.config.run_directory // ""')" = docker-compose/monitoring ] && stack=$ks
done
[ -n "$stack" ] || { echo "  monitoring stack not found"; exit 1; }
id=$(komodo execute DeployStack "{\"stack\":\"$stack\"}" | jq -r '._id["$oid"]')
for _ in $(seq 120); do
  u=$(komodo read GetUpdate "{\"id\":\"$id\"}"); [ "$(jq -r .status <<<"$u")" = Complete ] && break; sleep 5
done
[ "$(jq -r .success <<<"$u")" = true ] || { echo "  deploy $stack: FAILED (see the update in Komodo)"; exit 1; }
echo "  deploy $stack: ok"
sleep 90
echo "  Prometheus targets:"
curl -fsS "$PROM/api/v1/targets" | jq -r '.data.activeTargets[] | "    \(.labels.job) \(.labels.instance) \(.health) \(.lastError)"'
q() { curl -fsS "$PROM/api/v1/query" --data-urlencode "query=$1" | jq -r '.data.result[0].value[1] // "none"'; }
containers=$(q 'count(container_memory_rss{name!=""})'); series=$(q 'count({__name__=~"container_.+"})')
guests=$(q 'count(pve_guest_info)'); node_up=$(q 'max(pve_up{id=~"node/.*"})'); pve_target=$(q 'up{job="pve"}')
echo "  containers with memory metrics: $containers (cAdvisor series: $series)"
echo "  Proxmox: scrape up=$pve_target, node up=$node_up, guests seen=$guests"
echo "  memory now (MiB):"
PVE "pct exec 101 -- docker stats --no-stream --format '{{.Name}} {{.MemUsage}}'" | grep -E '^(alloy|prometheus|grafana|loki|pve-exporter|uptime-kuma) ' | sed 's/^/    /'

# Fail the run if a feed is missing, so a half-working migration doesn't look done
bad=""
[ "$containers" != none ] && [ "${containers%.*}" -ge 10 ] || bad="$bad container-metrics"
[ "$pve_target" = 1 ] && [ "$node_up" = 1 ] || bad="$bad pve-exporter"
[ "$guests" != none ] && [ "${guests%.*}" -ge 1 ] || bad="$bad pve-guests"
if [ -n "$bad" ]; then echo "CHECK FAILED:$bad (InfluxDB is already archived; see the undo notes above)"; exit 1; fi
echo "all feeds OK"

