# Backups

How the homelab is backed up, and where each piece is configured. Set up 2026-10-04 to 2026-10-08.

## Layers

| What | How | Where it lands |
|---|---|---|
| LXC rootfs (+ `/docker` via CT 100/104) | vzdump jobs, Sat 02:00 (100, 101) and 03:00 (104, 201) | PBS `homelab-backups` (CT 105, 3TB on `vault`) |
| Proxmox host config (`/etc`, `/etc/pve`, `/var/lib/pve-cluster`, `/root`) | systemd timer `pve-host-backup.timer`, Sat 04:30 → `/usr/local/sbin/pve-host-backup.sh` | PBS group `host/pvehost` |
| Databases on docker-prod | `scripts/db-dumps.sh`, cron 01:30 daily (`/etc/cron.d/db-dumps` in CT 101) | `/docker/db-dumps` (7 days), then PBS + Backblaze with `/docker` |
| Immich DB | Immich's own nightly backup job | `/data/immich/backups` |
| `/data` and `/docker` files | Backblaze, over the SMB shares from CT 100 | off-site |
| PBS → off-site PBS | `pbs-pc` (192.168.1.50) pulls from CT 105 when it is online | secondary PBS |

## vzdump on this host

- Guest disks are `.raw` files on `dir` storage, which can't snapshot, so vzdump falls back to **suspend**
  mode: rsync to a temp dir, pause, final rsync. docker-prod pauses about 3 minutes.
- Temp dir: `tmpdir: /vault/vzdump-tmp` in `/etc/vzdump.conf` (the 80G root disk is too small for
  CT 101). The `vault/vzdump-tmp` dataset needs `acltype=posix xattr=sa`, otherwise rsync fails on
  journal ACLs (exit 23).
- Planned fix: move rootfs volumes to `zfspool` storage so snapshot mode works (no temp copy, no pause).
- Both jobs use `notification-mode notification-system` (the old `mailto` path never delivered).

## PBS (CT 105)

- Proxmox authenticates as API token `pvehost@pbs!backup` (role DatastoreBackup on
  `/datastore/homelab-backups`, for user and token). It owns all backup groups. The secret is in
  `/etc/pve/priv/storage/pbs-lxc.pw`; the host-config script reads the same file.
  Rollback copies from the switch: `/root/pbs-token-rollback/` on pvehost.
- Retention: prune job `weekly-prune`, Sun 04:00, keep-last 3 / weekly 8 / monthly 12.
  Garbage collection Sun 05:00. Verify job `verify-monthly`.
- The datastore uses `notification-mode notification-system`.

## Notifications (ntfy)

ntfy runs on docker-prod (`docker-compose/ntfy`), topic `homelab`, `auth-default-access: deny-all`.

| Sender | ntfy user | How it reaches ntfy |
|---|---|---|
| Proxmox (target `ntfy`, matcher `ntfy-all`: everything) | `proxmox`, write-only token | `/etc/hosts` on pvehost pins `ntfy.$DOMAIN` → 192.168.1.224 (Traefik), skipping Cloudflare Access |
| PBS (target `ntfy`, matcher `ntfy-all`: everything but successful prunes) | `pbs`, write-only token | same `/etc/hosts` pin inside CT 105 |
| Phone (Android app) | `diego` (admin) | Cloudflare Access app `ntfy.$DOMAIN` with a **Service Auth** policy and service token `ntfy-android` (custom headers in the app) |

- Webhook headers, body and secret values are **base64** in both `pvesh` and `proxmox-backup-manager`.
- The Access policy for the token must be **Service Auth** (`decision: non_identity`); with Allow,
  Access still redirects to the login page and the app shows "expected BEGIN_OBJECT but was STRING".
- Technitium has a one-record zone `ntfy.$DOMAIN` (A only), so LAN clients that use Technitium don't
  get Cloudflare's AAAA.

## Database dumps

`scripts/db-dumps.sh` (installed at `/docker/scripts/db-dumps.sh` in CT 101, root-only):

- Postgres (`security-postgresql-1`, `tandoor-db`, `nextcloud-db`, `zulip-database`, `strapiDB`):
  `pg_dumpall` inside each container. MariaDB (`notes-db-1`): `mariadb-dump --all-databases
  --single-transaction`. CouchDB (`obsidian-livesync`): `_all_docs?include_docs=true&attachments=true` per DB.
- Credentials come from each container's own environment, inside the container.
- A dump counts only if it is valid gzip, non-empty and ends with the tool's completion marker.
- Status: `/docker/db-dumps/.last-run`, log `/var/log/db-dumps.log`, and an Uptime Kuma push
  monitor "Backups: database dumps (push)" (25h interval) if `/docker/scripts/db-dumps.env` has
  `KUMA_PUSH_URL` (root-only, not in git; token is `KUMA_PUSH_DB_DUMPS` in the owner's `.env`).
- Restore, Postgres: `gzip -dc <file> | docker exec -i <container> psql -U <user> postgres`.
  MariaDB: `gzip -dc <file> | docker exec -i notes-db-1 sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mariadb -uroot'`.

## Pre-deploy backups

Before every deploy of a critical stack, Komodo runs `scripts/pre-deploy-backup.sh <stack>` (stack
config "Pre Deploy", set by `ops/requests/2026-10-24-komodo-pre-deploy-backups.sh`). The projects' own
upgrade docs say to back up before updating (docs/image-versions.md); this makes it happen on every
Renovate merge without anyone remembering. **If the backup fails, the deploy stops** (Periphery returns
before `compose up`), so nothing is upgraded without a copy.

| Stack | What | Stops for the copy |
|---|---|---|
| photos | `pg_dumpall` of `immich_postgres` | — |
| security | `pg_dumpall` of `security-postgresql-1`; `/docker/authentik` (media, certs, templates); `/docker/vw-data` | vaultwarden |
| haos | `/docker/ha` (without `backups/`, logs), zigbee2mqtt data, matter-server data, otbr data, mosquitto | homeassistant, zigbee2mqtt, matter-server, otbr |
| matter-hub | `/docker/matter-hub` | matter-hub |
| network-prod, network-tower | `/docker/technitium` (without logs, stats) | — |
| frigate | `/docker/frigate/config` (config.yml, frigate.db; without model_cache) | frigate |
| nextcloud, zulip, recipes | `pg_dumpall` of the stack's Postgres | — |
| open-webui | `/docker/open-webui` (without cache) | open-webui |

- Where: `/etc/komodo/pre-deploy-backups/<stack>/<timestamp>/` on the Docker host, newest 3 per stack.
  The host rootfs is in the vzdump jobs, so they reach PBS too. Sizes today: a few MB to ~900 MB
  (open-webui), Immich's dump is the largest database.
- Stopped containers are started again when the copy is done (also on failure); compose then
  recreates whatever changed. So a haos deploy restarts Home Assistant, Zigbee2MQTT, Matter and Thread
  once even if only one of them changed: expect about a minute without home automation.
- Files are read by a throwaway `alpine` container (pinned, Renovate-managed) with the host dir mounted
  read-only; Postgres dumps run inside the DB container with its own credentials.
- Adding a stack: a `case` entry in the script, its name in the ops request (as a new request), and a row here.
- Restore: Postgres `gzip -dc <file>.sql.gz | docker exec -i <container> psql -U <user> postgres`;
  files: stop the service, `tar xzf <file>.tar.gz -C <host dir>`, start it.
