# Agent access: one gate, two speeds

Agents (any CLI: Claude Code, opencode, codex, pi, omp, agy) on the agents box (LXC 102) hold **no
host keys, no API tokens and no `.env`**. Every path to a host goes through **Warpgate** (LXC 106),
which holds the host keys, enforces who may reach what, and records every session.

| Mode | When | How | The agent waits? |
|---|---|---|---|
| **Read** | always | `ssh pve-ro`, `docker-prod-ro`, `docker-tower-ro` (read-only `ai-agent`); Prometheus/Loki | no |
| **Attended change** | the owner is watching (debugging, upgrades) | `ssh pve-root`: owner approves on the phone, the approval lasts up to 1 h, the session can be watched live | yes, until approved |
| **Unattended change** | the owner is away | PR from the bot `homelabsito`; owner approves the diff and the deployment later; the runner applies it through Warpgate (`pve-root-ops`) | **no**: it opens the PR and moves on |

```
agents box (LXC 102)                                         Warpgate (LXC 106)            hosts
  agent ── ssh *-ro ─────────────────────────────────────────▶ agent → ai-agent ─────────▶ pvehost, docker-prod, docker-tower
  agent ── ssh pve-root ──▶ (waits) ntfy → owner approves ───▶ agent → root ─────────────▶ pvehost (pct exec → any LXC)
  agent ── git push / gh pr (homelabsito) ──▶ GitHub PR
                owner: review + merge, approve deployment (GitHub Mobile)
                      apply.yml ──▶ ops-runner (docker-tower) ─▶ ops → root (pve-root-ops) ▶ pvehost
                                    └─ Portainer git redeploy, Cloudflare / Technitium APIs
```

## Why each piece exists

| Piece | Stops |
|---|---|
| No keys, tokens or `.env` on the agents box | A prompt-injected agent, or a bad postinstall in one of the five CLIs, finds nothing that writes |
| Warpgate holds every host key; users limited by key **and** source IP | Stealing the agent's key from elsewhere does nothing; one place to revoke; every session recorded |
| `ai-agent` read-only: groups for logs, exact sudo commands, no `docker` group | The read targets can't be turned into root (the old `sudo cat /etc/*` and `sudo journalctl` rules could) |
| `pve-root` needs approval per session, ntfy push to the phone | Root only while the owner has said yes and can watch |
| Bot account `homelabsito` + branch protection | The bot can push branches and open PRs; it can't merge or approve deployments |
| Environment `homelab` with the owner as required reviewer | API write secrets and the ops key reach only jobs from `main` that the owner approved |
| Runner `job-started.sh` guard | Refuses anything except `apply.yml` on `main`: fork PRs on this public repo can't run code on the runner |
| `ops` Warpgate user only from 192.168.1.248, key only in GitHub | A leaked ops key is useless off docker-tower; unattended runs are recorded like any session |
| Request output in `/docker/ops/results`, never in the job log | Job logs on a public repo are public |

**What's left:**
- An approved request or an approved `pve-root` hour is root. The review (diff) or the watching
  (live session) is the control: check that nothing prints or sends a secret.
- Logs and outputs the agent reads can contain attacker-controlled text (Traefik, CrowdSec, public
  services). Fine while that can't lead to a write without the owner.
- The owner's GitHub account and the Warpgate admin login are now the keys to the homelab: passkey
  or TOTP on both (Warpgate admin: TOTP enrolled 2026-10-07).
- Warpgate holds root keys: it lives in its own LXC that only pvehost root can reach.

## Warpgate (LXC 106)

| Target | Logs in as | Who | Approval |
|---|---|---|---|
| `pve-ro`, `docker-prod-ro`, `docker-tower-ro` | `ai-agent` | `agent` (from 192.168.1.226) | none |
| `pve-root` | `root@pvehost` | `agent` | **every session**: waits up to 15 min, ntfy topic `warpgate` pings the owner, who approves in the admin UI (OTP). Scope *Target* remembers it for 1 h |
| `pve-root-ops` | `root@pvehost` | `ops` (from 192.168.1.248, the runner) | none: the GitHub job was already approved |

On the agents box, `~/.ssh/config` maps the aliases to `agent:<target>@warpgate.homelab.lan:2222`
with `~/.ssh/warpgate_agent`.

