# Warpgate drops an SSH session after ssh.inactivity_timeout (5m) with no output from the target;
# client keepalives don't count (tested 2026-11-27: a quiet session with ServerAliveInterval=30 was
# cut at exactly 300 s, one receiving a log line a minute lasted 400 s). That is what cut PR #74's
# silent tar. Raise it to 30m so quiet work up to 30 min (archives, dumps, pulls) survives.
#   1. In CT 106: back up /var/lib/warpgate/warpgate.yaml, set ssh.inactivity_timeout: 30m
#      (validated with `warpgate check` first, then written in place to keep the file's owner).
#   2. Restart warpgate.service detached (this session goes through Warpgate), then reconnect and
#      verify the service is active and the value is set.
# Effect on people: a human session left idle is also closed after 30 min instead of 5.
# Undo: in CT 106, copy the warpgate.yaml.bak-<timestamp> back and `systemctl restart warpgate`.
set -euo pipefail
PVE() { ssh -F "$OPS_SSH_CONFIG" pve "$@"; }

echo "== 1. Config"
PVE 'pct exec 106 -- sh -s' <<'SH'
set -eu
f=/var/lib/warpgate/warpgate.yaml
if grep -q '^  inactivity_timeout: 30m$' "$f"; then
  echo "  already 30m"
  exit 0
fi
grep -q '^  inactivity_timeout: ' "$f" || { echo "  no ssh.inactivity_timeout line in $f"; exit 1; }
cp -p "$f" "$f.bak-$(date +%Y%m%d-%H%M%S)"
sed 's/^  inactivity_timeout: .*/  inactivity_timeout: 30m/' "$f" > "$f.new"
if ! warpgate --config "$f.new" --skip-securing-files check >/dev/null 2>&1; then   # validate before touching the live file
  echo "  warpgate check failed on the new config; live config unchanged:"
  warpgate --config "$f.new" --skip-securing-files check 2>&1 | tail -5 | sed 's/^/    /'
  rm -f "$f.new"; exit 1
fi
cat "$f.new" > "$f" && rm -f "$f.new"   # rewrite in place: keeps owner and mode
echo "  set: $(grep '^  inactivity_timeout: ' "$f" | xargs)"
touch /run/warpgate-restart-needed
SH

echo "== 2. Restart and verify"
PVE 'pct exec 106 -- sh -s' <<'SH'
set -eu
if [ -e /run/warpgate-restart-needed ]; then
  rm -f /run/warpgate-restart-needed
  setsid sh -c 'sleep 3; systemctl restart warpgate' </dev/null >/dev/null 2>&1 &
  echo "  restart scheduled"
else
  echo "  no change, no restart"
fi
SH
sleep 20
for _ in 1 2 3 4 5 6; do
  if out=$(PVE 'pct exec 106 -- sh -s' <<'SH'
set -eu
systemctl is-active warpgate
grep '^  inactivity_timeout: ' /var/lib/warpgate/warpgate.yaml | xargs
SH
  ); then
    echo "$out" | sed 's/^/  /'
    echo "$out" | grep -qx active && echo "$out" | grep -q 'inactivity_timeout: 30m' && { echo "  ok"; exit 0; }
  fi
  sleep 10
done
echo "CHECK FAILED: warpgate not active with inactivity_timeout 30m (see undo above)"
exit 1
