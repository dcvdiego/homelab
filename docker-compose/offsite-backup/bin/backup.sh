#!/bin/sh
# One off-site run: back up every snapshot in /etc/rustic/rustic.toml, and on MAINTAIN_DAY also
# forget old snapshots (+ prune) and check the repository, reading CHECK_SUBSET of the pack data.
# Run by cron (entrypoint.sh) or by hand: docker exec offsite-backup /opt/offsite/backup.sh
# Reports to Uptime Kuma (KUMA_PUSH_URL) when set; a missed push alerts too.
set -u
# shellcheck source=/dev/null
[ -r /run/offsite.env ] && . /run/offsite.env
RCLONE_CONFIG=${RCLONE_CONFIG:-/config/rclone/rclone.conf}; export RCLONE_CONFIG
STATE=/cache/state
mkdir -p "$STATE"

log() { echo "$(date '+%F %T') offsite-backup: $*"; }

push() {   # push <up|down> <message>
  [ -n "${KUMA_PUSH_URL:-}" ] || return 0
  msg=$(printf '%s' "$2" | sed 's/%/%25/g; s/ /%20/g; s/&/%26/g; s/+/%2B/g; s/=/%3D/g')
  wget -q -T 20 -O /dev/null "$KUMA_PUSH_URL?status=$1&msg=$msg&ping=" || log "warn: Uptime Kuma push failed"
}

# One run at a time: the first upload takes days, and the daily schedule keeps firing meanwhile.
exec 9>"$STATE/lock"
if ! flock -n 9; then
  log "previous run still going: skipped"
  exit 0
fi

if [ ! -s "$RCLONE_CONFIG" ]; then
  log "no rclone config at $RCLONE_CONFIG: skipped (setup: docs/backups.md)"
  exit 0
fi
if [ -z "${RUSTIC_PASSWORD:-}" ]; then
  log "RUSTIC_PASSWORD is not set: FAILED"; push down "RUSTIC_PASSWORD not set"; exit 1
fi

start=$(date +%s)
log "backup: start"
# --init creates the repository on the very first run only (rustic leaves an existing one alone).
rustic backup --init
rc=$?
case $rc in
  0) result="ok" ;;
  3) result="ok, some files unreadable (see log)" ;;   # rustic >= 0.12: snapshot saved, files skipped
  *) log "backup: FAILED (exit $rc)"; printf '%s FAILED backup exit %s\n' "$(date -Is)" "$rc" > "$STATE/last-run"
     push down "backup failed (exit $rc)"; exit 1 ;;
esac
log "backup: $result"

if [ "$(date +%u)" = "${MAINTAIN_DAY:-7}" ]; then
  log "maintenance: forget + prune"
  if ! rustic forget --prune; then
    printf '%s FAILED forget/prune\n' "$(date -Is)" > "$STATE/last-run"
    push down "forget/prune failed"; exit 1
  fi
  log "maintenance: check (reading ${CHECK_SUBSET:-5%} of pack data)"
  if ! rustic check --read-data --read-data-subset "${CHECK_SUBSET:-5%}"; then
    printf '%s FAILED check\n' "$(date -Is)" > "$STATE/last-run"
    push down "repository check failed"; exit 1
  fi
  result="$result, maintenance ok"
fi

mins=$(( ($(date +%s) - start) / 60 ))
log "finished in ${mins} min: $result"
printf '%s OK %s\n' "$(date -Is)" "$result" > "$STATE/last-run"
push up "$result (${mins} min)"
