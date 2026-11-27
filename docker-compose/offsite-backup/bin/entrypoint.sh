#!/bin/sh
# Runs backup.sh on BACKUP_SCHEDULE with busybox crond (rustic has no scheduler of its own).
# crond starts jobs with an empty environment, so the settings the job needs are handed over in a
# root-only file instead.
set -eu
umask 077
export -p | grep -E '^export (RUSTIC_|RCLONE_|KUMA_PUSH_URL|BACKUP_|MAINTAIN_DAY|CHECK_SUBSET|TZ)' > /run/offsite.env
mkdir -p /etc/crontabs
printf '%s /opt/offsite/backup.sh > /proc/1/fd/1 2>&1\n' "${BACKUP_SCHEDULE:-15 3 * * *}" > /etc/crontabs/root
echo "offsite-backup: schedule '${BACKUP_SCHEDULE:-15 3 * * *}', maintenance on weekday ${MAINTAIN_DAY:-7}"
[ -s "${RCLONE_CONFIG:-/config/rclone/rclone.conf}" ] \
  || echo "offsite-backup: no rclone config yet, runs are skipped until it exists (docs/backups.md)"
exec crond -f -l 8
