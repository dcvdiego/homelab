ssh -F "$OPS_SSH_CONFIG" pve 'bash -euo pipefail -s -- arg1' <<'SH'
echo "unterminated
SH
