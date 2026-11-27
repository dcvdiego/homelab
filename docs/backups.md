# Backups

How the homelab is backed up, and where each piece is configured. Set up 2026-10-04 to 2026-10-08.

## Layers

| What | How | Where it lands |
|---|---|---|
| LXC rootfs (+ `/docker` via CT 100) | vzdump jobs, Sat 02:00 (100, 101, 106) and 03:00 (104, 201), snapshot mode | PBS `homelab-backups` (CT 105, 3TB on `vault`) |
| Proxmox host config (`/etc`, `/etc/pve`, `/var/lib/pve-cluster`, `/root`) | systemd timer `pve-host-backup.timer`, Sat 04:30 → `/usr/local/sbin/pve-host-backup.sh` | PBS group `host/pvehost` |
| Databases on docker-prod | `scripts/db-dumps.sh`, cron 01:30 daily (`/etc/cron.d/db-dumps` in CT 101) | `/docker/db-dumps` (7 days), then PBS + Backblaze with `/docker` |
| Immich DB | Immich's own nightly backup job (nothing written since 2026-11-07 when checked), and `pg_dumpall` in `db-dumps.sh` since 2026-11-27 | `/data/immich/backups`, `/docker/db-dumps` |
| `/data` and `/docker` files | Backblaze, over the SMB shares from CT 100 | off-site |
| Immich media, `/data/manual_backups`, `/docker`, docker-prod's `/etc/komodo`, Proxmox host config | rustic + rclone, daily 03:15 (stack `offsite-backup`, [below](#off-site-rustic--rclone)) | encrypted repository on the cloud drive (Google Drive or OneDrive) |
| Proxmox host config, daily | `pve-config-export.timer` 00:45 → `/usr/local/sbin/pve-config-export.sh` | `/docker/backups/pvehost` (newest 14), then off-site with `/docker` |
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

