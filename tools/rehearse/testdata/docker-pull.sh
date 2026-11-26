ssh -F "$OPS_SSH_CONFIG" pve "pct exec 101 -- docker image pull alpine:3.22"
ssh -F "$OPS_SSH_CONFIG" pve "cd /etc/komodo/stacks/x && docker compose -f docker-compose.yml pull"
ssh -F "$OPS_SSH_CONFIG" pve "docker save influxdb:2.8.0 -o /backup/i.tar"
ssh -F "$OPS_SSH_CONFIG" pve "docker compose up -d"
