# Deploy Komodo Core's compose file from the repo to docker-tower (CT 104): MongoDB 9.0.2 -> 9.0.4
# (Renovate #29, patch release). Komodo can't redeploy itself, so this is the manual step from
# docs/image-versions.md ("Komodo itself"), done as a request.
#
# Checked first (2026-11-07-vikunja-backup-komodo-diff.sh): the host file differs from the repo only in
# its two image lines (host: `mongo` = latest = 9.0.2, `komodo-core:${COMPOSE_KOMODO_IMAGE_TAG:-2}` =
# 2.3.3; repo: the same versions pinned by digest). So the only real change is MongoDB 9.0.2 -> 9.0.4.
#
# Steps: refuse unless the host file still differs only in image lines; mongodump of the Komodo database
# to /etc/komodo/pre-deploy-backups/komodo/<time>/ (CT 104); keep the host file as docker-compose.yml.bak;
# copy the repo file; `docker compose -p komodo up -d`; wait for Core to answer. Periphery is untouched
# (same version on both hosts). Expect Komodo's UI to be unavailable for under a minute.
#
# Undo: in CT 104, `cd /etc/komodo/core && cp docker-compose.yml.bak docker-compose.yml &&
#   docker compose -p komodo --env-file compose.env up -d` (MongoDB 9.0.4 data opens fine on 9.0.2:
#   same featureCompatibilityVersion). Dump restore: `docker exec -i komodo-mongo-1 sh -c 'mongorestore
#   --drop --archive --gzip -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD"' < <file>`.
# Same mode the runner uses (ops/bin/run-requests.sh: bash -euo pipefail), stated here so any failed
# step stops the request.
set -euo pipefail
PVE() { ssh -F "$OPS_SSH_CONFIG" pve "$@"; }
REPO_FILE=docker-compose/komodo/docker-compose.yml
DIR=/etc/komodo/core

grep -q 'image: mongo:9.0.4@' "$REPO_FILE" || { echo "repo file isn't on mongo 9.0.4; nothing done"; exit 1; }

echo "== host file vs repo: only image lines may differ"
PVE "pct exec 104 -- cat $DIR/docker-compose.yml" > /tmp/komodo-core-host.yml
other=$({ diff <(grep -v '^\s*image:' "$REPO_FILE") <(grep -v '^\s*image:' /tmp/komodo-core-host.yml) || true; } | wc -l)
rm -f /tmp/komodo-core-host.yml
if [ "$other" -ne 0 ]; then echo "host file has other changes ($other diff lines); nothing done"; exit 1; fi
echo "ok"

echo "== backup, then deploy (one script, run once in CT 104)"
cat > /tmp/komodo-core-step.sh <<'STEP'
set -eu
cd /etc/komodo/core
out=/etc/komodo/pre-deploy-backups/komodo/$(date +%Y%m%d-%H%M%S)
mkdir -p "$out"; chmod 700 /etc/komodo/pre-deploy-backups
# Credentials from the mongo container's own env; nothing printed
docker exec komodo-mongo-1 sh -c 'exec mongodump --quiet --archive --gzip -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin' > "$out/komodo-mongo.archive.gz"
# Explicit checks: under set -e, a failing left side of `&&` would not stop the script
[ -s "$out/komodo-mongo.archive.gz" ] || { echo "backup is empty; nothing deployed"; exit 1; }
gzip -t "$out/komodo-mongo.archive.gz" || { echo "backup is not valid gzip; nothing deployed"; exit 1; }
echo "backup: $out ($(du -h "$out/komodo-mongo.archive.gz" | cut -f1))"
cp docker-compose.yml docker-compose.yml.bak
mv /root/komodo-core.yml docker-compose.yml
# No pipe, so compose's own exit status counts (sh has no pipefail)
if docker compose -p komodo --env-file compose.env up -d > /tmp/komodo-up.log 2>&1; then
  tail -n 6 /tmp/komodo-up.log; rm -f /tmp/komodo-up.log
else
  tail -n 20 /tmp/komodo-up.log; rm -f /tmp/komodo-up.log
  echo "compose up failed; previous file is docker-compose.yml.bak"; exit 1
fi
STEP
PVE 'cat > /root/komodo-core.yml' < "$REPO_FILE"
PVE 'cat > /root/komodo-core-step.sh' < /tmp/komodo-core-step.sh
rm -f /tmp/komodo-core-step.sh
PVE 'pct push 104 /root/komodo-core.yml /root/komodo-core.yml && pct push 104 /root/komodo-core-step.sh /root/komodo-core-step.sh
     rm -f /root/komodo-core.yml /root/komodo-core-step.sh
     pct exec 104 -- sh /root/komodo-core-step.sh; r=$?
     pct exec 104 -- rm -f /root/komodo-core-step.sh /root/komodo-core.yml
     exit $r'

echo "== check"
up=false
for i in $(seq 1 30); do
  if curl -fsS -m 5 -o /dev/null -X POST -H 'Content-Type: application/json' \
       -H "x-api-key: $KOMODO_API_KEY" -H "x-api-secret: $KOMODO_API_SECRET" \
       -d '{}' "$KOMODO_URL/read/GetVersion"; then
    echo "Core answers after ~$((i * 5))s"; up=true; break
  fi
  sleep 5
done
PVE 'pct exec 104 -- docker ps --filter name=komodo --format "{{.Names}} {{.Image}} {{.Status}}"'
PVE 'pct exec 104 -- docker logs komodo-mongo-1' 2>&1 | grep -o 'buildInfo":{"version":"[0-9.]*' | tail -n 1 || echo "(mongo version not in log yet)"
$up || { echo "Core didn't answer within 150s; previous file is /etc/komodo/core/docker-compose.yml.bak"; exit 1; }
