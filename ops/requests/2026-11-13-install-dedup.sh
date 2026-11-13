# Installs the hourly lossy-file dedup on docker-prod (LXC 101) and runs the first pass.
#
# What: /root/dedup-mp3s.py (copied from this repo's main), /etc/cron.d/dedup-mp3s (hourly at :20),
#   and one immediate run. The script moves any lossy file (mp3/m4a/aac/ogg/opus) into
#   /data/quarantine/replaced-mp3s/ when a FLAC of the same track or album exists on disk;
#   every move is logged to /data/quarantine/replaced-mp3s/dedup.log. Nothing is deleted.
# Why: Tidarr is replacing the lossy libraries with FLACs (favourites + trickle); this keeps
#   Navidrome free of duplicate lossy/lossless copies as each replacement lands.
# Undo: rm /etc/cron.d/dedup-mp3s /root/dedup-mp3s.py; any moved file can be restored from
#   /data/quarantine/replaced-mp3s/ using dedup.log.
set -eu
ssh -F "$OPS_SSH_CONFIG" pve 'pct exec 101 -- sh -s' <<'EOF'
set -e
curl -fsSL https://raw.githubusercontent.com/dcvdiego/homelab/main/scripts/dedup-mp3s.py -o /root/dedup-mp3s.py
printf '20 * * * * root python3 /root/dedup-mp3s.py >/dev/null 2>&1\n' > /etc/cron.d/dedup-mp3s
chmod 644 /etc/cron.d/dedup-mp3s
echo cron-installed
python3 /root/dedup-mp3s.py
EOF
