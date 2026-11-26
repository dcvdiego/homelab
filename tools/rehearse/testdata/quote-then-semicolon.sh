# a payload followed by "; then" on the next line must not be misread (rehearse-request.py did)
ssh -F "$OPS_SSH_CONFIG" pve 'sh -s' <<'SH'
if pct exec 102 -- sh -c '
  set -eu
  echo hi
'; then
  echo ok
fi
SH
