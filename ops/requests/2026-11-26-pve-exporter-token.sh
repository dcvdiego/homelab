# pve-exporter never started: its token was passed with env_file at /docker/grafana-monitoring/..., but
# Komodo runs compose inside the periphery container, which only mounts /etc/komodo, so compose couldn't
# see the file and (required: false) silently skipped it. The exporter then looked for /etc/prometheus/pve.yml
# and crash-looped. The stack now mounts the directory and reads PVE_TOKEN_VALUE_FILE=/run/pve/token.
#   1. In CT 101, write the token value alone to /docker/grafana-monitoring/pve-exporter/token
#      (uid 101 = the image's user, mode 400) from the existing pve.env, then delete pve.env.
#      The value is never printed.
#   2. Redeploy monitoring and fail unless Proxmox metrics arrive.
# Undo: revert this PR. The token keeps working; to remove it: pveum user delete prometheus@pve on pvehost.
set -euo pipefail
PVE() { ssh -F "$OPS_SSH_CONFIG" pve "$@"; }
PROM=http://192.168.1.224:9090
D=/docker/grafana-monitoring/pve-exporter

komodo() {
  curl -fsS -m 300 -X POST "$KOMODO_URL/$1/$2" -H "Content-Type: application/json" \
    -H "x-api-key: $KOMODO_API_KEY" -H "x-api-secret: $KOMODO_API_SECRET" -d "$3"
}

echo "== 1. Token file"
if PVE "pct exec 101 -- test -s $D/token"; then
  echo "  token already there"
else
  PVE "pct exec 101 -- sh -c 'set -e; umask 077
    v=\$(sed -n \"s/^PVE_TOKEN_VALUE=//p\" $D/pve.env); [ -n \"\$v\" ]
    printf %s\\\\n \"\$v\" > $D/token.tmp && chown 101:101 $D/token.tmp && chmod 400 $D/token.tmp
    mv $D/token.tmp $D/token && rm -f $D/pve.env'" \
    || { echo "  could not read PVE_TOKEN_VALUE from $D/pve.env"; exit 1; }
  echo "  token written ($D/token, uid 101, 400); pve.env removed"
fi
PVE "pct exec 101 -- stat -c '  %n %U:%G %a %s bytes' $D/token"

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
sleep 60
PVE "pct exec 101 -- docker ps -a --filter name=pve-exporter --format '  {{.Names}} {{.Status}}'"
PVE "pct exec 101 -- docker logs --tail 5 pve-exporter" 2>&1 | sed 's/^/    /'
q() { curl -fsS "$PROM/api/v1/query" --data-urlencode "query=$1" | jq -r '.data.result[0].value[1] // "none"'; }
pve_target=$(q 'up{job="pve"}'); node_up=$(q 'max(pve_up{id=~"node/.*"})'); guests=$(q 'count(pve_guest_info)')
echo "  Proxmox: scrape up=$pve_target, node up=$node_up, guests seen=$guests"
[ "$pve_target" = 1 ] && [ "$node_up" = 1 ] && [ "$guests" != none ] && [ "$guests" -ge 1 ] \
  || { echo "CHECK FAILED: Proxmox metrics not arriving"; exit 1; }
echo "  ok"
