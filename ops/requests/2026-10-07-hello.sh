# Smoke test of the unattended path: runner -> Warpgate (user ops, target pve-root-ops) -> pvehost,
# plus the API tokens the runner holds. Read-only; nothing to undo.
echo "== pvehost via Warpgate"
ssh -F "$OPS_SSH_CONFIG" pve 'hostname; whoami; pveversion; echo "$(pct list | tail -n +2 | wc -l) containers"'
echo "== Technitium tokens"
for pair in "192.168.1.248 $TECHNITIUM_TOWER_TOKEN" "192.168.1.224 $TECHNITIUM_PROD_TOKEN"; do
  read -r host token <<<"$pair"
  curl -fsS -m 10 "http://$host:5380/api/zones/list?token=$token" | jq -r --arg h "$host" '"\($h): \(.status), \(.response.zones | length) zones"'
done
echo "== Cloudflare token"
curl -fsS -m 10 -H "Authorization: Bearer $CF_TOKEN" https://api.cloudflare.com/client/v4/user/tokens/verify | jq -r .result.status
