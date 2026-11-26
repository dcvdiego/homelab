# `command -v rsync` only checks that rsync exists
ssh -F "$OPS_SSH_CONFIG" pve "command -v rsync >/dev/null || echo no rsync"
