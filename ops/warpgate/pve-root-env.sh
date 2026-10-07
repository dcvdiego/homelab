#!/usr/bin/env bash
# Put the Cloudflare and Technitium write tokens on pvehost in /root/homelab.env (root, 600), so they
# can only be used inside an approved `ssh pve-root` session. Run from WSL as yourself:
#   bash ops/warpgate/pve-root-env.sh
# - Cloudflare: the CF_* values from .env (replace CF_TOKEN later with a dedicated, IP-filtered token).
# - Technitium: creates user `ops` (group DNS Administrators, not Administrators) on each instance
#   and an API token for it. Re-running replaces the token (and resets that user's random password).
# Nothing is printed except names.
set -euo pipefail
cd "$(dirname "$0")/../.."
set -a; . ./.env; set +a

envf=$(mktemp); trap 'shred -u "$envf" 2>/dev/null || rm -f "$envf"' EXIT; chmod 600 "$envf"
{ echo "# Write tokens for attended pve-root sessions only (docs/agent-access.md). root:root 600."
  echo "# Load with: set -a; . /root/homelab.env; set +a"
  printf 'CF_TOKEN=%s\nCF_ACCOUNT=%s\nCF_ZONE=%s\nCF_TUNNEL=%s\n' "$CF_TOKEN" "$CF_ACCOUNT" "$CF_ZONE" "$CF_TUNNEL"
} > "$envf"

json() { python3 -c "import sys,json; r=json.load(sys.stdin); assert r['status']=='ok', r.get('errorMessage'); print($1)"; }
for pair in "TOWER 192.168.1.248" "PROD 192.168.1.224"; do
  read -r name ip <<<"$pair"
  api="http://$ip:5380/api"
  admin=$(curl -fsS -m 10 "$api/user/login?user=admin&pass=$TECHNITIUM_PASSWORD&includeInfo=false" | json 'r["token"]')
  pass=$(openssl rand -hex 24)
  if curl -fsS -m 10 "$api/admin/users/list?token=$admin" | json '" ".join(u["username"] for u in r["response"]["users"])' | grep -qw ops; then
    curl -fsS -m 10 "$api/admin/users/set?token=$admin&user=ops&newPass=$pass" | json '""' >/dev/null
  else
    curl -fsS -m 10 "$api/admin/users/create?token=$admin&user=ops&pass=$pass&displayName=ops" | json '""' >/dev/null
  fi
  curl -fsS -m 10 "$api/admin/users/set?token=$admin&user=ops&memberOfGroups=DNS%20Administrators" | json '""' >/dev/null
  tok=$(curl -fsS -m 10 "$api/user/createToken?user=ops&pass=$pass&tokenName=pve-root" | json 'r["token"]')
  printf 'TECHNITIUM_%s_URL=http://%s:5380\nTECHNITIUM_%s_TOKEN=%s\n' "$name" "$ip" "$name" "$tok" >> "$envf"
  curl -fsS -m 5 "$api/user/logout?token=$admin" >/dev/null
  echo "$ip: Technitium user ops (DNS Administrators) + token"
done

ssh homelab-root 'install -m 600 -o root -g root /dev/stdin /root/homelab.env && ls -l /root/homelab.env && sed "s/=.*/=…/" /root/homelab.env' < "$envf"
