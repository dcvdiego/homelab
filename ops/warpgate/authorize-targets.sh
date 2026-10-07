#!/usr/bin/env bash
# Let Warpgate (LXC 106, 192.168.1.227) log in to its targets. Run from WSL as yourself:
#   bash ops/warpgate/authorize-targets.sh
# Adds Warpgate's client key, usable only from 192.168.1.227, to:
#   root@pvehost (target pve-root) and ai-agent on pvehost, docker-prod, docker-tower (the *-ro targets).
# Idempotent. Root's authorized_keys is a symlink into /etc/pve/priv, so it's appended to, never replaced.
set -euo pipefail
KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJgP7c5WUtIgMM9mHrjVRFw2Lq7vgrtcx2AduKvVu1vR'
LINE="from=\"192.168.1.227\",no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc $KEY warpgate"
# ssh joins its arguments into one string that the remote shell re-splits, so pass the values
# %q-quoted as environment assignments instead of positional arguments.
ssh homelab-root "KEY=$(printf %q "$KEY") LINE=$(printf %q "$LINE") bash -s" <<'REMOTE'
set -euo pipefail
add() { grep -qF "$KEY" "$1" && echo "already: $2" || { printf '%s\n' "$LINE" >> "$1"; echo "added: $2"; }; }
add /root/.ssh/authorized_keys "root@pvehost"
add ~ai-agent/.ssh/authorized_keys "ai-agent@pvehost"
for id in 101 104; do
  pct exec "$id" -- bash -c "$(declare -f add); KEY='$KEY'; LINE='$LINE'; add ~ai-agent/.ssh/authorized_keys ai-agent@ct$id"
done
REMOTE