- Postgres (`security-postgresql-1`, `tandoor-db`, `nextcloud-db`, `zulip-database`, `windmill-db`, `immich_postgres`):
  `pg_dumpall` inside each container. MariaDB (every container from the `mariadb` image, found by image, so also the private repo's
  stacks'): `mariadb-dump --all-databases
  --single-transaction`. CouchDB (`obsidian-livesync`): `_all_docs?include_docs=true&attachments=true` per DB.
- Credentials come from each container's own environment, inside the container.
- A dump counts only if it is valid gzip, non-empty and ends with the tool's completion marker.
- A container that is gone, or was stopped on purpose (exit code 0, e.g. its stack stopped in Komodo), is skipped
  without alerting, and its newest dump is kept past retention. A crashed one (non-zero exit) still fails and alerts.
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
| windmill | `pg_dumpall` of `windmill-db` (scripts, flows, schedules, resources, secrets, users: everything Windmill keeps). Caches and logs are named volumes and not copied (the docs: no backup needed) | — |
| forgejo | `/docker/forgejo/data` (SQLite DB, repos, `app.ini`; without tmp, log). Offsite copy of `homelab-private`: the push mirror to a private GitHub repo (docs/forgejo-split.md) | forgejo |
| notes | `mariadb-dump` of `notes-db-1` (Vikunja); `/docker/vikunja/files` (attachments, avatars) | notes-vikunja-1 |

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

## Off-site: rustic + rclone

Stack `offsite-backup` (docker-prod, `docker-compose/offsite-backup/`) backs up everything needed to
rebuild the server, plus the photos and manual backups that exist nowhere else, into one encrypted,
deduplicated [rustic](https://rustic.cli.rs) repository on a cloud drive. rustic starts `rclone serve
restic` itself for the `rclone:` backend ([docs](https://rustic.cli.rs/docs/commands/init/rclone.html));
rclone talks to Google Drive or OneDrive. Set up 2026-11-27 with rustic 0.12.0 and rclone 1.76.0.

| Snapshot label | Source (read-only, same path in the container) | Size (2026-11-27) |
|---|---|---|
| `immich` | `/data/immich`: originals (`upload/`, `library/`), profiles, thumbs and transcodes (kept so a restore works straight away), Immich's own DB backups | ~172 GB |
| `manual-backups` | `/data/manual_backups` (includes the old-xps13 pictures Immich shows as an external library) | ~762 GB |
| `docker` | `/docker`: every app's data and config, `db-dumps/` (now with `immich_postgres`), `komodo/backups/` (Komodo's nightly DB backup: every stack's env and secrets), `backups/pvehost/` (host config). Left out: `ollama/` (models), every `/docker/<app>/cache`, `frigate/config/model_cache`, the rclone token | ~24 GB |
| `komodo-prod` | `/etc/komodo` on docker-prod: Periphery config, pre-deploy backups (not `stacks/`, which is git) | small |

The whole repository is encrypted with the key in `RUSTIC_PASSWORD`: file contents, file names and
snapshot metadata. The cloud provider only sees opaque pack files.

- **Schedule:** daily 03:15 (`BACKUP_SCHEDULE`), after the host config export (00:45), Komodo's DB
  backup (01:00) and the DB dumps (01:30). On Sundays (`MAINTAIN_DAY=7`) the run then does `forget
  --prune` (keep 7 daily, 5 weekly, 12 monthly, 3 yearly) and `check --read-data --read-data-subset 5%`:
  it downloads and verifies about 5% of the data each week.
- **One run at a time:** a run that finds the previous one still going logs "skipped" and exits. The
  first upload takes days: with Drive's 750 GiB/day upload cap, `RCLONE_BWLIMIT=8M` (8 MiB/s, about 675
  GiB/day) keeps rclone under it, so about 33 hours for ~950 GB if the uplink keeps up.
- **Config:** the rustic profile (`rustic/rustic.toml`) and the scripts (`bin/`) are mounted from the
  stack's checkout and read on every run, so a merged change applies at the next run. The image changes
  only on a version bump (the Komodo stack has `run_build`). Edit the sources and retention in
  `rustic.toml`.
- **Status:** `docker logs offsite-backup` (and Loki), `/cache/state/last-run` in the container, and the
  Uptime Kuma push monitor once `KUMA_PUSH_URL` is set. Exit code 3 from rustic (some files unreadable)
  counts as success with a note, because the snapshot is saved. The log lists the files.
- **Cost of a run:** nightly changes are small (DB dumps, app data). The DB dumps are gzip, so each
  night's dumps are uploaded again (a few hundred MB, mostly Immich's).

### Setup (owner, once)

1. **Save the key off this server.** Komodo → Stacks → `offsite-backup` → Environment →
   `RUSTIC_PASSWORD` (the ops request generated it). Put it in a password manager that is **not** the
   self-hosted Vaultwarden, and on paper. Without it the off-site copy can't be read, and the copy is
   only for the day this server is gone.
2. **Google Drive remote** ([rclone: drive](https://rclone.org/drive/)). This needs a Google One plan
   with room for ~1 TB and growth (2 TB).
   1. Make your own OAuth client ([rclone: making your own client_id](https://rclone.org/drive/#making-your-own-client-id)):
      Google Cloud console → new project → enable the Google Drive API → OAuth consent screen
      (External) → client ID of type **Desktop app**. **Publish the app** (status "In production",
      unverified is fine for yourself). An app left in "Testing" issues refresh tokens that expire after
      7 days, and backups then stop.
   2. On a PC with a browser: `rclone config create offsite drive client_id=<id> client_secret=<secret>
      scope=drive.file`. With `drive.file`, rclone sees only the files it created itself.
   3. Save the client ID and secret next to the rustic key: a restore with a different client can't see
      `drive.file` files.
   4. Copy the `[offsite]` section from `rclone config file` into docker-prod's
      `/docker/offsite-backup/rclone/rclone.conf` (root, mode 600; `pct exec 101` from pvehost).

   **OneDrive instead:** `rclone config create offsite onedrive` ([rclone: onedrive](https://rclone.org/onedrive/);
   rclone's own client ID is fine). Set `RCLONE_BWLIMIT=` (empty) in the stack env, since OneDrive has
   no daily cap. A Microsoft 365 Personal plan's 1 TB is already too small for this. The config dir is
   mounted read-write because OneDrive rotates refresh tokens and rclone has to save the new one.
3. **Check it:** `docker exec offsite-backup rclone lsd offsite:` lists the drive.
4. **Monitoring:** in Uptime Kuma, add a push monitor "Backups: off-site (push)" with a 25 h heartbeat
   interval (pause it until the first upload has finished). Put `http://uptime-kuma:3001/api/push/<token>`
   into `KUMA_PUSH_URL` in the stack env, then redeploy. Add it to `uptime-kuma-monitors.py` in the private
   repo.
5. **First run:** wait for 03:15, or start it now with `docker exec -d offsite-backup sh -c
   '/opt/offsite/backup.sh > /proc/1/fd/1 2>&1'` and follow it with `docker logs -f offsite-backup`. The
   first run creates the repository (`homelab-rustic` in the drive).

### Restore

**Server still up** (a deleted album, a broken app): restore into `/data/restore` (mounted as
`/restore`), check the files, then move them into place.

```sh
docker exec offsite-backup rustic snapshots                       # what's there, per label
docker exec offsite-backup rustic ls latest:/data/immich/upload --filter-label immich | head
docker exec offsite-backup rustic restore latest:/docker/ha /restore/ha --filter-label docker
docker exec offsite-backup rustic restore <snapshot id>:/data/manual_backups/xps13 /restore/xps13
```

**Server gone.** On any Linux machine, using the key and the OAuth client saved in setup:

1. Install the [rustic](https://github.com/rustic-rs/rustic/releases) and [rclone](https://rclone.org/downloads/)
   binaries. `rclone config create offsite drive client_id=<saved id> client_secret=<saved secret>
   scope=drive.file` (the same client, so the repository's files are visible), then
   `export RUSTIC_PASSWORD=<key>` and `R="rustic -r rclone:offsite:homelab-rustic"`.
2. `$R snapshots`. Then `$R restore latest:/docker/backups/pvehost /tmp/pvehost --filter-label docker`
   and unpack the newest tarball: `etc/pve/lxc/*.conf` (container configs), `etc/pve/storage.cfg`,
   `etc/network/interfaces`, `config.db` (the whole cluster config), and `/root` and `/usr/local/sbin` (host
   scripts, `homelab.env`). Reinstall Proxmox and recreate the containers from those configs, or
   restore them from PBS if PBS survived ([Restoring a container](#restoring-a-container)).
3. `/docker`: `$R restore latest:/docker /docker --filter-label docker`. This brings back the apps' data and
   configs, `db-dumps/` and `komodo/backups/`.
4. Komodo: start Core with an empty MongoDB, then restore its database from `/docker/komodo/backups`
   with `km database restore` ([Komodo: backup and restore](https://komo.do/docs/setup/backup)). That
   brings back every stack's config and env. Deploy the stacks.
5. Databases: load each stack's newest dump from `/docker/db-dumps` (commands in
   [Database dumps](#database-dumps)), Immich's included. Live Postgres directories copied from a
   running server are crash-consistent at best: prefer the dumps.
6. Immich: `$R restore latest:/data/immich /data/immich --filter-label immich`, then follow
   [Immich: backup and restore](https://docs.immich.app/administration/backup-and-restore/) to load the
   database dump into a fresh `immich_postgres` before starting `immich_server`.
7. `/data/manual_backups`: `$R restore latest:/data/manual_backups /data/manual_backups --filter-label manual-backups`.

Downloads from Google Drive are free and not capped like uploads. Expect hours for the full ~950 GB.

### Changing it

- Add a source: a new `[[backup.snapshots]]` with its own `label` in `rustic/rustic.toml`, plus its
  read-only mount in `docker-compose.yml` at the same path.
- Version bumps come from Renovate: rustic is `review` (0.x minors change options; read the
  [breaking changes](https://rustic.cli.rs/docs/breaking_changes.html)), rclone is in the weekly batch.
- Never change `RUSTIC_PASSWORD` in Komodo. Add a second key with `rustic key add` first if it has to
  rotate.
