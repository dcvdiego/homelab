# Komodo migration, critical stacks (docs/komodo-migration.md phase 4.4). Backups first: PBS "pre-komodo
# 2026-10-07" of CT 101/104 plus DB dumps in /docker/backups/pre-komodo-2026-10-07/ (both done).
# One call per stack: the first failure stops the rest. Expect each service to restart once on adoption.
# haos accepts only the OT_LOG_LEVEL drift (repo 4 = intended; live 7 = debug); anything else blocks it.
# Undo per stack: delete it in Komodo and redeploy it from Portainer (record still there, same env).
M="python3 ops/bin/komodo-migrate.py migrate"
$M matter-hub@docker-prod
$M haos@docker-prod+drift=OT_LOG_LEVEL
$M security@docker-prod
$M photos@docker-prod
