# Retry of 2026-11-27-warpgate-inactivity-timeout.sh, which stopped before changing anything:
# pct exec runs with a minimal PATH (no /usr/local/bin), so `warpgate check` was "not found".
# Same steps, with the binary's full path (/usr/local/bin/warpgate, docs/agent-access.md).
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
  pid=$(systemctl show -p MainPID --value warpgate)
  if [ "$pid" != 0 ] && [ "$f" -nt "/proc/$pid" ]; then   # set, but warpgate started before the change
    echo "  already 30m, but warpgate was started before the change: restart needed"
    touch /run/warpgate-restart-needed
  else
    echo "  already 30m and running with it"
  fi
  exit 0
fi
grep -q '^  inactivity_timeout: ' "$f" || { echo "  no ssh.inactivity_timeout line in $f"; exit 1; }
cp -p "$f" "$f.bak-$(date +%Y%m%d-%H%M%S)"
sed 's/^  inactivity_timeout: .*/  inactivity_timeout: 30m/' "$f" > "$f.new"
if ! /usr/local/bin/warpgate --config "$f.new" --skip-securing-files check >/dev/null 2>&1; then   # validate before touching the live file
  echo "  warpgate check failed on the new config; live config unchanged:"
  /usr/local/bin/warpgate --config "$f.new" --skip-securing-files check 2>&1 | tail -5 | sed 's/^/    /'
  rm -f "$f.new"; exit 1
fi
cat "$f.new" > "$f" && rm -f "$f.new"   # rewrite in place: keeps owner and mode
echo "  set: $(grep '^  inactivity_timeout: ' "$f" | xargs)"
touch /run/warpgate-restart-needed
SH

echo "== 2. Restart and verify"
# The restart may cut this session before it closes; the verification below decides.
PVE 'pct exec 106 -- sh -s' <<'SH' || echo "  (session ended by the restart)"
set -eu
if [ -e /run/warpgate-restart-needed ]; then
  rm -f /run/warpgate-restart-needed
  systemctl show -p MainPID --value warpgate > /run/warpgate-pid-before
  setsid sh -c 'sleep 10; systemctl restart warpgate' </dev/null >/dev/null 2>&1 &
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
# restarted: the main PID changed since step 2 (no PID file: no restart was needed)
if [ -e /run/warpgate-pid-before ]; then
  [ "$(systemctl show -p MainPID --value warpgate)" != "$(cat /run/warpgate-pid-before)" ] && echo restarted || echo not-restarted
else
  echo restarted
fi
SH
  ); then
    echo "$out" | sed 's/^/  /'
    if echo "$out" | grep -qx active && echo "$out" | grep -q 'inactivity_timeout: 30m' && echo "$out" | grep -qx restarted; then
      PVE 'pct exec 106 -- rm -f /run/warpgate-pid-before' || true
      echo "  ok"; exit 0
    fi
  fi
  sleep 10
done
echo "CHECK FAILED: warpgate not restarted and active with inactivity_timeout 30m (see undo above)"
exit 1