`ai-agent` is read-only (changed 2026-10-07):
- pvehost: groups `systemd-journal` + `adm` (all journals, `/var/log`); sudo only for
  `pct list|config|status`, `pvesm status`, `pveversion`. The old `sudo cat /etc/*`, `sudo
  journalctl` and `sudo systemctl status *` rules were root-equivalent (wildcards match `..` and
  spaces; pagers spawn shells). Backup: `/root/sudoers-ai-agent.bak-2026-10-07`.
- docker-prod, docker-tower: groups `systemd-journal` + `adm`; sudo only for `docker ps`, `logs`,
  `top`, `stats --no-stream`, `images`, `compose ls`. No `inspect` (prints env = secrets), no `exec`,
  not in the `docker` group.

| | |
|---|---|
| Host | LXC 106 `warpgate`, 192.168.1.227, `warpgate.homelab.lan`. Unprivileged Debian 12, 1 core / 512 MB / 4 GB on `disks`, onboot order 6, in the Sat 02:00 PBS job. Container sshd disabled: manage with `pct exec 106` |
| Warpgate | `/usr/local/bin/warpgate` v0.29.1 (sha256-verified release binary), `warpgate.service` as user `warpgate`, config/db/recordings in `/var/lib/warpgate`. SSH :2222, admin UI https://warpgate.homelab.lan:8888 (self-signed). Host key `SHA256:VFVmrUZB4rfhGN0X5MeYVnU+TG/wev40C6wTECj9g7w` |
| Notifier | `warpgate-approval-notify.service` (`ops/warpgate/approval-notify.py`): reads pending approvals from Warpgate's SQLite read-only, pushes to ntfy topic `warpgate` as ntfy user `warpgate` (write-only). Token in `/etc/warpgate-notify.env` (root, 600) |
| Target keys | Warpgate's client key is in `authorized_keys` of root@pvehost and ai-agent@{pvehost,docker-prod,docker-tower} with `from="192.168.1.227"` (`ops/warpgate/authorize-targets.sh`) |
| Config | `scripts/warpgate-setup.py` (idempotent, needs an admin API token in `~/.config/homelab/warpgate-api-token`) creates the roles, targets and users below. Users are public-key only and limited to one source IP |
| Upgrade | Download the new release binary, check its sha256 against the GitHub release digest, `install -m 755` it over `/usr/local/bin/warpgate`, `systemctl restart warpgate` |

Setup order: `authorize-targets.sh` → `warpgate-setup.py` → connect once to each target →
`warpgate-setup.py --lock-host-keys` (unknown host keys rejected from then on).

## Status

Done 2026-10-07:
- Warpgate installed; all `agent` targets tested from the agents box; `pve-root` approved from the
  phone (ntfy push → admin UI, scope *Target*; a reconnect within the hour skipped the prompt); host
  keys locked (`AutoReject`, known: .148, .224, .248). `pve-root-ops` created, no `ops` user yet.
- `ai-agent` made read-only on pvehost, docker-prod, docker-tower.
- Root on pvehost no longer accepts `homelab_agent`. The owner's WSL uses `~/.ssh/homelab_root`
  (`homelab-root` in `~/.ssh/config`); add a passphrase with `ssh-keygen -p -f ~/.ssh/homelab_root`.
  Backup of the old file: `/root/authorized_keys.bak-2026-10-07`.
- The repo is on the agents box (`~/homelab`, synced from WSL without `.env`, `stack.env`,
  `*.tfvars`, `TODO.md`). Sync by git from now on.

Pending: the PR pipeline (below).

## Setup: PR pipeline (unattended changes)

Run from WSL. Steps 1, 2 and 4 need the owner (accounts, tokens).

### 1. GitHub

```bash
R=dcvdiego/homelab
# a) Create the homelabsito account in a browser (own email, 2FA on), then invite it:
gh api -X PUT repos/$R/collaborators/homelabsito -f permission=push
#    Accept the invite as homelabsito. Create a *classic* PAT for it with only `public_repo`
#    (not `workflow`, so it can't change .github/workflows).

# b) Protect main
gh api -X PUT repos/$R/branches/main/protection --input - <<'EOF2'
{"required_status_checks":null,"enforce_admins":false,"restrictions":null,
 "required_pull_request_reviews":{"required_approving_review_count":1,
   "dismiss_stale_reviews":true,"require_last_push_approval":true},
 "allow_force_pushes":false,"allow_deletions":false}
EOF2

# c) Environment: the owner approves, only protected branches deploy
gh api -X PUT repos/$R/environments/homelab --input - <<EOF2
{"reviewers":[{"type":"User","id":$(gh api user --jq .id)}],"prevent_self_review":false,
 "deployment_branch_policy":{"protected_branches":true,"custom_branch_policies":false}}
EOF2

# d) Fork PRs: Settings > Actions > General > "Require approval for all external contributors"
```

