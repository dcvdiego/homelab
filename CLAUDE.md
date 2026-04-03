# Homelab — Claude Code Context

This is the working directory for managing a self-hosted homelab. Always load `.env` for credentials before making API calls.

## Topology

| Node | Type | IP | VMID | Purpose |
|------|------|----|------|---------|
| pvehost | Proxmox host | 192.168.1.148 | — | Hypervisor |
| vault | LXC | 192.168.1.172 | 100 | HashiCorp Vault |
| docker-prod | LXC | 192.168.1.224 | 101 | Docker (Portainer agent :9001) |
| docker-dev | LXC | stopped | 102 | Docker dev environment |
| proxy | LXC | 192.168.1.230 | 103 | Reverse proxy |
| docker-tower | LXC | 192.168.1.248 | 104 | Docker primary (Portainer UI :9443) |
| jellyfin | LXC | 192.168.1.174 | 201 | Media server |

External access via **Cloudflare Tunnel** (selective services only).
`docker-prod` also has **Tailscale** at `100.97.221.5`.

## Access Methods

### SSH (Proxmox host)
```bash
ssh homelab           # ai-agent user (restricted sudo)
ssh homelab-root      # root (key-only, no password)
```
Key: `~/.ssh/homelab_agent`

### SSH (LXC containers — direct)
```bash
ssh docker-prod       # ai-agent@192.168.1.224 (docker-prod LXC 101) — use for reads
ssh docker-tower      # ai-agent@192.168.1.248 (docker-tower LXC 104) — use for reads
```
Use `homelab-root` + `pct exec <vmid> -- <cmd>` only when writes to an LXC are needed.

To enter an LXC container from Proxmox host:
```bash
ssh homelab-root "pct enter <vmid>"
# e.g. pct enter 104 for docker-tower
```

### Proxmox API
```bash
curl -sk -H "Authorization: PVEAPIToken=$PROXMOX_USER!$PROXMOX_TOKEN_ID=$PROXMOX_TOKEN_SECRET" \
  https://$PROXMOX_HOST:8006/api2/json/<endpoint>
```
The `ai-agent@pve` user has `PVEAuditor` role (read-only).

### Portainer API
Base URL: `https://$PORTAINER_HOST:$PORTAINER_PORT`
```bash
curl -sk -H "x-api-key: $PORTAINER_TOKEN" \
  https://$PORTAINER_HOST:$PORTAINER_PORT/api/endpoints
```
Key endpoints:
- `GET  /api/endpoints` — list all Docker environments
- `GET  /api/endpoints/{id}/docker/containers/json` — list containers
- `GET  /api/stacks` — list all stacks
- `POST /api/stacks/create/standalone/string?endpointId={id}` — deploy stack
- `PUT  /api/stacks/{id}?endpointId={id}` — update stack

Known endpoint IDs: `2` = docker-tower local

## Repository Structure

```
homelab/
├── CLAUDE.md              # this file
├── .env                   # secrets — never commit
├── .gitignore
├── docker-compose/        # compose files per service
│   ├── cloudflare-tunnel/
│   ├── immich/
│   └── tandoor/
├── docs/
└── terraform/             # Proxmox IaC
    ├── providers.tf        # telmate/proxmox provider configured
    ├── lxc-docker.tf       # LXC template
    └── example.tfvars
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

## Rules

- **Never commit `.env` or any `*.env` file** (gitignored)
- **Never commit `*.tfvars`** except `example.tfvars`
- **Confirm before any destructive action**: stopping containers, deleting stacks, modifying Proxmox VMs
- **Read before editing**: always read a config file before modifying it
- `ai-agent` sudo is read-only — use root SSH only when writes to the host are needed
- Portainer API token has full access — be careful with POST/PUT/DELETE calls
- When adding a new service: create a `docker-compose/<service-name>/` directory with a `docker-compose.yml` and `example.env`
