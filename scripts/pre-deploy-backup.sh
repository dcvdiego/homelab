#!/bin/sh
# Komodo pre-deploy backup: runs before every deploy of the stacks listed below, so an upgrade (or any
# redeploy) always has a fresh copy of the data to go back to. The project docs of these apps say to
# back up before updating (docs/image-versions.md); this makes it automatic.
#
# How it runs: Komodo stack config "Pre Deploy" = `sh ../../scripts/pre-deploy-backup.sh <stack>`, set
# by ops/requests/2026-10-24-komodo-pre-deploy-backups.sh. Periphery runs it inside its container, in
# the stack's run directory, with the Docker socket. A non-zero exit stops the deploy (Komodo
# periphery: "Pre Deploy" failure returns before `compose up`), so nothing is upgraded without a backup.
#
# What it writes: /etc/komodo/pre-deploy-backups/<stack>/<YYYYmmdd-HHMMSS>/ on the Docker host (the
# path is bind-mounted into Periphery at the same place), newest 3 kept per stack. The host rootfs is in
# the vzdump/PBS jobs, so these also land in PBS.
#   - Postgres: pg_dumpall inside the DB container (its own credentials, nothing on argv), checked for
#     pg_dumpall's completion marker.
#   - Files: a throwaway alpine container tars the bind-mounted host directory read-only.
#   - Apps with live SQLite (Home Assistant, Vaultwarden, Frigate, Open WebUI) and Matter/Thread state
#     are stopped for the copy so it's consistent, then started again (also if anything fails). Compose
#     recreates them right after anyway when their image or config changed.
#
# Restore: Postgres `gzip -dc <file> | docker exec -i <container> psql -U <user> postgres`; files: stop
# the service, `tar xzf <file> -C <host dir>`, start it.
# Undo: clear "Pre Deploy" on the stacks in Komodo; rm -r /etc/komodo/pre-deploy-backups.
set -eu

STACK=${1:?usage: pre-deploy-backup.sh <komodo stack name>}
ROOT=/etc/komodo/pre-deploy-backups
KEEP=3
HELPER=alpine:3.24.3@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a # renovate: image
OUT=$ROOT/$STACK/$(date +%Y%m%d-%H%M%S)
STOPPED=""

log() { echo "pre-deploy-backup[$STACK]: $*"; }

restart_stopped() {
  for c in $STOPPED; do
    if docker start "$c" >/dev/null 2>&1; then log "started $c"; else log "WARNING: could not start $c"; fi
  done
}
trap restart_stopped EXIT

running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }

# stop <container>...: stop running ones (60s grace) for a consistent copy; restarted on exit
stop() {
  for c in "$@"; do
    if running "$c"; then
      docker stop -t 60 "$c" >/dev/null
      STOPPED="$STOPPED $c"
      log "stopped $c"
    fi
  done
}

# pg <container>: pg_dumpall as the container's POSTGRES_USER
pg() {
  c=$1 f="$OUT/$1.sql.gz"
  if ! running "$c"; then log "skip $c: not running (first deploy?)"; return 0; fi
  docker exec "$c" sh -c 'pg_dumpall -U "$POSTGRES_USER"' | gzip > "$f"
  if ! gzip -dc "$f" | tail -n 5 | grep -q 'PostgreSQL database cluster dump complete'; then
    log "FAIL $c: dump incomplete"; exit 1
  fi
  log "ok $c $(du -h "$f" | cut -f1)"
}

# files <name> <host dir> [tar --exclude patterns...]
# The host dir isn't visible inside Periphery, so a helper container reads it. --mount (unlike -v)
# fails on a missing path instead of creating it.
files() {
  name=$1 src=$2; shift 2
  if ! docker run --rm --network none --mount "type=bind,src=$src,dst=/src,readonly" "$HELPER" true >/dev/null 2>&1; then
    log "skip $name: $src not found"; return 0
  fi
  ex=""
  for p in "$@"; do ex="$ex --exclude=./$p"; done
  # shellcheck disable=SC2086
  docker run --rm --network none --mount "type=bind,src=$src,dst=/src,readonly" \
    --mount "type=bind,src=$OUT,dst=/out" "$HELPER" tar czf "/out/$name.tar.gz" -C /src $ex .
  log "ok $name $(du -h "$OUT/$name.tar.gz" | cut -f1)"
}

mkdir -p "$OUT"
chmod 700 "$ROOT"

case "$STACK" in
  photos)
    pg immich_postgres ;;
  security)
    pg security-postgresql-1
    files authentik /docker/authentik database redis
    stop vaultwarden
    files vaultwarden /docker/vw-data ;;
  haos)
    stop homeassistant zigbee2mqtt matter-server otbr
    files homeassistant /docker/ha 'backups' '*.log' '*.log.*'
    files zigbee2mqtt /docker/zigbee2mqtt/data 'log'
    files matter-server /docker/matter-server/data
    files otbr /docker/otbr/data
    files mosquitto /docker/mosquitto 'log' ;;
  matter-hub)
    stop matter-hub
    files matter-hub /docker/matter-hub ;;
  network-prod|network-tower)
    files technitium /docker/technitium 'logs' 'stats' ;;
  frigate)
    stop frigate
    files frigate-config /docker/frigate/config 'model_cache' ;;
  nextcloud)
    pg nextcloud-db ;;
  zulip)
    pg zulip-database ;;
  recipes)
    pg tandoor-db ;;
  open-webui)
    stop open-webui
    files open-webui /docker/open-webui 'cache' ;;
  *)
    log "no pre-deploy backup configured for this stack"
    rmdir "$OUT" 2>/dev/null || true
    exit 0 ;;
esac

# Keep the newest $KEEP backups of this stack
find "$ROOT/$STACK" -mindepth 1 -maxdepth 1 -type d | sort -r | tail -n +$((KEEP + 1)) | while read -r old; do
  rm -rf "$old"
done
log "done: $OUT"
