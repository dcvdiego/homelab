#!/usr/bin/env bash
# Wire the homelabsito GitHub App into the agents box (run there, as the agent user). Idempotent.
#   scripts/homelabsito-setup.sh <bot-user-id>
# Needs ~/.config/homelabsito/{app-id,app.pem} (put there by the owner) and gh installed
# (brew install gh). Afterwards, inside ~/homelab only, `git push` and `gh pr create` act as
# homelabsito[bot] with 1-hour tokens; elsewhere gh and git behave as before.
set -euo pipefail
bot_id=${1:?usage: $0 <bot-user-id>  (gh api users/homelabsito%5Bbot%5D --jq .id)}
repo_dir="$HOME/homelab"
real_gh=$(type -ap gh | grep -v "^$HOME/.local/bin/gh$" | head -1 || true)
for c in /home/linuxbrew/.linuxbrew/bin/gh /usr/local/bin/gh /usr/bin/gh; do   # non-login PATHs lack brew
  [ -z "$real_gh" ] && [ -x "$c" ] && real_gh=$c
done
[ -n "$real_gh" ] || { echo "install gh first (brew install gh)"; exit 1; }
test -r "$HOME/.config/homelabsito/app.pem" -a -r "$HOME/.config/homelabsito/app-id"

install -d -m 755 "$HOME/.local/bin"
install -m 755 "$repo_dir/scripts/gh-app-token" "$HOME/.local/bin/gh-app-token"
cat > "$HOME/.local/bin/gh" <<EOF
#!/usr/bin/env bash
# gh wrapper (scripts/homelabsito-setup.sh): inside ~/homelab, act as the homelabsito GitHub App.
top=\$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "\${GH_TOKEN:-}" ] && [ "\$top" = "$repo_dir" ]; then
  GH_TOKEN=\$("$HOME/.local/bin/gh-app-token") || exit 1; export GH_TOKEN
fi
exec "$real_gh" "\$@"
EOF
chmod 755 "$HOME/.local/bin/gh"

cd "$repo_dir"
git config --unset-all credential.https://github.com.helper 2>/dev/null || true
git config --add credential.https://github.com.helper ''   # drop inherited helpers for this repo
git config --add credential.https://github.com.helper \
  '!f() { test "$1" = get && printf "username=x-access-token\npassword=%s\n" "$("$HOME/.local/bin/gh-app-token")"; }; f'
git config user.name 'homelabsito[bot]'
git config user.email "${bot_id}+homelabsito[bot]@users.noreply.github.com"
echo "homelabsito wired: gh -> $real_gh via wrapper, git credential helper + identity set in $repo_dir"
