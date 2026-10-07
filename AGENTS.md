# Homelab — agent context

This is the working directory for managing a self-hosted homelab. On the owner's WSL machine, load
`.env` for credentials before making API calls. On the agents box there is no `.env`: see below.

Site facts that identify the owner (the public domain, `$DOMAIN`) are not in this public repo: read
them from `site.env` in the repo root (gitignored; template `site.example.env`). Docs write
`$DOMAIN` / `<sub>.$DOMAIN` wherever the real domain goes.

## Working from the agents box (LXC 102)

There is no `.env`, no API token and no host SSH key on the agents box, by design. Don't look for
credentials or copy them in. Everything goes through Warpgate (LXC 106) or unauthenticated read APIs.

| Need | Use |
|---|---|
| Metrics, logs | Prometheus `http://192.168.1.224:9090`, Loki `http://192.168.1.224:3100` (no auth) |
| Read-only shell | `ssh pve-ro`, `ssh docker-prod-ro`, `ssh docker-tower-ro`: user `ai-agent` with journals, `/var/log`, `sudo pct list/config/status`, `sudo pvesm status`, `sudo docker ps/logs/top/stats/images/compose ls` |
| A change, owner **not** watching | Open a PR (below). Don't wait for it: say what you proposed and stop |
| A change, owner watching (debugging, upgrades) | `ssh pve-root`: root on pvehost, needs the owner's approval |

### Changes while the owner is away: PR

1. Commit on a branch in `~/homelab`: compose edits under `docker-compose/`, anything else as a
   script in `ops/requests/` (read `ops/requests/README.md` first).
2. `git push -u origin <branch>` and `gh pr create` (as the bot account `homelabsito`). Say in the
   PR what it changes, why, and how to undo it.
3. Stop there. The owner reviews the diff, merges, and approves the deployment from the phone.
   The runner applies it; read the output afterwards with
   `ssh docker-tower-ro cat /docker/ops/results/<run id>/<request>.log`.

### Changes while the owner is watching: `pve-root`

- The first connection **waits up to 15 min** until the owner approves it from the phone. Before
  you connect, say what you're going to do and why, so the approval is an informed one.
- An approval usually covers the next hour. Plan the work to fit, and don't retry in a loop if a
  connection hangs: it is waiting for approval.
- Run one command per call (`ssh pve-root 'cmd'`); reach an LXC with `pct exec <vmid> -- <cmd>`.
- Cloudflare and Technitium write tokens are in `/root/homelab.env` on pvehost: `ssh pve-root 'set -a; . /root/homelab.env; set +a; curl …'`. Never print them.
- Every session is recorded. The Access Priority and Rules below still apply: read before
  editing, back up before risky changes (`vzdump`, or `cp file file.bak-<date>`), confirm destructive steps.
- Afterwards, put anything that should persist (config, compose) into the repo as a PR, so git
  stays the source of truth.

Design and threat model: [docs/agent-access.md](docs/agent-access.md).

## Topology

| Node | Type | IP | VMID | Purpose |
|------|------|----|------|---------|
| pvehost | Proxmox host | 192.168.1.148 | — | Hypervisor |
| vault | LXC | 192.168.1.172 | 100 | HashiCorp Vault |
| docker-prod | LXC | 192.168.1.224 | 101 | Docker (Portainer agent :9001) |
| agents | LXC | 192.168.1.226 | 102 | AI agents box: herdr + Collie + CodexBar (was docker-dev; see docs/agents.md) |
| docker-tower | LXC | 192.168.1.248 | 104 | Docker primary (Portainer UI :9443) |
| jellyfin | LXC | 192.168.1.174 | 201 | Media server |
| warpgate | LXC | 192.168.1.227 | 106 | Warpgate SSH gateway for agents: SSH :2222, admin UI https://warpgate.homelab.lan:8888 (see docs/agent-access.md) |
| pbs | LXC | 192.168.1.251 | 105 | Proxmox Backup Server 3.4.8 (primary, pbs-lxc storage, homelab-backups datastore 3TB HDD) |
| pbs-pc | Ubuntu dual-boot | 192.168.1.50 | — | PBS secondary (Docker, sync from LXC) |

