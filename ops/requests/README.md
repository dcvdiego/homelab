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
| `PORTAINER_URL`, `PORTAINER_TOKEN` | Portainer API, full access |
| `CF_TOKEN`, `CF_ACCOUNT`, `CF_ZONE`, `CF_TUNNEL` | Cloudflare DNS edit + tunnel config for the zone |
| `TECHNITIUM_TOWER_TOKEN`, `TECHNITIUM_PROD_TOKEN` | Technitium API tokens for `192.168.1.248:5380` and `192.168.1.224:5380` |
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
