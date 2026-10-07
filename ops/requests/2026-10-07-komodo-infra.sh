# Komodo migration, infrastructure (docs/komodo-migration.md phase 4.3). Order keeps DNS and the tunnel up:
# docker-prod's network first (docker-tower's Technitium + cloudflared keep serving), then traefik, then
# docker-tower's network (accepts only the cloudflared `command` drift: the --protocol http2 fix).
# ops (the runner's own stack) is registered without deploying: a deploy from this job would kill the job.
# Undo per stack: delete it in Komodo and redeploy from Portainer.
M="python3 ops/bin/komodo-migrate.py migrate"
$M network@docker-prod
$M traefik@docker-prod
$M network@docker-tower+drift=command
$M ops@docker-tower+nodeploy