External access via **Cloudflare Tunnel** (selective services only).
`docker-prod` also has **Tailscale** (its `100.x` tailnet address is the tailnet's DNS server).

## Access Priority (use the highest available method)

**Always prefer APIs and local CLIs over SSH. Reserve `homelab-root` as an absolute last resort.**

| Priority | Method | Use when |
|----------|--------|----------|
| 1 | **Proxmox API** | Reading node/LXC/storage/network/firewall state |
| 2 | **Portainer API** | Anything Docker: containers, stacks, logs, exec, images, networks, volumes |
| 3 | **Local CLIs** | `promtool` (Prometheus queries), `logcli` (Loki log queries), `grafanactl` (Grafana dashboards/datasources) |
| 4 | **SSH `docker-prod` / `docker-tower`** | Reading files inside LXCs that aren't exposed via API |
| 5 | **SSH `homelab`** | Reading Proxmox host files not exposed via API |
| 6 | **SSH `homelab-root`** | **Last resort only** — writing to Proxmox host, `pct exec`, editing LXC configs |

### Proxmox API (read-only)
```bash
source .env
curl -sk -H "Authorization: PVEAPIToken=$PROXMOX_USER!$PROXMOX_TOKEN_ID=$PROXMOX_TOKEN_SECRET" \
  https://$PROXMOX_HOST:8006/api2/json/<endpoint>
```
Role: `PVEAuditor` — read-only across nodes, VMs, storage, network, firewall.

Key endpoints:
- `GET /api2/json/nodes` — list nodes
- `GET /api2/json/nodes/{node}/lxc` — list all LXCs
- `GET /api2/json/nodes/{node}/lxc/{vmid}/config` — LXC config (network, resources)
- `GET /api2/json/nodes/{node}/lxc/{vmid}/status/current` — LXC status (running/stopped, uptime, CPU, memory)
- `GET /api2/json/nodes/{node}/network` — host network interfaces
- `GET /api2/json/nodes/{node}/firewall/rules` — firewall rules
- `GET /api2/json/nodes/{node}/lxc/{vmid}/firewall/rules` — per-LXC firewall rules
- `GET /api2/json/nodes/{node}/storage` — storage pools
- `GET /api2/json/cluster/resources` — all resources in one call

### Portainer API (full access)
Base URL: `https://$PORTAINER_HOST:$PORTAINER_PORT`
```bash
source .env
curl -sk -H "x-api-key: $PORTAINER_TOKEN" \
  https://$PORTAINER_HOST:$PORTAINER_PORT/api/<endpoint>
```

Key endpoints:
- `GET  /api/endpoints` — list Docker environments
- `GET  /api/endpoints/{id}/docker/containers/json` — list containers
- `GET  /api/endpoints/{id}/docker/containers/{id}/logs?stdout=true&stderr=true&tail=100` — container logs
- `POST /api/endpoints/{id}/docker/containers/{id}/exec` — exec into container
- `GET  /api/stacks` — list all stacks
- `POST /api/stacks/create/standalone/string?endpointId={id}` — deploy stack
- `PUT  /api/stacks/{id}?endpointId={id}` — update stack
- `PUT  /api/stacks/{id}/git/redeploy?endpointId={id}` — redeploy git-backed stack

Known endpoint IDs: `2` = docker-tower (local), `3` = docker-prod (agent), `4` = docker-dev (retired — LXC 102 is now `agents`, no Portainer agent)

### Cloudflare API (DNS + Tunnel)
```bash
source .env
# CF_TOKEN, CF_ACCOUNT, CF_ZONE, CF_TUNNEL are in .env

# Add CNAME for a new subdomain
curl -sS -X POST -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
  -d "{\"type\":\"CNAME\",\"name\":\"<sub>.$DOMAIN\",\"content\":\"$CF_TUNNEL.cfargotunnel.com\",\"proxied\":true}" \
  "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records"

# Get current tunnel ingress config (always GET first before PUT)
curl -sS -H "Authorization: Bearer $CF_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT/cfd_tunnel/$CF_TUNNEL/configurations"

# PUT full tunnel config (replace entire ingress array; always end with catchall)
# Each rule: {"hostname":"<sub>.$DOMAIN","service":"https://traefik","originRequest":{"noTLSVerify":true}}
# Catchall:  {"service":"http_status:404"}
```

### Technitium DNS API (docker-tower, 192.168.1.248:5380)
Technitium runs on docker-tower. Its container has no curl/wget, so use bash `/dev/tcp` from inside the container (via Portainer exec on endpoint 2) or call it directly from the WSL host.

```bash
source .env
TECH_IP="192.168.1.248"; TECH_PORT="5380"

# Login and get token
TOKEN=$(curl -sS "http://$TECH_IP:$TECH_PORT/api/user/login?user=admin&pass=$TECHNITIUM_PASSWORD&includeInfo=false" | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')

# Add an A record to homelab.lan
curl -sS "http://$TECH_IP:$TECH_PORT/api/zones/records/add?token=$TOKEN&domain=<name>.homelab.lan&zone=homelab.lan&type=A&ipAddress=192.168.1.224&ttl=3600"

# List records in a zone
curl -sS "http://$TECH_IP:$TECH_PORT/api/zones/records/get?token=$TOKEN&domain=homelab.lan&zone=homelab.lan" | python3 -m json.tool
```

**Required in `.env`:** `TECHNITIUM_PASSWORD=<admin password>`

Records are per instance: add split-DNS/`homelab.lan` records to **both** `192.168.1.248` and
`192.168.1.224`.

**Tailnet DNS depends on docker-prod.** Tailscale's only global nameserver is docker-prod's tailnet address
(Technitium on docker-prod) with override on, so if docker-prod leaves the tailnet or
`technitium-dns` stops, tailnet devices lose all public DNS ("Tailscale on = no internet").
docker-prod needs `/etc/systemd/resolved.conf.d/no-stub-listener.conf` (`DNSStubListener=no`) or
the container can't bind `:53`. Never remove it. Full write-up, incident and open
recommendations: [docs/networking.md → DNS](docs/networking.md#failure-modes-and-monitoring).

### Uptime Kuma (monitoring stack, docker-prod)
No host port: reach it at `https://status.$DOMAIN`, which is behind Cloudflare Access
publicly but resolves to Traefik (`192.168.1.224`) via Technitium split DNS on LAN/tailnet (A record
only, so force IPv4). Provision monitors with `scripts/uptime-kuma-monitors.py`. It is idempotent
(skips existing names) and needs `KUMA_USER`, `KUMA_PWD`, `KUMA_PUSH_TAILNET_DNS` from `.env` and `DOMAIN` from `site.env`. WSL
has no venv support; run it on the agents box:
```bash
scp -q scripts/uptime-kuma-monitors.py agents:/tmp/k.py
cat site.env <(grep -E '^KUMA_' .env) | ssh agents 'set -a; . /dev/stdin; set +a; \
  /home/linuxbrew/.linuxbrew/bin/uv run -q --no-project --with "python-socketio[client]" \
  --with websocket-client python /tmp/k.py; rm -f /tmp/k.py'
```
Kuma v2 delivers the monitor list as a `monitorList` **event**, not as `getMonitorList`'s
callback; the script refuses to run without it (it once duplicated every monitor).

### Local CLI tools
```bash
# Prometheus — query metrics, check config, check rules
export PROMETHEUS_ADDR="http://192.168.1.224:9090"
promtool query instant 'up'
promtool check config prometheus.yml

# Loki — query logs from any container/service
export LOKI_ADDR="http://192.168.1.224:3100"
logcli query '{container="grafana"}' --limit=20 --since=1h

# Grafana — manage dashboards, datasources, alerts
grafanactl <subcommand>
```

### SSH (fallback only)
```bash
ssh homelab           # ai-agent user (restricted sudo) — reads on Proxmox host
ssh homelab-root      # root — LAST RESORT, only for writes to host/LXC configs
ssh docker-prod       # ai-agent@192.168.1.224 (LXC 101) — reads inside container
ssh docker-tower      # ai-agent@192.168.1.248 (LXC 104) — reads inside container
ssh agents            # diego@192.168.1.226 (LXC 102) — agents box, owns its own workloads
```
Key: `~/.ssh/homelab_agent`

Use `homelab-root` + `pct exec <vmid> -- <cmd>` only when writes to an LXC are needed and no API alternative exists.

## Repository Structure

```
homelab/
├── AGENTS.md              # this file (read by every agent CLI)
├── site.example.env       # template for site.env (gitignored): DOMAIN and other identifying facts
├── .env                   # secrets on the owner's machine only — never commit
├── docker-compose/<stack>/ # one dir per Portainer stack: docker-compose.yml + example.env (+ config/)
├── ops/                   # agent access: Warpgate setup and notifier, PR request runner, request guide
├── .github/workflows/     # apply.yml: applies approved PRs on the self-hosted runner
├── scripts/               # one-off and idempotent helpers (Kuma monitors, Technitium, restore test, Warpgate)
├── docs/                  # design notes: agent access, networking/DNS, agents box, Komodo migration
└── terraform/             # Proxmox IaC (WIP)
```

## Common Tasks

### Redeploy a Git-backed stack via Portainer API
**Always include `env` in the body — omitting it wipes all stored env vars for that stack.**
```bash
source .env
# Get stack ID and current env vars first
STACK_ID=39
EP_ID=3
# Redeploy (env array from GET /api/stacks response)
curl -sk -X PUT -H "x-api-key: $PORTAINER_TOKEN" -H "Content-Type: application/json" \
  -d '{"pullImage":false,"prune":false,"env":[{"name":"KEY","value":"VALUE"}]}' \
  https://$PORTAINER_HOST:$PORTAINER_PORT/api/stacks/$STACK_ID/git/redeploy?endpointId=$EP_ID
```

### List stacks and env vars
```bash
source .env
curl -sk -H "x-api-key: $PORTAINER_TOKEN" \
  https://$PORTAINER_HOST:$PORTAINER_PORT/api/stacks | python3 -m json.tool | grep -E '"Id"|"Name"'
```

### Query Proxmox nodes
```bash
source .env
curl -sk -H "Authorization: PVEAPIToken=$PROXMOX_USER!$PROXMOX_TOKEN_ID=$PROXMOX_TOKEN_SECRET" \
  https://$PROXMOX_HOST:8006/api2/json/nodes | python3 -m json.tool
```

### Enter a container to inspect/edit files
```bash
ssh homelab-root
# then on pvehost:
pct enter 104   # docker-tower
pct enter 101   # docker-prod
```

### Terraform (Proxmox IaC)
```bash
cd terraform/
terraform init
terraform plan -var-file="example.tfvars"
```
Credentials go in a `terraform.tfvars` (gitignored).

## Traefik & Auth Patterns

All services use `${DOMAIN}` for subdomain routing via Traefik labels. `DOMAIN` is set per-stack in the Portainer UI (never committed).

### Adding a new service — checklist

Do ALL of these every time, in order:

1. Add Traefik labels to the service in `docker-compose.yml` (router + service port)
2. Do NOT bind the HTTP port to the host (remove `ports:` for the web UI)
3. Add `DOMAIN=` to `example.env`
4. Decide auth strategy based on the table below before enabling a middleware
5. **Add a Cloudflare DNS CNAME** for `<subdomain>.$DOMAIN` → `$CF_TUNNEL.cfargotunnel.com` (proxied=true) via CF API
6. **Add a Cloudflare Tunnel ingress rule** mapping `<subdomain>.$DOMAIN` → `https://traefik` with `noTLSVerify: true`
7. **Add a Technitium DNS A record** for `<service>.homelab.lan` → docker-prod IP (`192.168.1.224`) via Technitium API

Steps 5–7 must be done for every new externally-accessible service, not just Traefik itself.

### Auth strategy by client type

| Client type | Auth approach | Forward auth safe? |
|---|---|---|
| Browser-only (Grafana, Portainer, Tandoor) | Authentik forward auth via Traefik | Yes |
| Has mobile app with API (Immich, Vikunja) | Native OIDC only — keep app's built-in auth | **No — breaks mobile** |
| Has API/sync client (Vaultwarden, CouchDB) | App's own auth | **No — breaks client** |
| Proxmox | Native OIDC at node level, nothing to do with Traefik | N/A |

### Enabling Authentik forward auth on a service
Uncomment the middleware label on the router, then in the Authentik UI:
1. Create a **Proxy Provider** (Forward auth single application) for the subdomain
2. Assign it to an **Application**
3. The embedded outpost picks it up automatically

The middleware is defined on `authentik-server` in the `security` stack and referenced cross-stack as `authentik-forwardauth@docker`.

## Home Assistant Stack

Stack name in Portainer: **haos** (endpoint 3, docker-prod). Compose file: `docker-compose/haos/docker-compose.yml`.

### Services

| Container | Image | Notes |
|-----------|-------|-------|
| `homeassistant` | `ghcr.io/home-assistant/home-assistant:stable` | `network_mode: host`; config at `/docker/ha` |
| `mosquitto` | `eclipse-mosquitto:2` | MQTT broker; config at `/docker/mosquitto/config/mosquitto.conf`; port 1883 |
| `zigbee2mqtt` | `ghcr.io/koenkk/zigbee2mqtt:latest` | Z2M; data at `/docker/zigbee2mqtt/data`; frontend at `https://zigbee2mqtt.$DOMAIN` |
| `otbr` | `openthread/border-router:latest` | Thread border router; `network_mode: host`; REST API port 8083; `FIREWALL=0` required in LXC |
| `matter-server` | `ghcr.io/matter-js/matterjs-server:stable` | Matter controller; `network_mode: host`; WebSocket `ws://localhost:5580/ws`; data owned by uid 1000:1000 |

### USB devices (passed through Proxmox host → LXC 101 → containers)

| Device | Host path | Container | Purpose |
|--------|-----------|-----------|---------|
| Silicon Labs ZBT-2 | `/dev/ttyACM0` | otbr | Thread RCP (flashed with OpenThread RCP firmware — not Zigbee) |
| Sonoff Zigbee 3.0 Plus V2 | `/dev/ttyUSB0` | zigbee2mqtt | Zigbee coordinator (`adapter: ember`, EFR32MG21 chip) |

Proxmox passthrough config in `/etc/pve/lxc/101.conf` — cgroup2 allow entries + mount entries. Udev rules in `/etc/udev/rules.d/99-usb-serial.rules` on Proxmox host set mode 0666.

### Key config files (inside LXC 101)

- `/docker/zigbee2mqtt/data/configuration.yaml` — Z2M config; MQTT server `mqtt://mosquitto:1883`
- `/docker/mosquitto/config/mosquitto.conf` — must have `listener 1883` (Mosquitto 2.x doesn't bind 0.0.0.0 by default)
- `/docker/ha/automations.yaml` — HA automations (written directly; reload via HA Developer Tools → YAML → Reload Automations)
- `/docker/ha/.storage/auth` — HA auth tokens (JSON); contains long-lived token for `homepage` integration

### Thread network

Network name, dataset and OMR prefix: ask OTBR (`docker exec otbr ot-ctl dataset active`, `ot-ctl state`). IPv6 forwarding must be enabled on LXC 101 (`net.ipv6.conf.all.forwarding=1`); persisted via `/etc/sysctl.d/60-otbr-ip-forward.conf` written by OTBR setup-host script.

### Devices and entities

Don't trust a hardcoded list: query them live. Z2M devices: the `zigbee2mqtt/bridge/devices` MQTT
topic or the Z2M frontend. HA entities: `GET /api/states` with a long-lived token, or Developer
Tools → States. Automations are in `/docker/ha/automations.yaml`.

## Cameras / Frigate Stack

Stack name in Portainer: **frigate** (ID 64, endpoint 3, docker-prod, web-editor stack — not Git-backed). Compose: `docker-compose/frigate/docker-compose.yml`. Seed config: `docker-compose/frigate/config/config.yml` → live at `/docker/frigate/config/config.yml` (push with `pct push 101`; Frigate 0.18 can also edit it from its Settings UI, so read the live file before overwriting). Frigate **0.18.0**, checked against the v0.18.0 docs.

### Cameras

Names below match the seed config; the live config may use others, so read it first.

| Frigate name | Source | Main stream | Sub/detect stream | Recorded by |
|---|---|---|---|---|
| `doorbell` | NVR ch0 | H.264 2560×1920, http-flv | H.264 896×672, http-flv | NVR |
| `garden` | NVR ch1 | H.265 4608×1728, RTSP `Preview_02_main` | H.264 1536×576, RTSP `Preview_02_sub` | NVR |
| `front_porch` | NVR ch2 | H.265 7680×2160, RTSP `Preview_03_main` | H.264 1536×432, RTSP `Preview_03_sub` | NVR |
| `kitchen` | E1 Pro (WiFi), `FRIGATE_WIFI1_IP` | H.264 2880×1616, RTSP `h264Preview_01_main` | H.264 896×512, RTSP `h264Preview_01_sub` | **Frigate**, 24/7, 7 days continuous (~32 GB/day) |
| `wifi_cam2` | E1 Pro (WiFi), `FRIGATE_WIFI2_IP` | H.264 2880×1616, RTSP | H.264 896×512, RTSP | **Frigate**, 24/7, 7 days continuous |

- E1 Pros: login in `FRIGATE_WIFI_*` in `.env`. I-frame interval set to 1× on both streams via API `SetEnc` (`gop: 1`). http-flv hangs on this firmware, so they use RTSP. Reolink locks accounts after about 5 failed logins, so don't guess passwords.
- NVR cameras keep their default I-frame intervals (main 2×, sub 4×). The NVR records them, so they were deliberately left alone.

- NVR at `FRIGATE_NVR_IP` (credentials in `FRIGATE_NVR_*` in `.env`). RTSP and RTMP (http-flv) must be enabled on it for Frigate. The NVR returns EOF for http-flv on the ≥6MP cameras → those use RTSP for both streams (matches the docs' Reolink table).
- NVR HTTP API: `https://$FRIGATE_NVR_IP/api.cgi?cmd=...`. Its `Search` doesn't return file names on this firmware; use `NvrDownload` (time range → `fileList`), then `cgi-bin/api.cgi?cmd=Download&source=<fileName>` (~0.8 MB/s).
- NVR cameras are detect + live only in Frigate (`record.enabled: false` globally). Recording has to be enabled per camera **in YAML**; the UI/MQTT toggle can't turn on recording that's disabled in config.

### Host / hardware

- LXC 101: 4 cores, `dev0: /dev/dri/renderD128,gid=108,mode=0660` (gid 108 = `render` inside the LXC). Backup of the previous config: `/root/101.conf.bak-2026-09-24` on pvehost.
- Detector: OpenVINO on the iGPU (bundled SSDLite model, ~10 ms). The docs now recommend YOLOv9 (needs an ONNX export).
- hwaccel: `preset-intel-qsv-h264` (docs recommend it for gen13+ Intel).
- Storage: recordings on `/data/frigate` (16TB HDD); config/DB on `/docker/frigate/config` (backed up).

### Access

- Ports: 8971 (authenticated UI, TLS disabled, Traefik → `frigate.${DOMAIN}`), 5000 (unauthenticated API, bound to `127.0.0.1` only), 8554 (RTSP restream), 8555 tcp/udp (WebRTC).
- Admin login: `FRIGATE_ADMIN_USER` / `FRIGATE_ADMIN_PASSWORD` in `.env`. Reset: add `auth: {reset_admin_password: true}` and restart; the new password is printed in the logs.
- DNS: Technitium A records `frigate.$DOMAIN` and `frigate.homelab.lan` → 192.168.1.224. Externally it's reachable through the `*.$DOMAIN` tunnel wildcard, behind **Cloudflare Access** (same as zigbee2mqtt).

### Integrations

- **HA**: native Reolink integration (NVR entry: `camera.*_fluent`, Reolink AI person/vehicle/animal sensors, sirens, lights) + Frigate custom integration **v5.15.6**, installed manually in `/docker/ha/custom_components/frigate` (no HACS; update by replacing the folder) at `http://127.0.0.1:5000` → `camera.doorbell`/`garden`/`front_porch`. MQTT via `mosquitto` (anonymous).
- **Prometheus**: job `frigate` scrapes `frigate:5000/api/metrics` over `network_default`. The live config is `/docker/grafana-monitoring/prometheus/config/prometheus.yml` (reload with SIGHUP; no lifecycle API).
- **Homepage** (docker-tower): Frigate widget via `https://frigate.$DOMAIN`, pinned to 192.168.1.224 with `extra_hosts` (docker-tower resolves through 1.1.1.1). Uses `HOMEPAGE_VAR_FRIGATE_*` stack env vars.

### Technitium split-DNS for local services

The `$DOMAIN` zone in Technitium is a **Forwarder** zone (→ 1.1.1.1). Local A records override specific subdomains (e.g. `zigbee2mqtt.$DOMAIN → 192.168.1.224`). This allows local-only access while Cloudflare handles external DNS for the same domain.

## Rules

- **API first, SSH last**: Always use Proxmox API / Portainer API / local CLIs before falling back to SSH. Never use `homelab-root` if there's an API or non-root SSH alternative. See Access Priority table above.
- **Never commit `.env` or any `*.env` file** (gitignored)
- **Never commit `*.tfvars`** except `example.tfvars`
- **Confirm before any destructive action**: stopping containers, deleting stacks, modifying Proxmox VMs
- **Read before editing**: always read a config file before modifying it
- `ai-agent` sudo is read-only — use root SSH only when writes to the host are needed
- Portainer API token has full access — be careful with POST/PUT/DELETE calls
- When adding a new service: create a `docker-compose/<service-name>/` directory with a `docker-compose.yml` and `example.env`
