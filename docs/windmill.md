# Windmill

Scripts (Python, TypeScript, Bash, Go, ...), flows, schedules and webhooks for the homelab's
automations. Komodo stack **windmill** on docker-prod, compose `docker-compose/windmill/`, created by
`ops/requests/2026-11-25-windmill.sh`. Community Edition, **1.884.1**, set up from the official docs:

- [Self-host (Docker)](https://www.windmill.dev/docs/advanced/self_host), and its Traefik variant of
  the compose (the one this stack follows, with this repo's Traefik in place of Caddy)
- [Release compose v1.884.1](https://raw.githubusercontent.com/windmill-labs/windmill/v1.884.1/docker-compose.yml)
- [Security and process isolation](https://www.windmill.dev/docs/advanced/security_isolation),
  [worker groups](https://www.windmill.dev/docs/core_concepts/worker_groups),
  [Postgres 18 upgrade](https://www.windmill.dev/docs/advanced/self_host/postgres_18_upgrade)

## Access

- `https://windmill.$DOMAIN`. LAN and tailnet: split DNS (Technitium A records on both instances) →
  Traefik on 192.168.1.224. Outside: the `*.$DOMAIN` tunnel wildcard, **behind Cloudflare Access**.
  Routers are named `windmill-access` / `windmill-extra-access`, so CrowdSec's Access whitelist
  covers them; if the hostname ever moves to an Access bypass policy, rename them first
  (docker-compose/crowdsec/access-protected-whitelist.yaml).
- `windmill.homelab.lan` also resolves to Traefik, but Traefik only routes `windmill.$DOMAIN`.
- **First sign-in:** `admin@windmill.dev` with the password in CT 101
  `/root/windmill-initial-password` (the request replaced the default `changeme`). Then create your
  own user as superadmin, sign in as it, and disable or delete `admin@windmill.dev`.
- **Webhooks from the internet** (GitHub, etc.) hit Cloudflare Access and fail. When one is needed,
  add an Access bypass or service-token policy for that path only, and take the router out of the
  CrowdSec whitelist name pattern at the same time (see above). LAN/tailnet callers (Home Assistant,
  Komodo, ntfy) reach it directly.

## Layout

| Service | What | Notes |
|---|---|---|
| `db` (`windmill-db`) | `postgres:18`, as upstream | Data in `/docker/windmill/db` (mounted at `/var/lib/postgresql`: 18's layout) |
| `windmill_server` | API + UI, :8000 | Traefik `windmill.$DOMAIN` |
| `windmill_worker` ×2 | default worker group, 2 GB limit each | `privileged` + `FAVOR_UNSHARE_PID`: jobs run in their own PID namespace. No Docker socket |
| `windmill_worker_native` ×1 | native jobs (HTTP, SQL) in-process | no isolation, as upstream |
| `windmill_indexer` ×0 | full-text log search | Enterprise only, off as upstream |
| `windmill_extra` | LSP + debugger, :3000 | Traefik `/ws/`, `/ws_mp/`, `/ws_debug/`. Multiplayer is Enterprise only |

Sizing: the docs' rule of thumb is 1 worker per vCPU and 1–2 GB RAM, and one worker runs one job at a
time. docker-prod (6 vCPU, ~21 GB, ~4 GB free on 2026-11-25) runs 3 workers; raise
`windmill_worker` `replicas` in the compose (a PR) if jobs queue. Each job over its memory limit is
killed with exit 137 and the worker keeps running.

Not in CE (so not set up here): worker group management UI, dedicated workers, init scripts,
audit logs, Git sync, object storage, Prometheus metrics. Plain SSO (Google, GitHub, ...) is in the
OAuth instance settings.

## Secrets

The stack env (Komodo) holds `DOMAIN` and `WINDMILL_DB_PASSWORD`. Credentials that scripts use
(API tokens for Home Assistant, ntfy, ...) go into **Windmill resources/variables marked secret**,
not into this repo or the stack env. They're stored encrypted in Postgres, so the dumps below contain
them (encrypted) along with password hashes and the session-signing secret: dumps stay root-only.

## Backups and upgrades

- Nightly `pg_dumpall` of `windmill-db` (`scripts/db-dumps.sh`), and a pre-deploy `pg_dumpall`
  before every Komodo deploy (`scripts/pre-deploy-backup.sh windmill`; the deploy stops if it fails).
  The docs say to dump the **whole cluster**, never just the `windmill` database. The caches, LSP
  cache and logs are named volumes and need no backup. Details in [backups.md](backups.md).
- Upgrades: Renovate's grouped **Windmill** PR (server, workers, indexer, windmill-extra on one
  version; the `postgres` companion synced from that release's compose by CI). Migrations run on
  their own at startup, and the docs give no downgrade path: the way back is the pre-deploy dump.
  Windmill releases often (near-daily); Renovate offers one PR a week at most.
- A Postgres major (e.g. a future 19) is never an image bump: `pg_dumpall`, new volume, restore,
  `vacuumdb --all --analyze-in-stages`, as the Postgres 18 upgrade page describes.

## Follow-ups not in the first request

- Uptime Kuma HTTP monitor for `https://windmill.$DOMAIN/api/version` (private repo script).
- Homepage tile, if wanted.
