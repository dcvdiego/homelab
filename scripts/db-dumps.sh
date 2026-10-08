#!/bin/bash
# Nightly logical dumps of the databases on docker-prod (LXC 101).
#
# Why: PBS backs up the database files as they are on disk, which is at best crash-consistent.
# A logical dump restores cleanly into any version-compatible server.
# Where: /docker/db-dumps (on the shared /docker disk, so it is picked up by PBS and Backblaze).
# Install: /docker/scripts/db-dumps.sh, run by /etc/cron.d/db-dumps at 01:30 (before Saturday's 02:00 backup).
# Immich is not here: it writes its own dumps to /data/immich/backups.
# Undo: rm /etc/cron.d/db-dumps /docker/scripts/db-dumps.sh (and /docker/db-dumps if unwanted).
#
# Credentials never leave the containers: each dump runs inside its container using that
# container's own environment, so nothing secret is on this script's command line or in its output.

set -uo pipefail

# Optional: KUMA_PUSH_URL (https://status.$DOMAIN/api/push/<token>) for the Uptime Kuma push
# monitor "Backups: database dumps (push)". Kept out of git; the file is root-only.
ENV_FILE=/docker/scripts/db-dumps.env
[ -r "$ENV_FILE" ] && . "$ENV_FILE"

OUT=/docker/db-dumps
KEEP_DAYS=7
STAMP=$(date +%Y%m%d-%H%M)
FAILED=()

mkdir -p "$OUT"
chmod 700 "$OUT"

log() { echo "$(date '+%F %T') $*"; }

# push <up|down> <message>: report to Uptime Kuma. A missed daily push also alerts (monitor interval 25h).
push() {
  [ -n "${KUMA_PUSH_URL:-}" ] || return 0
  curl -fsS -4 -m 20 -o /dev/null -G "$KUMA_PUSH_URL" \
    --data-urlencode "status=$1" --data-urlencode "msg=$2" --data-urlencode "ping=" \
    || log "warn: Uptime Kuma push failed"
}

# finish <name> <tmpfile> <final> <check-regex>
# The dump must be valid gzip, non-empty, and its last lines must match the tool's "completed" marker.
finish() {
  local name=$1 tmp=$2 final=$3 marker=$4
  if gzip -t "$tmp" 2>/dev/null && [ "$(gzip -dc "$tmp" 2>/dev/null | head -c1 | wc -c)" -eq 1 ] \
     && gzip -dc "$tmp" | tail -n 5 | grep -qE "$marker"; then
    mv "$tmp" "$final"
    log "ok   $name $(du -h "$final" | cut -f1)"
  else
    rm -f "$tmp"
    FAILED+=("$name")
    log "FAIL $name (incomplete or empty dump)"
  fi
}

# Postgres: full cluster dump (all databases, roles) as the container's own superuser.
for c in security-postgresql-1 tandoor-db nextcloud-db zulip-database strapiDB; do
  f="$OUT/$c-$STAMP.sql.gz"
  docker exec "$c" sh -c 'pg_dumpall -U "$POSTGRES_USER"' 2>>"$OUT/.errors.log" | gzip > "$f.tmp"
  finish "$c" "$f.tmp" "$f" 'PostgreSQL database cluster dump complete'
done

# MariaDB (notes stack): password passed via MYSQL_PWD inside the container, not on argv.
c=notes-db-1
f="$OUT/$c-$STAMP.sql.gz"
docker exec "$c" sh -c 'D=$(command -v mariadb-dump || command -v mysqldump); MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$D" -uroot --all-databases --single-transaction --routines --events' \
  2>>"$OUT/.errors.log" | gzip > "$f.tmp"
finish "$c" "$f.tmp" "$f" 'Dump completed'

# CouchDB (Obsidian LiveSync): every database as JSON (_all_docs with docs and attachments).
c=obsidian-livesync
f="$OUT/$c-$STAMP.json.gz"
docker exec "$c" sh -c '
  A="$COUCHDB_USER:$COUCHDB_PASSWORD"; U=http://127.0.0.1:5984
  printf "{"; first=1
  for db in $(curl -fsS -u "$A" "$U/_all_dbs" | tr -d "[]\"" | tr "," " "); do
    case "$db" in _*) continue;; esac
    [ $first -eq 1 ] || printf ","; first=0
    printf "\"%s\":" "$db"
    curl -fsS -u "$A" "$U/$db/_all_docs?include_docs=true&attachments=true" || exit 1
  done
  printf "}\n"' 2>>"$OUT/.errors.log" | gzip > "$f.tmp"
finish "$c" "$f.tmp" "$f" '\}$'

# Retention
find "$OUT" -maxdepth 1 -type f \( -name '*.sql.gz' -o -name '*.json.gz' \) -mtime +"$KEEP_DAYS" -delete

if [ ${#FAILED[@]} -gt 0 ]; then
  log "finished with failures: ${FAILED[*]}"
  printf '%s FAILED %s\n' "$(date -Is)" "${FAILED[*]}" > "$OUT/.last-run"
  push down "failed: ${FAILED[*]}"
  exit 1
fi
log "finished: all dumps ok"
printf '%s OK\n' "$(date -Is)" > "$OUT/.last-run"
push up "all dumps ok"
