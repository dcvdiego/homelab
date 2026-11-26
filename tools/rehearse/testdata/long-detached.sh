# the PR #75 fix: tar under setsid is fine; the rsync after it is not; file names are not commands
ssh -F "$OPS_SSH_CONFIG" pve "pct exec 101 -- sh -c 'cd /d
  setsid sh -c \"tar czf /a.tar.gz b && mv /a.tar.gz /c\" </dev/null >/dev/null 2>&1 &
  rm -f /old.tar.gz
  rsync -a /x /y'"
