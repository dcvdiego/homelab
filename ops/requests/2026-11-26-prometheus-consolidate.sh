# Finish moving the monitoring stack onto Prometheus (docs/monitoring.md). The apply job has already
# redeployed the stack from this commit before this runs: Alloy now writes container metrics, Grafana
# loads its provisioning, and pve-exporter is waiting for its token.
#   1. Proxmox: lists the metric servers and deletes the InfluxDB ones (InfluxDB is gone).
#   2. Proxmox: creates user prometheus@pve with role PVEAuditor (read-only) on /, and an API token
#      "exporter". The token goes straight from pvehost into
#      /docker/grafana-monitoring/pve-exporter/pve.env in CT 101 (root, 600); it is never printed.
#      Skipped if that file already exists.
#   3. InfluxDB and Telegraf (left running as orphans by the deploy): stopped, data archived to
#      /docker/backups/retired/influxdb-<ts>.tar.gz (on the /docker disk, so PBS backs it up), then removed.
#   4. Removes the influxdb.homelab.lan DNS record on both Technitium servers.
#   5. Deploys the monitoring stack again so pve-exporter starts with its token, then checks the
#      Prometheus targets and that container and Proxmox metrics are arriving.
# Undo:
#   Revert the PR and deploy monitoring. For InfluxDB's data, untar the archive into
#   /docker/grafana-monitoring/. Token: `pveum user delete prometheus@pve` on pvehost, and
#   rm /docker/grafana-monitoring/pve-exporter/pve.env in CT 101.
set -euo pipefail
PVE() { ssh -F "$OPS_SSH_CONFIG" pve "$@"; }
TS=$(date +%Y%m%d-%H%M%S)
PROM=http://192.168.1.224:9090

komodo() {
  curl -fsS -m 300 -X POST "$KOMODO_URL/$1/$2" -H "Content-Type: application/json" \
    -H "x-api-key: $KOMODO_API_KEY" -H "x-api-secret: $KOMODO_API_SECRET" -d "$3"
}

echo "== 1. Proxmox metric servers"
PVE 'pvesh get /cluster/metrics/server --output-format json' \
  | jq -r '.[] | "\(.id) \(.type) \(.server):\(.port) disabled=\(.disable // 0)"' | sed 's/^/  /' || true
for id in $(PVE 'pvesh get /cluster/metrics/server --output-format json' | jq -r '.[] | select(.type == "influxdb") | .id'); do
  PVE "pvesh delete /cluster/metrics/server/$id" && echo "  deleted metric server $id"
done

echo "== 2. pve-exporter token"
if PVE 'pct exec 101 -- test -s /docker/grafana-monitoring/pve-exporter/pve.env'; then
  echo "  pve.env already there; token left as is"
else
  PVE 'bash -s' <<'EOS'
set -euo pipefail
# pvehost has no jq: plain-text listing for the check, core perl (JSON::PP) to read the token
pveum user list --noborder | awk '{print $1}' | grep -qx prometheus@pve \
  || pveum user add prometheus@pve --comment "read-only: prometheus-pve-exporter (monitoring stack)"
pveum acl modify / --users prometheus@pve --roles PVEAuditor
pveum user token remove prometheus@pve exporter >/dev/null 2>&1 || true
umask 077
trap 'rm -f /root/pve.env' EXIT  # the token file never outlives this step, even if a command fails
v=$(pveum user token add prometheus@pve exporter --privsep 0 --comment "pve-exporter" --output-format json \
  | perl -MJSON::PP -0777 -ne 'print decode_json($_)->{value} // ""')
[ -n "$v" ] && [ "$v" != null ]
printf 'PVE_USER=prometheus@pve\nPVE_TOKEN_NAME=exporter\nPVE_TOKEN_VALUE=%s\n' "$v" > /root/pve.env
unset v
pct exec 101 -- sh -c 'mkdir -p /docker/grafana-monitoring/pve-exporter && chmod 700 /docker/grafana-monitoring/pve-exporter'
pct push 101 /root/pve.env /docker/grafana-monitoring/pve-exporter/pve.env --perms 600 --user 0 --group 0
rm -f /root/pve.env
echo "  user prometheus@pve (PVEAuditor on /) and token exporter created; pve.env written in CT 101"
EOS
fi

echo "== 3. InfluxDB and Telegraf"
PVE "pct exec 101 -- sh -c 'set -e
  docker stop telegraf influxdb >/dev/null 2>&1 || true
  if [ -d /docker/grafana-monitoring/influxdb ]; then
    mkdir -p /docker/backups/retired; chmod 700 /docker/backups/retired
    a=/docker/backups/retired/influxdb-$TS.tar.gz
    d=influxdb; [ -d /docker/grafana-monitoring/telegraf ] && d=\"influxdb telegraf\"
    tar czf \$a -C /docker/grafana-monitoring \$d && tar tzf \$a >/dev/null
    echo \"  archived: \$a (\$(du -h --apparent-size \$a | cut -f1))\"
    docker rm -f telegraf influxdb >/dev/null 2>&1 || true
    rm -rf /docker/grafana-monitoring/influxdb /docker/grafana-monitoring/telegraf
    echo \"  containers and data dirs removed\"
  else echo \"  already gone\"; fi
  docker image rm \$(docker images --format \"{{.Repository}}:{{.Tag}}\" | grep -E \"^(influxdb|telegraf):\") >/dev/null 2>&1 && echo \"  images removed\" || true'"

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
echo "  deploy $stack: $(jq -r 'if .success then "ok" else "FAILED" end' <<<"$u")"
sleep 90
echo "  Prometheus targets:"
curl -fsS "$PROM/api/v1/targets" | jq -r '.data.activeTargets[] | "    \(.labels.job) \(.labels.instance) \(.health) \(.lastError)"'
q() { curl -fsS "$PROM/api/v1/query" --data-urlencode "query=$1" | jq -r '.data.result[0].value[1] // "none"'; }
echo "  containers with memory metrics: $(q 'count(container_memory_rss{name!=""})')"
echo "  cAdvisor series: $(q 'count({__name__=~"container_.+"})')"
echo "  Proxmox guests seen: $(q 'count(pve_guest_info)')  pve_up for node: $(q 'max(pve_up{id=~"node/.*"})')"
echo "  memory now (MiB):"
PVE "pct exec 101 -- docker stats --no-stream --format '{{.Name}} {{.MemUsage}}'" | grep -E '^(alloy|prometheus|grafana|loki|pve-exporter|uptime-kuma) ' | sed 's/^/    /'
