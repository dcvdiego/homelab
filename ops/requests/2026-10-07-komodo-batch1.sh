# Komodo migration, batch 1: non-critical stacks (docs/komodo-migration.md phase 4.1-4.2).
# Each: Komodo stack from git, same compose project, env copied from Portainer, deploy without pulling
# images; expected result "recreated: none". homepage: drift accepted (repo adds HOMEPAGE_VAR_DOMAIN,
# so homepage is recreated once). Undo per stack: delete it in Komodo; Portainer still has the record.
python3 ops/bin/komodo-migrate.py migrate \
  dev@docker-prod backend_cms@docker-prod smtp-relay@docker-prod open-webui@docker-prod \
  recipes@docker-prod notes@docker-prod zulip@docker-prod nextcloud@docker-prod deezer@docker-prod \
  servarr@docker-prod frigate@docker-prod monitoring@docker-prod ntfy@docker-prod crowdsec@docker-prod \
  homepage@docker-tower+drift
