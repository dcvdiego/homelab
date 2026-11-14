# Backups

How the homelab is backed up, and where each piece is configured. Set up 2026-10-04 to 2026-10-08.

## Layers

| What | How | Where it lands |
|---|---|---|
| LXC rootfs (+ `/docker` via CT 100) | vzdump jobs, Sat 02:00 (100, 101, 106) and 03:00 (104, 201), snapshot mode | PBS `homelab-backups` (CT 105, 3TB on `vault`) |
| Proxmox host config (`/etc`, `/etc/pve`, `/var/lib/pve-cluster`, `/root`) | systemd timer `pve-host-backup.timer`, Sat 04:30 → `/usr/local/sbin/pve-host-backup.sh` | PBS group `host/pvehost` |
| Databases on docker-prod | `scripts/db-dumps.sh`, cron 01:30 daily (`/etc/cron.d/db-dumps` in CT 101) | `/docker/db-dumps` (7 days), then PBS + Backblaze with `/docker` |
| Immich DB | Immich's own nightly backup job | `/data/immich/backups` |
| `/data` and `/docker` files | Backblaze, over the SMB shares from CT 100 | off-site |
| PBS → off-site PBS | `pbs-pc` (192.168.1.50) pulls from CT 105 when it is online | secondary PBS |

## vzdump on this host

Since 2026-11-07 every container's rootfs is a ZFS subvolume on storage `flash-zfs` (`zfspool`,
dataset `flash/subvols`, `acltype=posix xattr=sa`, sparse), so vzdump runs in **snapshot** mode:
ZFS snapshot, a brief filesystem freeze, no temp copy, no pause. Docs:
[vzdump](https://pve.proxmox.com/pve-docs/chapter-vzdump.html) ("snapshot mode requires that all
backed up volumes are on a storage that supports snapshots"; `backup=no` volumes are exempt).

| CT | Before (suspend mode) | Snapshot mode (test 2026-11-07) |
|---|---|---|
| 100 vault (rootfs + `/docker`) | ~11 min | 59 s (suspends for the instant both volumes are snapshotted) |
| 101 docker-prod | ~21 min, 127 s pause | 2 min 53 s, no pause |
| 104 docker-tower | ~5.5 min | 30 s |

Disk layout:

- `/docker`: CT 100's volume `flash-zfs:subvol-100-disk-0` (`backup=1`). CT 101 and 104 bind-mount
  its directory (`mp1: /flash/subvols/subvol-100-disk-0,mp=/docker`), the documented way to share
  data between containers. Bind mounts are never backed up, so `/docker` is backed up once, from CT 100.
  Edit 101/104's `mp1` line in the `.conf` by hand, not with `pct set`: replacing a volume mount point
  with `pct set` keeps the old volume as `unusedN`, and destroying that CT (or `--delete unusedN`) would
  delete CT 100's disk.
- `/data`: still `data:100/vm-100-disk-0.raw` (14 TB raw on `vault`, mounted in 100/101/104/201,
  `backup` off). All four share one loop device, so the filesystem is mounted once (checked
  2026-11-07). PBS's datastore (CT 105 `mp0`) also stays raw on `vault`, not backed up.
- Docker in 101/104 uses `overlay2` on ZFS (needs OpenZFS ≥ 2.2; host has 2.4.4).
- The old `.raw` rootfs/`/docker` files are kept as `unused0`/`unused1` until a scheduled Saturday
  run has succeeded in snapshot mode; then delete them (owner's OK) to free ~140 GB on `flash`.
  Config copies from before the move: `/root/<ct>.conf.bak-2026-11-07` on pvehost.
- `tmpdir: /vault/vzdump-tmp` in `/etc/vzdump.conf` is now only used for `pct.conf`; keep it for a
  container that ever goes back to `dir` storage.
- Both jobs use `notification-mode notification-system` (the old `mailto` path never delivered).

Why it mattered: on 2026-11-07, in suspend mode, CT 101 was paused 127 s; on resume the USB Zigbee
adapter hit `ASH_NCP_FATAL_ERROR` and Zigbee2MQTT hung with its container still "Up" (presence
automations dead for 14 h). Monitor "Zigbee2MQTT (push)" alerts on that now. The snapshot-mode test
backup of CT 101 caused no adapter errors.

## Restoring a container

Tested 2026-11-07: CT 201's PBS backup restored to a new CT 9201 on `flash-zfs` (7.7 GiB in 1m51s);
Jellyfin started and reported `Healthy`, data matched the original.

- `pct restore <new-id> pbs-lxc:backup/ct/<id>/<time> --storage flash-zfs --unique 1`. Restore to a
  **new ID** first; `--unique` only changes the MAC, so before starting remove or change `net0`
  (same IP as the original) and set `onboot 0`.
- **Mount points that are excluded from backup come back as new, empty volumes** on the target storage
  (CT 201's 14 TB `/data` became an empty `subvol-9201-disk-1`). For a real restore, point `mp0` back
  at `data:100/vm-100-disk-0.raw` before starting, or the container sees an empty `/data`.
  Bind mounts (101/104's `/docker`) stay as written in the backed-up config.
- Before destroying a test restore, check its config lists only its own volumes
  (`subvol-<new-id>-*`): `pct destroy` deletes every volume in the config.
- Backups taken before 2026-11-07 still describe the old `.raw` layout.

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
  `pg_dumpall` inside each container. MariaDB (`notes-db-1`, `romm-db`): `mariadb-dump --all-databases
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
| forgejo | `/docker/forgejo/data` (SQLite DB, repos, `app.ini`; without tmp, log). Offsite copy of `homelab-private`: the push mirror to a private GitHub repo (docs/forgejo-split.md) | forgejo |
| notes | `mariadb-dump` of `notes-db-1` (Vikunja); `/docker/vikunja/files` (attachments, avatars) | notes-vikunja-1 |
| romm | `mariadb-dump` of `romm-db`; `/docker/romm/assets` (saves, states, uploads), `/docker/romm/config`. Not the ROM library or `/data/romm/resources` (RomM's docs: back the library up separately; resources re-download on a rescan) | romm |

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
  MariaDB `gzip -dc <file>.sql.gz | docker exec -i notes-db-1 sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mariadb -uroot'`;
  files: stop the service, `tar xzf <file>.tar.gz -C <host dir>`, start it.
