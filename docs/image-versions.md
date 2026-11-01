# Image versions

Every image follows **its own project's docs** on which tag to run and how to upgrade. Those rules are
written down here once per image, and from then on they're enforced by config instead of memory:

| Layer | What it does |
|---|---|
| Compose files | Every image is pinned as `tag@sha256:digest`: the exact version, and a digest a re-pushed tag can't change. |
| `renovate.json` | Renovate opens the update PRs, with release notes, on Saturdays (3-day minimum release age). Non-critical minor/patch/digest updates come as one weekly batch PR; critical or breaking-prone images get one PR per update (label `review`); majors get `breaking`. Per-image notes from this page are added to the PR body. |
| `scripts/image-policy.json` | What Renovate can't express: companion images that must match the app's upstream compose, and images that may not skip a release line. |
| `scripts/upstream-compose.py` | On a Renovate PR for Immich, authentik or Zulip, CI rewrites the companion images to the ones in the project's compose file for the new version (`--fix`), and every Monday it reports drift as an issue. |
| `scripts/check-images.py` | CI on every PR: fails if an image isn't pinned, uses a moving tag, has no row below, has no Renovate rule, or (for sequential images) skips a release line. |
| PR-Agent | On Renovate PRs, summarises breaking changes and manual steps from the release notes in the PR body. |
| Komodo pre-deploy | Critical stacks back up their data before every deploy, and the deploy stops if the backup fails ([docs/backups.md](backups.md#pre-deploy-backups)). |

Adding or changing an image: follow **AGENTS.md → Adding or updating a stack**.

## Rules

Kinds:
- **review**: own PR per update; read the release notes (and the notes Renovate adds) before merging.
- **batch**: minor/patch/digest updates in the weekly batch PR; majors get their own PR.
- **sequential**: review, and CI fails a PR that skips a release line.
- **companion**: the image and tag come from the app's upstream compose for the version we run; Renovate only refreshes the digest (or nothing, if upstream pins the digest).
- **db**: batch for minor/patch; Renovate never offers a major (a dump and restore, done by hand).
- **off**: no updates.

| Image | Stacks | Kind | What the project's docs say | Source |
|---|---|---|---|---|
| `ghcr.io/immich-app/immich-server` | photos | review | Pin a version (`IMMICH_VERSION`), read release notes for breaking changes; breaking changes only in majors; upgrade mobile apps before a major. Server and ML on the same version. | [upgrading](https://docs.immich.app/install/upgrading/) |
| `ghcr.io/immich-app/immich-machine-learning` | photos | review | Same version as immich-server (grouped PR). | [upgrading](https://docs.immich.app/install/upgrading/) |
| `ghcr.io/immich-app/postgres` | photos | companion | Use the image (with digest) from the release's `docker-compose.yml`. | [release compose](https://github.com/immich-app/immich/releases) |
| `docker.io/redis` | photos | companion | Immich ≥ 2.x composes use `valkey/valkey:9@sha256:…` instead (see catch-up). | [release compose](https://github.com/immich-app/immich/releases) |
| `ghcr.io/goauthentik/server` | security | sequential | Never skip a release line (each `YYYY.M`); back up the DB first; no downgrades; outposts on the same version. 2025.10 removed Redis. | [upgrade](https://docs.goauthentik.io/install-config/upgrade/) |
| `postgres` | security, nextcloud, recipes, backend_cms | companion (security) / db | authentik: the tag in its compose (`16-alpine`). Others: Postgres majors need dump/restore. | [authentik compose](https://github.com/goauthentik/authentik/blob/main/lifecycle/container/compose.yml) |
| `redis` | security, zulip, nextcloud | companion (security, zulip) / batch | authentik and Zulip: the tag in their compose (`alpine`). Nextcloud: a cache, any supported version. | [docker-zulip compose](https://github.com/zulip/docker-zulip/blob/main/compose.yaml) |
| `vaultwarden/server` | security | review | Examples use `latest`; release notes flag client/config changes, so pin and read them. Back up `/data` first. | [wiki](https://github.com/dani-garcia/vaultwarden/wiki/Using-Docker-Compose) |
| `ghcr.io/home-assistant/home-assistant` | haos | review | Docs use `stable`; monthly releases each have backward-incompatible changes, so pin `YYYY.M.x` and read them. | [install](https://www.home-assistant.io/installation/linux#docker-compose), [release notes](https://www.home-assistant.io/blog/categories/release-notes/) |
| `eclipse-mosquitto` | haos | review | Major tag `2` in docs; pinned exact (`2.x.y-alpine`) because the haos stack is critical. | [Docker Hub](https://hub.docker.com/_/eclipse-mosquitto) |
| `ghcr.io/koenkk/zigbee2mqtt` | haos | review | Tags `latest`, `X.Y.Z`; check the changelog for breaking changes. | [docker](https://www.zigbee2mqtt.io/guide/installation/02_docker.html) |
| `openthread/border-router` | haos | review | Docs use `latest`; monthly `vYYYY.MM.x` release tags exist and are what Renovate follows. | [docker guide](https://openthread.io/guides/border-router/docker) |
| `ghcr.io/matter-js/matterjs-server` | haos | review | `stable` in the docs; versions `X.Y.Z` published. | [README](https://github.com/matter-js/matterjs-server) |
| `ghcr.io/riddix/home-assistant-matter-hub` | matter-hub | review | `latest` = stable channel; some releases need devices re-paired. | [README](https://github.com/RiDDiX/home-assistant-matter-hub) |
| `ghcr.io/blakeblackshear/frigate` | frigate | review | Pin the version tag, read release notes for config changes, back up `/config` (config.yml, frigate.db) first. | [updating](https://docs.frigate.video/frigate/updating) |
| `nextcloud` | nextcloud | sequential | One major version at a time (30 → 31 → …). | [docker README](https://github.com/nextcloud/docker#update-to-a-newer-version), [release schedule](https://github.com/nextcloud/server/wiki/Maintenance-and-Release-Schedule) |
| `collabora/code` | nextcloud | batch | Versioned tags `YY.MM.x.y.z`. | [Docker Hub](https://hub.docker.com/r/collabora/code) |
| `ghcr.io/zulip/zulip-server` | zulip | review | Pin the image tag; read the upgrade notes for every version in between; companions from docker-zulip's compose. | [docker-zulip](https://github.com/zulip/docker-zulip) |
| `zulip/zulip-postgresql` | zulip | companion | The tag in docker-zulip's compose (`14`). | [compose](https://github.com/zulip/docker-zulip/blob/main/compose.yaml) |
| `memcached` | zulip | companion | The tag in docker-zulip's compose (`alpine`). | [compose](https://github.com/zulip/docker-zulip/blob/main/compose.yaml) |
| `rabbitmq` | zulip | companion | The tag in docker-zulip's compose (`4.2`). | [compose](https://github.com/zulip/docker-zulip/blob/main/compose.yaml) |
| `vabene1111/recipes` | recipes | review | Use `X.Y.Z` for stability; migrations can't be undone (no downgrade). | [docker](https://docs.tandoor.dev/install/docker/) |
| `ghcr.io/open-webui/open-webui` | open-webui | review | Pin `vX.Y.Z` (never `:main`), read release notes, back up before every update. | [updating](https://docs.openwebui.com/getting-started/updating) |
| `ollama/ollama` | open-webui | batch | Versioned tags. | [Docker Hub](https://hub.docker.com/r/ollama/ollama) |
| `vikunja/vikunja` | notes | review | Examples untagged; changelog lists breaking changes. | [docker example](https://vikunja.io/docs/full-docker-example/), [changelog](https://vikunja.io/changelog) |
| `mariadb` | notes | db | Vikunja's example uses `mariadb:10`; 10.11 is the LTS line. | [docker example](https://vikunja.io/docs/full-docker-example/) |
| `couchdb` | notes | db | Obsidian LiveSync needs CouchDB 3.x. | [Docker Hub](https://hub.docker.com/_/couchdb) |
| `technitium/dns-server` | network | review | Docs show `latest`; versioned tags published. DNS for the LAN: read the changelog. | [Docker Hub](https://hub.docker.com/r/technitium/dns-server) |
| `cloudflare/cloudflared` | network | review | Calendar-versioned tags; keep within Cloudflare's supported window (about a year). | [Docker Hub](https://hub.docker.com/r/cloudflare/cloudflared) |
| `traefik` | traefik | review | Exact `vX.Y.Z`; read the migration guide for minors. | [migration](https://doc.traefik.io/traefik/migration/v3/) |
| `tecnativa/docker-socket-proxy` | traefik | batch | Versioned tags. | [README](https://github.com/Tecnativa/docker-socket-proxy) |
| `crowdsecurity/crowdsec` | crowdsec | batch | Versioned tags. | [Docker Hub](https://hub.docker.com/r/crowdsecurity/crowdsec) |
| `binwiederhier/ntfy` | ntfy | batch | Versioned tags. | [install](https://docs.ntfy.sh/install/) |
| `devture/exim-relay` | smtp-relay | batch | Versioned tags `X.Y-rN-N`. | [Docker Hub](https://hub.docker.com/r/devture/exim-relay) |
| `grafana/grafana-oss` | monitoring | batch | Versioned tags. | [docker](https://grafana.com/docs/grafana/latest/setup-grafana/installation/docker/) |
| `prom/prometheus` | monitoring | batch | Versioned tags. | [install](https://prometheus.io/docs/prometheus/latest/installation/) |
| `grafana/loki` | monitoring | batch | Versioned tags; read upgrade notes on majors. | [upgrade](https://grafana.com/docs/loki/latest/setup/upgrade/) |
| `grafana/alloy` | monitoring | batch | Versioned tags. | [docker](https://grafana.com/docs/alloy/latest/set-up/install/docker/) |
| `telegraf` | monitoring | batch | Versioned tags. | [Docker Hub](https://hub.docker.com/_/telegraf) |
| `influxdb` | monitoring | db | `latest` still means 2.x; InfluxDB 3 is a separate product, so Renovate is held below 3. | [Docker Hub](https://hub.docker.com/_/influxdb) |
| `louislam/uptime-kuma` | monitoring | batch | Major tag `2` in docs; pinned exact. | [README](https://github.com/louislam/uptime-kuma) |
| `ghcr.io/hotio/radarr` | servarr | batch | `release` channel; versioned `release-X.Y.Z.B` tags. | [hotio](https://hotio.dev/containers/radarr/) |
| `ghcr.io/hotio/sonarr` | servarr | batch | As radarr. | [hotio](https://hotio.dev/containers/sonarr/) |
| `ghcr.io/hotio/prowlarr` | servarr | batch | As radarr. | [hotio](https://hotio.dev/containers/prowlarr/) |
| `ghcr.io/hotio/sabnzbd` | servarr | batch | `release-X.Y.Z` tags. | [hotio](https://hotio.dev/containers/sabnzbd/) |
| `lscr.io/linuxserver/bazarr` | servarr | batch | linuxserver tags `vX.Y.Z-lsN`. | [linuxserver](https://docs.linuxserver.io/images/docker-bazarr/) |
| `lscr.io/linuxserver/readarr` | servarr | off | Project retired June 2025, image archived. Remove or replace. | [deprecation](https://github.com/linuxserver/docker-readarr) |
| `ghcr.io/seerr-team/seerr` | servarr | batch | Versioned tags `vX.Y.Z`. | [docs](https://docs.seerr.dev/getting-started/docker/) |
| `cy01/blackhole` | servarr | batch | Versioned tags `vX.Y`. | [Docker Hub](https://hub.docker.com/r/cy01/blackhole) |
| `deluan/navidrome` | deezer | batch | Versioned tags. | [docker](https://www.navidrome.org/docs/installation/docker/) |
| `ghcr.io/bambanah/deemix` | deezer | batch | Versioned tags `vX.Y.Z`. | [README](https://github.com/bambanah/deemix) |
| `lscr.io/linuxserver/beets` | deezer | batch | linuxserver tags `X.Y.Z-lsN`. | [linuxserver](https://docs.linuxserver.io/images/docker-beets/) |
| `bugattiguy527/termix` | dev | batch | Tags `X.Y.Z` (older `release-X.Y.Z`). | [README](https://github.com/Termix-SSH/Termix) |
| `ghcr.io/gethomepage/homepage` | homepage | batch | Versioned tags `vX.Y.Z`. | [install](https://gethomepage.dev/installation/docker/) |
| `ghcr.io/moghtech/komodo-core` | komodo | review | Upstream compose uses major tag `2`; Core and Periphery on the same version (grouped PR). Not a Komodo stack: deploy by hand (below). | [setup](https://komo.do/docs/setup/mongo) |
| `ghcr.io/moghtech/komodo-periphery` | komodo-periphery | review | As komodo-core. | [setup](https://komo.do/docs/setup/connect-servers) |
| `mongo` | komodo | sequential | Komodo's compose runs untagged `mongo`; MongoDB upgrades one major at a time, setting featureCompatibilityVersion after each. | [release notes](https://www.mongodb.com/docs/manual/release-notes/) |
| `ghcr.io/nikosch86/docker-proxmox-backup-server` | pbs (pbs-pc) | review | Versioned tags `vX.Y.Z-<pbs version>`; it's a backup server. | [README](https://github.com/nikosch86/docker-proxmox-backup-server) |
| `ghcr.io/actions/actions-runner` | ops (Dockerfile) | batch | Versioned tags; the runner self-updates too. | [releases](https://github.com/actions/runner/releases) |
| `alpine` | pre-deploy backups (`scripts/pre-deploy-backup.sh`) | batch | Helper for tar; any current release. | [Docker Hub](https://hub.docker.com/_/alpine) |

## Catch-up (state on 2026-10-24)

Pinned at what was running. These are behind enough that the docs' upgrade path matters; each step is
its own PR (Renovate opens most of them), merged in order:

1. **Nextcloud 30 → 35** (30 is end of life since 2025-10): 31, 32, 33, 34, 35, one at a time.
2. **authentik 2024.10.2 → 2026.8.x**: every release line in order (2024.12, 2025.2, … 2026.8). At
   2025.10 remove the `redis` service (CI flags it from the upstream compose).
3. **Immich**: first switch `redis` and `database` to the images in the v2.7.5 release compose
   (`valkey/valkey:9@…`, `postgres:14-vectorchord0.4.3…@…`), then v3 (read the v3.0.0 breaking changes,
   update the phone apps first). Then delete the `allow_drift` entries in `scripts/image-policy.json`.
4. **Strapi's database** (`backend_cms`): `postgres:12.0-alpine` is end of life; dump, move to a supported
   major, restore.
5. **Readarr**: retired upstream; remove it or pick a replacement.
6. **cloudflared 2024.10.1**: outside Cloudflare's support window; update (Renovate's first review PR).
7. **OpenThread Border Router**: pinned to the running build `sha-57d556f`. Renovate only understands the
   monthly `vYYYY.MM.x` tags, so move it to one by hand once (next haos change).
8. **servarr** apps are ~21 months behind; the weekly batch catches them up (Radarr 5 → 6 is a major PR).

## Komodo itself

`docker-compose/komodo` and `docker-compose/komodo-periphery` aren't Komodo stacks (Komodo can't redeploy
itself), so merging their Renovate PR deploys nothing. After merging, in an attended `pve-root` session
(or an ops request), Core first, then the Periphery on each Docker host (104 = docker-tower, 101 = docker-prod):

```bash
R=https://raw.githubusercontent.com/dcvdiego/homelab/main/docker-compose
pct exec 104 -- sh -c "cd /etc/komodo/core && cp docker-compose.yml docker-compose.yml.bak && curl -fsSLo docker-compose.yml $R/komodo/docker-compose.yml && docker compose --env-file compose.env up -d"
for ct in 104 101; do pct exec $ct -- sh -c "cd /etc/komodo/periphery && cp docker-compose.yml docker-compose.yml.bak && curl -fsSLo docker-compose.yml $R/komodo-periphery/docker-compose.yml && docker compose up -d"; done
```

The files on the hosts are copies of the repo's; diff them first if anything was changed there by hand.
