# Portainer → Komodo migration plan

## Status: done 2026-10-07 (Portainer stopped the same day; its data volume kept until ~2026-10-14)

Done by an agent through the access model in [agent-access.md](agent-access.md): PRs by the
`homelabsito[bot]` app, ops requests run by the `homelab-ops` runner, attended `pve-root` sessions.

| Step | How | Result |
|---|---|---|
| Backups | `pve-root`: DB dumps (Immich, Authentik, Zulip, Strapi, notes, Vaultwarden) to `/docker/backups/pre-komodo-2026-10-07/`, then PBS `vzdump 101 104` | both OK, incremental |
| Core + Periphery | PR #3 (upstream v2.3.3 compose files, local changes listed in each header), bootstrapped in `pve-root` | Core on docker-tower; both servers onboarded with a one-time key; terminals and container exec off |
| Check | PR #5: live compose vs repo for all 22 stacks, env names only | 18 identical; drift in homepage, network (tower), haos (`OT_LOG_LEVEL`, and `otbr`'s `/run/dbus` missing from the repo, fixed in #6) |
| Batch 1 (15 non-critical) | PR #6 | all running; most services restarted once (compose recreated them) |
| Critical (matter-hub, haos, security, photos) | PR #8 | all running and healthy; Thread attached, Zigbee publishing |
| Infra (network ×2, traefik) + register `ops` | PR #9 | DNS, tunnel (now `protocol=http2` on tower too) and HTTPS verified |

Lessons: adoption recreates containers even with unchanged images and env (expect one restart per
service); compare live with the repo before moving anything (it found two real gaps); the runner's own
stack can't be deployed from a job.

Follow-ups: drop Portainer's data volume after a week; move stack secrets into Komodo secret variables
(`[[NAME]]`) so a Stack Read permission stops exposing env; Authentik OIDC for Komodo.

---


Direct cutover (no parallel trial). Portainer CE 2.x stays running, untouched, as the
rollback path until the last stack is moved, then it's removed.

Why: Portainer CE is frozen on the 2.x line (2.45 LTS, maintained until ~May 2027); 3.0 is
Kubernetes-first. Komodo v2 covers everything Portainer is used for here (multi-host agents,
git-backed stacks, env/secrets, API, logs, terminals) and adds GitOps (Resource Sync),
scheduled procedures, update detection, alerting and free OIDC.

---

## Current state (audited 2026-09-25)

| Portainer endpoint | Host | Stacks |
|---|---|---|
| 2 `local` | docker-tower (LXC 104) | homepage, network |
| 3 `prod` | docker-prod (LXC 101) | backend_cms, crowdsec, deezer, dev, frigate, haos, matter-hub, monitoring, network, nextcloud, notes, open-webui, photos, recipes, security, servarr, smtp-relay, traefik, zulip |
| 4 `dev` | docker-dev (LXC 102, **stopped**) | mc, network, servarr-dev, tandoor |
| 5 (endpoint no longer exists) | — | cloudflare-tunnel (orphan record) |

- 26 stacks: 5 git-backed, 21 web-editor. **Every live compose file is now in
  `docker-compose/`**. The repo matches live except:
  - `haos`: repo has `OT_LOG_LEVEL: "4"`, live runs `"7"` (debug). Repo is the intended value — applied at cutover.
  - `network` on docker-tower was deployed from an older commit (missing `--protocol http2`). Fixed at cutover.
  - `network-ep3/`, `network-ep4/`, `cloudflare-tunnel/` dirs are legacy — superseded by the unified `network/` stack.
- Inline secrets exist only in Portainer's copies of the **ep4/ep5** stacks (tunnel tokens, tandoor
  DB password, playit key). The repo versions use `${VARS}`; nothing leaked into git history.
- Compose project name = stack name (Portainer convention). Komodo must use the **same project
  names** so it adopts the running containers instead of creating duplicates.
- All bind mounts are absolute (`/docker/...`, `/data/...`), so nothing depends on Portainer's
  `/data/compose/<id>` working dir.

---

## Phase 0 — Backups first (critical services)

Only these need real backups: **immich (photos), vaultwarden (security), haos, matter-hub, network**.

| Service | Data | Location | In PBS today? |
|---|---|---|---|
| Immich originals | 155 GB | `/data/immich` (vault HDD mirror) | **No** — `/data` mp0 has no `backup=1` |
| Immich DB | Postgres | `/docker/immich/postgres` | Yes (crash-consistent LXC snapshot) |
| Immich auto DB dumps | `.sql.gz` | `/data/immich/backups` | **No** (on `/data`) |
| Vaultwarden | SQLite + attachments | `/docker/vw-data` | Yes (crash-consistent) |
| Home Assistant / Z2M / OTBR / matter-server / mosquitto | configs + DBs | `/docker/{ha,zigbee2mqtt,otbr,matter-server,mosquitto}` | Yes |
| Matter Hub | config | `/docker/matter-hub` | Yes |
| Technitium | zones/config | `/docker/technitium` | Yes |

PBS jobs: Sat 02:00 (100, 101, 103) and Sat 03:00 (104, 201) → **weekly only**, and the
auditor token can't list snapshots, so restorability is unverified.

**Do before cutover:**
1. Take a manual PBS backup of LXC 101 and 104 (the cutover rollback point).
2. App-level, consistent dumps into `/docker/backups/` (which PBS picks up):
   - Vaultwarden: `sqlite3 /data/db.sqlite3 ".backup '/data/db-backup.sqlite3'"` (or the admin panel backup) — daily.
   - Immich: confirm the built-in DB dump job is on; copy/relocate dumps off `/data`.
   - Home Assistant: built-in backup, daily.
   - Technitium: Settings → Backup (API: `/api/settings/backup`).
