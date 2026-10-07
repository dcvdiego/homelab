# agents (LXC 102)

Headless box that runs coding agents in **herdr**, driven from the phone with **Collie**, with
**CodexBar** tracking every subscription's quota and pushing alerts through Collie.

| | |
|---|---|
| VMID / host | 102 / `agents` (was `docker-dev`) |
| IP | 192.168.1.226 static, `agents.homelab.lan` (Technitium) |
| Resources | 4 cores, 6 GB RAM, 2 GB swap, 32 GB rootfs on `disks` |
| OS | Ubuntu 24.04 (upgraded from 22.04 on 2026-10-04; needs pve-container ≥ 5.3, i.e. PVE ≥ 8.4), unprivileged, nesting, `/dev/net/tun` passed through |
| Access | `ssh agents` (diego, key `~/.ssh/homelab_agent`), Tailscale `agents` |
| Dotfiles | chezmoi `dcvdiego/dotfiles`, role `agents` (hostname-detected) |
| Homelab access | Through Warpgate only: `ssh pve-ro`/`docker-*-ro` (read), `ssh pve-root` (approved on the phone); unattended changes as `homelabsito[bot]` PRs. No `.env`, no host keys. See [agent-access.md](agent-access.md) |

## What runs

| Thing | How | Notes |
|---|---|---|
| herdr | `systemd --user` `herdr-server` (`herdr server`) | Agent panes live here and survive detach/reboot. `herdr` to attach. |
| Collie | `systemd --user` `collie` + `tailscale serve` :443 → 127.0.0.1:8787 | Phone UI + Web Push. Tailnet only, never `funnel`. |
| CodexBar dashboard | `systemd --user` `codexbar-serve` on 127.0.0.1:8080 | `ssh -L 8080:127.0.0.1:8080 agents` → http://localhost:8080 |
| CodexBar watcher | `systemd --user` `codexbar-watch` | Polls every 5 min, runs `~/.local/bin/quota-notify` → `collie push test` |
| Agents | `claude` (native installer); `opencode` v2, `pi`, `codex` (mise npm); `omp` (mise github); `agy` Antigravity CLI (official installer) | GPT + GLM are driven from opencode/pi/omp; `codex` is installed so CodexBar can read the ChatGPT quota. |

Linger is enabled for diego, so user services run without a login session.

Tracked providers: `claude`, `codex`, `antigravity`, `zai`, `opencodego`. Alerts fire on
`quota_low` (80%), `quota_reached`, `quota_reset`, `refresh_failed` (usually means a re-login).
Rules are merged into `~/.config/codexbar/config.json` by the dotfiles setup script; API keys in
that file are not managed by chezmoi.

## Logins (once, interactive)

```bash
ssh -t agents
claude                                   # /login, pick Claude account (Pro)
codex login --device-auth                # ChatGPT Plus; CodexBar reads ~/.codex/auth.json
agy                                      # Sign in with Google (AI Plus); Gemini CLI no longer serves personal plans
opencode auth login                      # v2: OpenAI (ChatGPT Plus), Z.ai Coding Plan, OpenCode Go
pi                                       # /login -> ChatGPT; Z.ai via API key
omp                                      # /login -> ChatGPT; Z.ai via API key
printf '%s' 'ZAI_KEY' | codexbar config set-api-key --provider zai --stdin
echo 'OPENCODE_API_KEY=...' >> ~/.config/codexbar/env && chmod 600 ~/.config/codexbar/env
systemctl --user restart codexbar-serve codexbar-watch
codexbar usage                           # every provider should show windows + resets
```

`~/.local/bin/xdg-open` is a shim that prints the URL, so CLIs that try to open a browser just show
the link. Headless OAuth that redirects to `localhost:<port>`: tunnel that port from the laptop
(`ssh -L <port>:localhost:<port> agents`) and open the printed URL locally.

## Rebuild from scratch

As root on pvehost: `pct create` an Ubuntu/Debian LXC with the settings above, append
`lxc.cgroup2.devices.allow: c 10:200 rwm` and
`lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file` to `/etc/pve/lxc/102.conf`.
Inside as root: `apt install openssh-server zsh git curl file build-essential procps unzip`,
create `/home/linuxbrew` owned by diego, install Tailscale, `loginctl enable-linger diego`,
`tailscale up --operator=diego --hostname=agents`. Then as diego:

```bash
sh -c "$(curl -fsLS get.chezmoi.io)" -- -b ~/.local/bin
~/.local/bin/chezmoi init --apply dcvdiego
collie start                             # pick herdr; then collie pair on the phone
```

## History / gotchas

- 2026-10-04: upgraded 22.04 → 24.04 (PBS backup "pre 24.04 upgrade 2026-10-04"). PVE 8.2's pve-container
  5.0.10 refused to start it ("unsupported Ubuntu version"); fixed by upgrading the host to 8.4.
- 2026-10-04: repurposed from docker-dev. Pre-change config at `/root/102.conf.bak-2026-10-04`
  on pvehost; rootfs backup on `pbs-lxc` ("pre-agents repurpose 2026-10-04").
- docker-dev used to mount `data:100/vm-100-disk-0.raw` (/data) and
  `disks:100/vm-100-disk-1.raw` (/docker), the **same images vault/docker-prod/docker-tower mount**.
  Those mounts were removed and the resulting `unusedN` lines deleted from the config. Never
  re-add them, and never "Remove" an unused disk pointing at `vm-100-*` from the UI: that deletes
  the production volume.
- opencode v2 is `npm:@opencode/cli` via mise with `npm.package_manager = "npm"` and
  `npm_args = "--ignore-scripts=false"` for that one package: its postinstall links the native
  binary, and mise's default installer skips lifecycle scripts.
- An old `cloudflared-tunnel` container auto-started on first boot and was removed with the other
  docker-dev containers (mc, servarr, tandoor, portainer agent). Portainer endpoint 4 is retired.
