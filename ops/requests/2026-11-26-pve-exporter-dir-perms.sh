# pve-exporter still couldn't read its token ("Failed to read PVE_TOKEN_VALUE_FILE: Permission denied"):
# 2026-11-26-prometheus-consolidate.sh created /docker/grafana-monitoring/pve-exporter as root 700, so the
# image's user (uid 101) can't enter it to reach the token file (uid 101, 400).
#   1. In CT 101: chown root:101 and chmod 710 that directory, so uid 101 can enter it but not list it.
#      pve.env stays root 600 and unreadable to the container. Reproduced and tested locally with the
#      pinned image: 700 fails with the same error, 710 starts.
#   2. Redeploy monitoring and fail unless Proxmox metrics arrive.
# Undo: chmod 700 /docker/grafana-monitoring/pve-exporter && chown root:root it in CT 101 (pve-exporter stops working).
set -euo pipefail
PVE() { ssh -F "$OPS_SSH_CONFIG" pve "$@"; }
PROM=http://192.168.1.224:9090
D=/docker/grafana-monitoring/pve-exporter

komodo() {
  curl -fsS -m 300 -X POST "$KOMODO_URL/$1/$2" -H "Content-Type: application/json" \
    -H "x-api-key: $KOMODO_API_KEY" -H "x-api-secret: $KOMODO_API_SECRET" -d "$3"
}

echo "== 1. Directory permissions"
PVE "pct exec 101 -- sh -c 'chown root:101 $D && chmod 710 $D'"
PVE "pct exec 101 -- stat -c '  %n %u:%g %a' $D $D/token $D/pve.env"

echo "== 2. Redeploy monitoring and check"
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
PVE "pct exec 101 -- docker restart pve-exporter" >/dev/null  # in case it is in restart backoff
sleep 60
PVE "pct exec 101 -- docker ps -a --filter name=pve-exporter --format '  {{.Names}} {{.Status}}'"
PVE "pct exec 101 -- docker logs --tail 5 pve-exporter" 2>&1 | sed 's/^/    /'
q() { curl -fsS "$PROM/api/v1/query" --data-urlencode "query=$1" | jq -r '.data.result[0].value[1] // "none"'; }
pve_target=$(q 'up{job="pve"}'); node_up=$(q 'max(pve_up{id=~"node/.*"})'); guests=$(q 'count(pve_guest_info)')
echo "  Proxmox: scrape up=$pve_target, node up=$node_up, guests seen=$guests"
[ "$pve_target" = 1 ] && [ "$node_up" = 1 ] && [ "$guests" != none ] && [ "$guests" -ge 1 ] \
  || { echo "CHECK FAILED: Proxmox metrics not arriving"; exit 1; }
echo "  ok"
