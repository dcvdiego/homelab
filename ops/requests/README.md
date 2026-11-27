# Ops requests

Anything an agent can't do with read-only access (the `*-ro` Warpgate targets) is proposed as a request: a
shell script in this directory, opened as a PR by the GitHub App `homelabsito[bot]`. Nothing runs
until the owner **approves the PR** and then **approves the deployment** in GitHub Mobile. Then the
`homelab-ops` runner on docker-tower runs it once (`.github/workflows/apply.yml`). Use this when the
owner isn't watching; for live work use `ssh pve-root` instead (see AGENTS.md).

## Writing one

- File name: `YYYY-MM-DD-<slug>.sh`, e.g. `2026-10-06-add-grafana-dns.sh`. Only **new** files run;
  editing a merged request does nothing, so add a new one to retry.
- Start with a comment block: what it changes, why, how to undo it.
- Make it idempotent and **read before write** (GET the current state, change only what differs).
- Print what changed. Output lands in `/docker/ops/results/<run id>/<name>.log` on docker-tower and
  agents read it with `ssh docker-tower-ro cat …`. **Never print secrets**: anything the script
  prints, agents can read.
- Changes to compose files don't need a request: merging them redeploys the git-backed stack.

## What a request can use

| Variable | What |
|---|---|
| `CF_TOKEN`, `CF_ACCOUNT`, `CF_ZONE`, `CF_TUNNEL` | Cloudflare DNS edit + tunnel config for the zone |
| `TECHNITIUM_TOWER_TOKEN`, `TECHNITIUM_PROD_TOKEN` | Technitium API tokens for `192.168.1.248:5380` and `192.168.1.224:5380` |
| `KOMODO_URL`, `KOMODO_API_KEY`, `KOMODO_API_SECRET` | Komodo API (service user `ops`, admin) |
| `OPS_SSH_CONFIG` | `ssh -F "$OPS_SSH_CONFIG" pve '<cmd>'` runs as root on pvehost through Warpgate (`pct exec`, `pct push`); recorded like any other session |

Tools on the runner: `bash`, `curl`, `jq`, `python3`, `git`, `ssh`.

## Example

```bash
# Add frigate.homelab.lan -> 192.168.1.224 on both Technitium instances.
# Undo: same call with /api/zones/records/delete.
for pair in "192.168.1.248 $TECHNITIUM_TOWER_TOKEN" "192.168.1.224 $TECHNITIUM_PROD_TOKEN"; do
  read -r host token <<<"$pair"
  curl -fsS "http://$host:5380/api/zones/records/add?token=$token&zone=homelab.lan&domain=frigate.homelab.lan&type=A&ipAddress=192.168.1.224&ttl=3600&overwrite=true" | jq -c '.status'
done
```

## Reviewing (owner)

Read it like code that runs as root. In particular, check that it doesn't print or send a
secret anywhere (`echo $CF_TOKEN`, `curl` to a host that isn't yours, writing it into the
results dir) and that the change matches the PR description.

## Writing remote commands

Send each remote script as a heredoc with a quoted delimiter, so nothing is nested inside a
string and no quoting can break:

```bash
PVE 'pct exec 101 -- sh -s' <<'SH'
set -eu
docker restart pve-exporter
SH
```

Values from the request go in as arguments (`'pct exec 101 -- sh -s -- arg'`, read as `$1`) or
are computed on the remote side. Avoid `PVE "pct exec 101 -- sh -c '...\"...\"...'"`: three
layers of quoting is where PR #75-era bugs came from.

Warpgate closes a session after 30 minutes with no output from the target
(`ssh.inactivity_timeout`; client keepalives don't count). Anything that can be silent longer
(big archives, dumps) runs detached with `setsid` and is polled with short calls, as in
`2026-11-26-prometheus-consolidate-finish.sh`.

## Before merge (CI)

The `ops-check` workflow (`.github/workflows/ops-check.yml`, proposed in `ops/pending-workflows/`)
runs `shellcheck` on each added or edited request and renders every stack as Komodo's periphery
sees it (`scripts/check-compose-komodo.py`): compose runs inside that container and can't read an
`env_file` outside the stack's checkout or `/etc/komodo`. Bind mounts are fine; the host's Docker
daemon resolves them.

What it can't test: anything that depends on live state (permissions of files on a host, real
tokens, how long a real archive takes). Each request still ends with checks that fail loudly.
