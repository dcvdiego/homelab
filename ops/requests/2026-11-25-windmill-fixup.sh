# Finish what ops/requests/2026-11-25-windmill.sh (run 45658103634) didn't. That run created the
# Komodo stack and the homelab.lan records, then stopped: its config read-back check failed, and
# the traefik stack's DOMAIN is single-quoted ('…'), which it passed to Technitium unstripped, so the
# windmill.$DOMAIN records errored. The first deploys also failed, for two reasons:
#   - /docker/windmill/db was root 700, and the postgres image (uid 999) can't enter it;
#   - "db" resolved to another stack's DB on network_default (fixed in the compose in this PR).
# Done by hand on 2026-11-25 over pve-root: chown 999:999 /docker/windmill/db, and both
# windmill.$DOMAIN records added on both Technitium instances.
#
# This request, after the apply job's redeploy step has deployed the fixed compose:
# 1. CT 101: /docker/windmill/db owned by 999:999 (idempotent, for the record).
# 2. Waits for Windmill through Traefik, then, only if the default admin@windmill.dev / changeme
#    still works: instance setting Base Url = https://windmill.$DOMAIN, and a random password for that
#    user, saved first in CT 101 /root/windmill-initial-password (600) and never printed.
#
# Undo: Instance settings > Core > Base Url in the UI; the password is changed again from the UI.
set -u
PVE() { ssh -F "$OPS_SSH_CONFIG" pve "$@"; }

echo "== 1. CT 101: data dir owner"
PVE 'pct exec 101 -- sh -c "chown 999:999 /docker/windmill/db && ls -lnd /docker/windmill/db"' \
  || { echo "chown: FAILED"; exit 1; }

echo "== 2. Base Url, default superadmin password"
# DOMAIN from the stack's own .env (Komodo wrote it), quotes stripped. Never printed.
D=$(PVE 'pct exec 101 -- sed -n "s/^DOMAIN=//p" /etc/komodo/stacks/windmill/docker-compose/windmill/.env' \
      | tr -d "\"' \r\n")
case "$D" in *.*) ;; *) echo "DOMAIN: not readable from the stack's .env"; exit 1 ;; esac
W="https://windmill.$D"
# Through Traefik on docker-prod (forced IPv4 + --resolve: never out through Cloudflare)
CURL() { curl -4 -fsS --max-time 20 --resolve "windmill.$D:443:192.168.1.224" "$@"; }
up=no
for _ in $(seq 1 300); do
  if CURL -o /dev/null "$W/api/version" 2>/dev/null; then up=yes; break; fi
  sleep 1
done
[ "$up" = yes ] && echo "windmill: up ($(CURL "$W/api/version"))" \
  || { echo "windmill: not reachable through Traefik after 5 min"; PVE 'pct exec 101 -- docker ps -a --filter name=windmill --format "{{.Names}}: {{.Status}}"'; exit 1; }

TOKEN=$(CURL -X POST -H 'Content-Type: application/json' \
          -d '{"email":"admin@windmill.dev","password":"changeme"}' "$W/api/auth/login" 2>/dev/null) || TOKEN=
if [ -z "$TOKEN" ]; then
  echo "superadmin: default login refused: already changed; password and Base Url left as they are"
  exit 0
fi
umask 077
trap 'rm -f /tmp/wm-auth /tmp/wm-body' EXIT
printf 'Authorization: Bearer %s\n' "$TOKEN" > /tmp/wm-auth

if CURL -X POST -H 'Content-Type: application/json' -H @/tmp/wm-auth \
     -d "{\"value\":\"$W\"}" -o /dev/null "$W/api/settings/global/base_url"; then
  echo "instance setting base_url: set to https://windmill.\$DOMAIN"
else
  echo "instance setting base_url: FAILED (set it in Instance settings > Core > Base Url)"
fi

NEWPW=$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')
# Saved in CT 101 first, so a set password is never one nobody has
if ! printf '%s\n' "$NEWPW" | PVE 'set -e; umask 077; cat > /root/wm-pw
       pct push 101 /root/wm-pw /root/windmill-initial-password --perms 600 --user 0 --group 0
       rm -f /root/wm-pw'; then
  echo "superadmin: could not save a new password in CT 101; default left: change it at first sign-in"
  exit 1
fi
printf '{"password":"%s"}' "$NEWPW" > /tmp/wm-body
if CURL -X POST -H 'Content-Type: application/json' -H @/tmp/wm-auth --data-binary @/tmp/wm-body \
     -o /dev/null "$W/api/users/setpassword"; then
  echo "superadmin admin@windmill.dev: password replaced; it's in CT 101 /root/windmill-initial-password"
else
  PVE 'pct exec 101 -- rm -f /root/windmill-initial-password'
  echo "superadmin: setpassword FAILED (default password still active: change it at first sign-in)"
  exit 1
fi
CURL -X POST -H @/tmp/wm-auth -o /dev/null "$W/api/auth/logout" || true
PVE 'pct exec 101 -- docker ps --filter name=windmill --format "{{.Names}}: {{.Status}}"'
