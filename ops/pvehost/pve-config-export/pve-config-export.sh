#!/bin/bash
# Daily tarball of the Proxmox host config into CT 100's /docker volume, so the off-site rustic backup
# (docker-compose/offsite-backup) carries it: LXC/VM configs, storage.cfg, network, PBS/notification
# config (/etc/pve), the cluster DB, /root (homelab.env, rollback copies) and /usr/local (scripts).
# The weekly pve-host-backup.timer to PBS is unchanged; this is the copy that survives losing the box.
#
# Install: /usr/local/sbin/pve-config-export.sh + pve-config-export.{service,timer} (ops request
# 2026-11-27-offsite-backup.sh). Undo: systemctl disable --now pve-config-export.timer; rm those files
# and /flash/subvols/subvol-100-disk-0/backups/pvehost.
set -euo pipefail

OUT=/flash/subvols/subvol-100-disk-0/backups/pvehost   # = /docker/backups/pvehost in CT 100/101/104
KEEP=14
CT_ROOT=${CT_ROOT:-100000}                                         # root of the unprivileged CTs (uid map 0 -> 100000)
STAMP=$(date +%Y%m%d-%H%M)
TMP=$(mktemp -d /root/.pve-config-export.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

umask 077
install -d -m 700 -o "$CT_ROOT" -g "$CT_ROOT" "$OUT"

# Consistent copy of the cluster DB (/etc/pve is its FUSE view; tar of that is the readable form)
if command -v sqlite3 >/dev/null; then
  sqlite3 /var/lib/pve-cluster/config.db ".backup '$TMP/config.db'"
else
  cp /var/lib/pve-cluster/config.db "$TMP/config.db"
fi

# tar exits 1 when a file changed while read (logs, /etc/pve/.rrd): the archive is still complete
rc=0
tar --create --gzip --file "$OUT/.pvehost-config-$STAMP.tar.gz" \
    --warning=no-file-changed --warning=no-file-removed --one-file-system \
    --exclude=/root/.cache --exclude='/root/.pve-config-export.*' \
    /etc /etc/pve /root /usr/local -C "$TMP" config.db 2>&1 || rc=$?
[ "$rc" -le 1 ] || { echo "tar failed (exit $rc)"; exit 1; }
gzip -t "$OUT/.pvehost-config-$STAMP.tar.gz"

chown "$CT_ROOT:$CT_ROOT" "$OUT/.pvehost-config-$STAMP.tar.gz"
mv "$OUT/.pvehost-config-$STAMP.tar.gz" "$OUT/pvehost-config-$STAMP.tar.gz"
# shellcheck disable=SC2012  # names are ours: pvehost-config-<digits>-<digits>.tar.gz
ls -t "$OUT"/pvehost-config-*.tar.gz | tail -n +$((KEEP + 1)) | xargs -r rm -f --
echo "ok $(du -h "$OUT/pvehost-config-$STAMP.tar.gz" | cut -f1) $OUT/pvehost-config-$STAMP.tar.gz"