GitHub Mobile: turn on notifications for **Deployment reviews** and **Review requests**.

### 2. Credentials (GitHub environment `homelab` only)

| Secret | How to make it |
|---|---|
| `PORTAINER_TOKEN` | Portainer user `ops` (admin) → Access tokens; revoke this one, not yours, if it leaks |
| `CF_TOKEN` | Cloudflare token: Zone DNS Edit (your zone) + Account Cloudflare Tunnel Edit, client IP filter = home WAN IP |
| `TECHNITIUM_TOWER_TOKEN`, `TECHNITIUM_PROD_TOKEN` | On each instance: user `ops` with modify permission on the zones → Create API token |
| `NTFY_TOKEN` | In the ntfy container: `ntfy user add ops`, `ntfy access ops homelab-ops wo`, `ntfy token add ops` |
| `OPS_SSH_KEY` | The runner's Warpgate key, below |

```bash
ssh-keygen -t ed25519 -N '' -C ops-runner -f /tmp/ops
gh secret set OPS_SSH_KEY --env homelab -R $R < /tmp/ops
install -m 600 /tmp/ops.pub ~/.config/homelab/ops-runner.pub && shred -u /tmp/ops /tmp/ops.pub
scripts/warpgate-setup.py                        # creates Warpgate user ops with that key
for s in PORTAINER_TOKEN CF_TOKEN TECHNITIUM_TOWER_TOKEN TECHNITIUM_PROD_TOKEN NTFY_TOKEN; do
  gh secret set $s --env homelab -R $R; done     # prompts for each value
gh variable set PORTAINER_URL --env homelab -R $R --body https://192.168.1.248:9443
gh variable set NTFY_URL --env homelab -R $R --body "https://ntfy.$(sed -n 's/^DOMAIN=//p' site.env)"
gh variable set WARPGATE_KNOWN_HOSTS --env homelab -R $R --body "$(ssh-keyscan -p 2222 -t ed25519 192.168.1.227 2>/dev/null)"
source ~/homelab/.env && for v in CF_ACCOUNT CF_ZONE CF_TUNNEL; do
  gh variable set $v --env homelab -R $R --body "${!v}"; done
```

For attended `pve-root` sessions that need the same APIs, keep copies of the write tokens in
`/root/homelab.env` on pvehost (root, 600): usable only inside an approved session.

### 3. Deploy the ops stack (docker-tower)

1. `ssh homelab-root 'pct exec 104 -- install -d -o 1001 -g 1001 -m 755 /docker/ops/results'`
2. Portainer → endpoint 2 → Stacks → Add → Repository: this repo, `refs/heads/main`,
   `docker-compose/ops/docker-compose.yml`, env
   `RUNNER_TOKEN=$(gh api -X POST repos/$R/actions/runners/registration-token --jq .token)`.
   **Leave GitOps auto-update off**, here and on every stack: redeploys go through `apply.yml`.
3. Once the runner shows as Idle (Settings → Actions → Runners), delete `RUNNER_TOKEN` from the stack env.

### 4. Agents box

```bash
ssh agents
gh auth login --with-token <<< '<homelabsito PAT>' && gh auth setup-git
git -C ~/homelab config user.name homelabsito
git -C ~/homelab config user.email '<id>+homelabsito@users.noreply.github.com'
```

### 5. End-to-end test

Have an agent open a PR adding `ops/requests/<date>-hello.sh`:

```bash
# Smoke test: read-only checks of every write path. Undo: nothing to undo.
ssh -F "$OPS_SSH_CONFIG" pve pveversion
curl -fsSk -H "x-api-key: $PORTAINER_TOKEN" "$PORTAINER_URL/api/status" | jq -c .Version
```

Approve the PR, merge, approve the deployment. ntfy (`homelab-ops`) reports the result; the agent
reads `ssh docker-tower-ro cat /docker/ops/results/<run id>/<date>-hello.log`.
