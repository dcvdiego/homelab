# Komodo migration, step 1 (read-only): for every Portainer stack, compare its live compose file with
# the repo and list its env var names (values never printed). Changes nothing; nothing to undo.
python3 ops/bin/komodo-migrate.py check \
  homepage@docker-tower network@docker-tower ops@docker-tower \
  backend_cms@docker-prod crowdsec@docker-prod deezer@docker-prod dev@docker-prod frigate@docker-prod \
  haos@docker-prod matter-hub@docker-prod monitoring@docker-prod network@docker-prod nextcloud@docker-prod \
  notes@docker-prod ntfy@docker-prod open-webui@docker-prod photos@docker-prod recipes@docker-prod \
  security@docker-prod servarr@docker-prod smtp-relay@docker-prod traefik@docker-prod zulip@docker-prod
