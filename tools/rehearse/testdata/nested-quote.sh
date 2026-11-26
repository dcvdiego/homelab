PVE() { ssh -F "$OPS_SSH_CONFIG" pve "$@"; }
PVE "pct exec 101 -- sh -c 'echo \"unterminated'"