3. **Immich originals need an off-host copy** — mirrored HDDs are redundancy, not backup.
   Options: add `/data/immich` as a separate PBS client backup (proxmox-backup-client from
   inside LXC 101), or restic/rclone to pbs-pc / cloud. 155 GB, grows slowly.
4. Move the PBS schedule for 101/104 to daily; add a retention policy (e.g. 7 daily, 4 weekly, 6 monthly).
5. Test one restore (vaultwarden into a scratch container) before relying on it.
6. Grant the auditor token `Datastore.Audit` on PBS so backup freshness can be monitored/alerted.

---

## Phase 1 — Repo as source of truth (mostly done)

- [x] Every live stack's compose file in `docker-compose/<stack>/`.
- [x] Repo synced to live where live was the intended state (vaultwarden pin `1.37.2`, vikunja-db healthcheck 30s).
- [ ] Commit the outstanding working-tree changes.
- [ ] Every stack has an `example.env` listing its variable names (values go into Komodo, never git).
- [ ] Pin the critical services instead of relying on old images for rollback:
      `IMMICH_VERSION=v<current>`, HA `stable` → exact version, zigbee2mqtt / OTBR / matter-hub `latest` → exact tags.
- [ ] Delete legacy dirs: `network-ep3/`, `network-ep4/`, `cloudflare-tunnel/` (and ep4 stacks if docker-dev is being retired).

## Phase 2 — Komodo Core

- Host: **docker-tower** (it already hosts the Portainer UI; keeps management off the prod box).
- Stack `komodo` in `docker-compose/komodo/`: `komodo-core` + **MongoDB** (Komodo's recommended DB; the i3-13100 supports AVX).
  FerretDB+Postgres is the alternative if avoiding Mongo.
- Image tags: `:2` (v2 images; `:latest` is deprecated).
- Traefik labels + Authentik **OIDC** (native login, browser-only UI) — `komodo.${DOMAIN}`, add Technitium record; LAN-only, no Cloudflare route.
- Enable passkey/TOTP on the local admin as break-glass.
- Add the Mongo data dir to the backup set (it holds Komodo's state; the TOML in git is the real source of truth).

## Phase 3 — Periphery agents

- Install Periphery on docker-prod and docker-tower (v2 outbound mode: agent connects to Core,
  onboarding key, no inbound port needed).
- Run it as a container (or systemd via Ansible later). It needs `/var/run/docker.sock` and
  the repo clone dir.

## Phase 4 — Cutover, stack by stack

Order (lowest risk → critical, one host at a time):
1. docker-tower: `homepage`
2. docker-prod non-critical: `dev`, `backend_cms`, `deezer`, `smtp-relay`, `open-webui`, `recipes`, `notes`, `zulip`, `nextcloud`, `servarr`, `crowdsec`, `monitoring`, `frigate`
3. Infra: `traefik`, `network` (both hosts)
4. Critical (after Phase 0 dumps are verified): `matter-hub`, `haos`, `security` (vaultwarden + authentik), `photos` (immich)

Per stack:
1. Put the stack's variables in Komodo (secrets as Komodo Secrets, shared ones like `DOMAIN` as global Variables).
2. Create the Komodo Stack: git repo `dcvdiego/homelab`, run directory `docker-compose/<stack>`,
   **project name = the Portainer stack name**, server = the right Periphery.
3. Deploy. Compose reconciles the existing project — unchanged services aren't recreated.
4. Check the service works (UI, Uptime Kuma green, logs clean).
5. **Do not delete the stack in Portainer** — that runs `compose down` on the same project and
   would stop the containers Komodo now manages. Leave the Portainer records alone.

Rollback for any stack: redeploy it from Portainer (still running, still has its env).

## Phase 5 — Turn on the useful bits

- **Resource Sync**: export Komodo resources to `komodo/*.toml` in this repo; from then on
  changes are git commits → sync. (This replaces the AGENTS.md "always include env on redeploy" footgun.)
- **Webhooks**: GitHub push → redeploy only the stacks whose files changed.
- **Procedure "weekly-image-prune"** on both servers: removes unused images — keeps disk flat now
  that rollback relies on pinned tags instead of old images.
- **Alerter → Discord**: server disk/mem/CPU thresholds, container unexpectedly stopped, image update available.
- **Auto-update**: only non-critical stacks (servarr, open-webui, …). Critical stacks: notify only, update by bumping the pin.
- Update AGENTS.md access table: Komodo API / `km` CLI replaces the Portainer API.

## Phase 6 — Decommission Portainer

- Once every stack runs from Komodo for a week: stop the Portainer container and agents
  (containers of the stacks are unaffected), then remove them and `docker-compose/portainer/`.
- Delete the orphan ep4/ep5 stack records along with it (their inline secrets go with them;
  rotate the playit key and tandoor DB password if docker-dev is ever reused).

## Later — Terraform + Ansible

- **Terraform** (`terraform/`): switch from `telmate/proxmox` to `bpg/proxmox` (better LXC support), import existing LXCs 100–105/201 incl. mountpoints, dev passthrough, backup jobs.
- **Ansible**: base packages, Docker, Periphery agent, node_exporter, `/etc/pve/lxc/101.conf` device passthrough, udev rules, ZFS ARC limit.
- **Komodo Resource Sync**: all stacks.
Rebuild path: `terraform apply` → `ansible-playbook` → Komodo sync → restore data from PBS.
