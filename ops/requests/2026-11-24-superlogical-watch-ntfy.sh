# Provision ntfy credentials for the superlogical.jobs watcher on agents (CT 102).
# What:
#   - On docker-prod (CT 101): create ntfy user "superlogical-watch" with write-only access to
#     topic "homelab" and issue a bearer token.
#   - On agents (CT 102): write /home/diego/.config/homelab/superlogical-watch.env (diego:diego, 600)
#     with NTFY_URL (read from the ntfy container's NTFY_BASE_URL), NTFY_TOPIC=homelab, and NTFY_TOKEN.
#   - Send a one-time test notification from CT 102 over IPv4 split DNS.
# Why:
#   The daily superlogical-watch systemd user timer on agents (09:00 Europe/London) diffs
#   `ssh superlogical.jobs` and pushes any changes to ntfy.
# Idempotent: keeps existing /home/diego/.config/homelab/superlogical-watch.env if non-empty.
# Undo:
#   pct exec 101 -- docker exec ntfy ntfy user del superlogical-watch
#   pct exec 102 -- rm -f /home/diego/.config/homelab/superlogical-watch.env
ssh -F "$OPS_SSH_CONFIG" pve 'sh -s' <<'SH'
set -eu

env_file=/home/diego/.config/homelab/superlogical-watch.env

if pct exec 102 -- test -s "$env_file"; then
  echo "kept: $env_file already exists on CT 102"
  exit 0
fi

# 1. Provision ntfy user, write-only ACL on homelab, and bearer token on CT 101 (docker-prod)
if pct exec 101 -- docker exec ntfy ntfy user list 2>&1 | grep -q '^user superlogical-watch '; then
  echo "kept: ntfy user superlogical-watch exists"
else
  pct exec 101 -- sh -c 'docker exec -e NTFY_PASSWORD="$(head -c 24 /dev/urandom | base64)" ntfy ntfy user add superlogical-watch >/dev/null'
  echo "added: ntfy user superlogical-watch"
fi

pct exec 101 -- docker exec ntfy ntfy access superlogical-watch homelab wo >/dev/null
echo "access: superlogical-watch write-only on homelab"

tok=$(pct exec 101 -- docker exec ntfy ntfy token add superlogical-watch 2>&1 | grep -oE 'tk_[A-Za-z0-9]+' | head -1)
[ -n "$tok" ] || { echo "error: ntfy token add returned no token"; exit 1; }

ntfy_url=$(pct exec 101 -- docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' ntfy | sed -n 's/^NTFY_BASE_URL=//p' | head -1)
[ -n "$ntfy_url" ] || { echo "error: could not read NTFY_BASE_URL from ntfy container"; exit 1; }

# 2. Write env file on CT 102 (agents) via stdin so secrets never appear on argv or logs
printf 'NTFY_URL=%s\nNTFY_TOPIC=homelab\nNTFY_TOKEN=%s\n' "$ntfy_url" "$tok" \
  | pct exec 102 -- sh -c '
      set -eu
      mkdir -p /home/diego/.config/homelab
      chown diego:diego /home/diego/.config/homelab
      umask 077
      cat > /home/diego/.config/homelab/superlogical-watch.env
      chown diego:diego /home/diego/.config/homelab/superlogical-watch.env
      chmod 600 /home/diego/.config/homelab/superlogical-watch.env
    '
echo "wrote: $env_file ($(pct exec 102 -- stat -c '%U:%G %a' "$env_file"))"

# 3. Verify end-to-end delivery from CT 102 (IPv4 split DNS)
if pct exec 102 -- sh -c '
  set -eu
  set -a; . /home/diego/.config/homelab/superlogical-watch.env; set +a
  curl -4 -fsS --max-time 15 \
    -H "Authorization: Bearer $NTFY_TOKEN" \
    -H "Title: superlogical-watch ready" \
    -H "Tags: white_check_mark" \
    -d "Daily 09:00 UK monitor for ssh superlogical.jobs is wired to ntfy." \
    "$NTFY_URL/$NTFY_TOPIC" >/dev/null
'; then
  echo "test: notification sent from CT 102, check the phone"
else
  echo "test: failed to post to ntfy from CT 102"
  exit 1
fi
SH
