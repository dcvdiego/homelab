#!/bin/bash
# Nightly logical dumps of the databases on docker-prod (LXC 101).
#
# Why: PBS backs up the database files as they are on disk, which is at best crash-consistent.
# A logical dump restores cleanly into any version-compatible server.
# Where: /docker/db-dumps (on the shared /docker disk, so it is picked up by PBS, Backblaze and the
# off-site rustic repository).
# Install: /docker/scripts/db-dumps.sh, run by /etc/cron.d/db-dumps at 01:30 (before Saturday's 02:00 backup).
# Immich (immich_postgres) is here too, although it writes its own dumps to /data/immich/backups: that job
# had written nothing since 2026-11-07 when checked (2026-11-27), and this dump is the one that goes
# off-site with /docker (docs/backups.md#off-site-rustic--rclone).
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

# skip <container>: true when there is nothing to dump: the container is gone, or it was stopped on
# purpose (exited with code 0, e.g. a stack stopped in Komodo). Its newest dump is then kept past
# retention, so a stopped app keeps one restorable copy. A crashed container (non-zero exit) is
# not skipped: its dump fails and alerts.
SKIPPED=()
skip() {
  local state
  state=$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$1" 2>/dev/null) \
    || { log "skip $1 (no such container)"; return 0; }
  [ "$state" = "exited 0" ] || return 1
  log "skip $1 (stopped)"
  SKIPPED+=("$1")
}

# finish <name> <tmpfile> <final> <dump-exit-code> <check-regex> <last-n-lines>
# The dump command must have exited 0, the file must be valid gzip and non-empty, and its last
# <n> lines must match the tool's "completed" marker (written only when the tool finishes).
finish() {
  local name=$1 tmp=$2 final=$3 rc=$4 marker=$5 lines=$6
  if [ "$rc" -eq 0 ] && gzip -t "$tmp" 2>/dev/null && [ "$(gzip -dc "$tmp" 2>/dev/null | head -c1 | wc -c)" -eq 1 ] \
     && gzip -dc "$tmp" | tail -n "$lines" | grep -qE "$marker"; then
    mv "$tmp" "$final"
    log "ok   $name $(du -h "$final" | cut -f1)"
  else
    rm -f "$tmp"
    FAILED+=("$name")
    log "FAIL $name (exit $rc, or incomplete/empty dump)"
  fi
}

# Postgres: full cluster dump (all databases, roles) as the container's own superuser.
for c in security-postgresql-1 tandoor-db nextcloud-db zulip-database windmill-db immich_postgres; do
  skip "$c" && continue
  f="$OUT/$c-$STAMP.sql.gz"
  docker exec "$c" sh -c 'pg_dumpall -U "$POSTGRES_USER"' 2>>"$OUT/.errors.log" | gzip > "$f.tmp"
  finish "$c" "$f.tmp" "$f" "${PIPESTATUS[0]}" 'PostgreSQL database cluster dump complete' 5
done

# MariaDB: every container from the mariadb image, running or not, so stacks from either repo are
# covered without naming them here (a stopped one fails its dump and alerts, as a named one did).
# Password passed via MYSQL_PWD inside the container, not on argv. The root password env var is
# MARIADB_ROOT_PASSWORD or the older MYSQL_ROOT_PASSWORD.
for c in $(docker ps -a --format '{{.Names}} {{.Image}}' | awk '$2 ~ /^(docker\.io\/(library\/)?)?mariadb[:@]/ {print $1}' | sort); do
  skip "$c" && continue
  f="$OUT/$c-$STAMP.sql.gz"
  docker exec "$c" sh -c 'D=$(command -v mariadb-dump || command -v mysqldump); MYSQL_PWD="${MARIADB_ROOT_PASSWORD:-$MYSQL_ROOT_PASSWORD}" "$D" -uroot --all-databases --single-transaction --routines --events' \
    2>>"$OUT/.errors.log" | gzip > "$f.tmp"
  finish "$c" "$f.tmp" "$f" "${PIPESTATUS[0]}" 'Dump completed' 5
done

# CouchDB (Obsidian LiveSync): every database as JSON (_all_docs with docs and attachments).
# The object's closing brace is written alone on the last line, only after every database was
# fetched (any curl failure exits non-zero first). CouchDB rows never form a bare "}" line, so a
# truncated export can't pass the check.
c=obsidian-livesync
f="$OUT/$c-$STAMP.json.gz"
docker exec "$c" sh -c '
  A="$COUCHDB_USER:$COUCHDB_PASSWORD"; U=http://127.0.0.1:5984
  dbs=$(curl -fsS -u "$A" "$U/_all_dbs") || exit 1
  printf "{\n"; first=1
  for db in $(printf "%s" "$dbs" | tr -d "[]\"" | tr "," " "); do
    case "$db" in _*) continue;; esac
    [ $first -eq 1 ] || printf ",\n"; first=0
    printf "\"%s\":" "$db"
    curl -fsS -u "$A" "$U/$db/_all_docs?include_docs=true&attachments=true" || exit 1
  done
  printf "\n}\n"' 2>>"$OUT/.errors.log" | gzip > "$f.tmp"
finish "$c" "$f.tmp" "$f" "${PIPESTATUS[0]}" '^\}$' 1

# Retention, except the newest dump of each skipped (stopped) container
KEEP=()
for c in ${SKIPPED[@]+"${SKIPPED[@]}"}; do
  n=$(ls -t "$OUT/$c"-[0-9]*.gz 2>/dev/null | head -n1)
  [ -n "$n" ] && KEEP+=("$n")
done
find "$OUT" -maxdepth 1 -type f \( -name '*.sql.gz' -o -name '*.json.gz' \) -mtime +"$KEEP_DAYS" -print0 |
  while IFS= read -r -d '' f; do
    for k in ${KEEP[@]+"${KEEP[@]}"}; do [ "$f" = "$k" ] && continue 2; done
    rm -f -- "$f"
  done

if [ ${#FAILED[@]} -gt 0 ]; then
  log "finished with failures: ${FAILED[*]}"
  printf '%s FAILED %s\n' "$(date -Is)" "${FAILED[*]}" > "$OUT/.last-run"
  push down "failed: ${FAILED[*]}"
  exit 1
fi
[ ${#SKIPPED[@]} -eq 0 ] || log "skipped (stopped): ${SKIPPED[*]}"
log "finished: all dumps ok"
printf '%s OK\n' "$(date -Is)" > "$OUT/.last-run"
push up "all dumps ok"
