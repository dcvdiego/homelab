# DNS + overnight schedule for the music stack (docker-compose/music), opened with the music-stack PR.
#
# What it does:
#   1. homelab.lan A records: tidarr + mass -> 192.168.1.224 (docker-prod) on BOTH Technitium
#      instances (tidarr also serves the Traefik router's TLS from LAN via the public path).
#   2. Cloudflare: CNAME tidarr.$DOMAIN -> $CF_TUNNEL (proxied) + tunnel ingress rule
#      tidarr.$DOMAIN -> https://traefik, so Tidarr's UI is reachable externally like Navidrome.
#      Music Assistant stays LAN-only on purpose: host-networked, no Traefik, holds streaming creds.
#   3. /etc/cron.d/tidarr-schedule on docker-prod (LXC 101): docker stop tidarr at 01:00, docker
#      start tidarr at 08:00 — no Tidal downloads while nobody is awake (Tidarr's own sync cron
#      '0 8-23,0 * * *' covers the same window; the UI is also down 01:00–08:00).
#
# Undo: Technitium records/delete for tidarr/mass on both instances; Cloudflare: delete the CNAME
# and PUT the ingress array without the tidarr rule; rm /etc/cron.d/tidarr-schedule on LXC 101.
set -eu

# --- 1. Technitium A records (both instances, idempotent) ---
for pair in "192.168.1.248 $TECHNITIUM_TOWER_TOKEN" "192.168.1.224 $TECHNITIUM_PROD_TOKEN"; do
  read -r host token <<<"$pair"
  for name in tidarr mass; do
    echo -n "technitium $host: $name.homelab.lan -> 192.168.1.224: "
    curl -fsS "http://$host:5380/api/zones/records/add?token=$token&zone=homelab.lan&domain=$name.homelab.lan&type=A&ipAddress=192.168.1.224&ttl=3600&overwrite=true" | jq -c '.status'
  done
done

# --- 2. Cloudflare CNAME + tunnel ingress for tidarr (idempotent) ---
zone_name=$(curl -fsS -H "Authorization: Bearer $CF_TOKEN" "https://api.cloudflare.com/client/v4/zones/$CF_ZONE" | jq -r '.result.name')
fqdn="tidarr.$zone_name"

existing=$(curl -fsS -H "Authorization: Bearer $CF_TOKEN" "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records?name=$fqdn" | jq '.result | length')
if [ "$existing" = "0" ]; then
  echo -n "cloudflare: CNAME $fqdn -> tunnel: "
  curl -fsS -X POST -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
    -d "{\"type\":\"CNAME\",\"name\":\"$fqdn\",\"content\":\"$CF_TUNNEL.cfargotunnel.com\",\"proxied\":true}" \
    "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records" | jq -c '.success'
else
  echo "cloudflare: CNAME $fqdn already exists"
fi

cfg=$(curl -fsS -H "Authorization: Bearer $CF_TOKEN" "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT/cfd_tunnel/$CF_TUNNEL/configurations")
if echo "$cfg" | jq -e --arg h "$fqdn" '.result.config.ingress[]? | select(.hostname == $h)' >/dev/null; then
  echo "cloudflare: tunnel ingress for $fqdn already present"
else
  payload=$(echo "$cfg" | jq --arg h "$fqdn" \
    '.result.config.ingress = ([{hostname: $h, service: "https://traefik", originRequest: {noTLSVerify: true}}] + .result.config.ingress) | {config: .result.config}')
  echo -n "cloudflare: tunnel ingress for $fqdn added: "
  curl -fsS -X PUT -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
    -d "$payload" "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT/cfd_tunnel/$CF_TUNNEL/configurations" | jq -c '.success'
fi

# --- 3. Overnight stop/start for tidarr on docker-prod (idempotent write) ---
echo -n "cron.d tidarr-schedule on docker-prod (LXC 101): "
ssh -F "$OPS_SSH_CONFIG" pve 'pct exec 101 -- sh -s' <<'EOF'
printf '0 1 * * * root docker stop tidarr >/dev/null 2>&1\n0 8 * * * root docker start tidarr >/dev/null 2>&1\n' > /etc/cron.d/tidarr-schedule
chmod 644 /etc/cron.d/tidarr-schedule
echo installed
EOF
