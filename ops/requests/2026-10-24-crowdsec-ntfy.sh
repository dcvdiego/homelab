# CrowdSec -> ntfy ban alerts (docker-compose/crowdsec/ntfy-notification.yaml).
# On docker-prod (CT 101): create ntfy user "crowdsec" with write-only access to topic homelab, write
# its token to /docker/crowdsec/secrets/ntfy.env (root, 600; the token never leaves docker-prod and is
# not printed), then restart crowdsec so its entrypoint loads it. Idempotent: an existing token file
# is kept.
# Undo: pct exec 101 -- docker exec ntfy ntfy user del crowdsec
#       pct exec 101 -- rm /docker/crowdsec/secrets/ntfy.env; pct exec 101 -- docker restart crowdsec
ssh -F "$OPS_SSH_CONFIG" pve 'pct exec 101 -- sh -s' <<'SH'
set -eu
f=/docker/crowdsec/secrets/ntfy.env
if [ -s "$f" ]; then
  echo "kept: $f already exists"
  exit 0
fi
if docker exec ntfy ntfy user list 2>&1 | grep -q '^user crowdsec '; then
  echo "kept: ntfy user crowdsec exists"
else
  docker exec -e NTFY_PASSWORD="$(head -c 24 /dev/urandom | base64)" ntfy ntfy user add crowdsec >/dev/null
  echo "added: ntfy user crowdsec"
fi
docker exec ntfy ntfy access crowdsec homelab wo >/dev/null
echo "access: crowdsec write-only on homelab"
tok=$(docker exec ntfy ntfy token add crowdsec 2>&1 | grep -oE 'tk_[A-Za-z0-9]+' | head -1)
[ -n "$tok" ] || { echo "error: ntfy token add returned no token"; exit 1; }
mkdir -p "$(dirname "$f")"
(umask 077; printf 'CROWDSEC_NTFY_TOKEN=%s\n' "$tok" > "$f")
echo "wrote: $f ($(stat -c '%U %a' "$f"))"
docker restart crowdsec >/dev/null
sleep 20
docker exec crowdsec cscli notifications list 2>&1 | grep http_default || true
if docker exec crowdsec cscli notifications test http_default >/dev/null 2>&1; then
  echo "test: notification sent, check the phone"
else
  echo "test: failed, see docker logs crowdsec"
fi
SH
