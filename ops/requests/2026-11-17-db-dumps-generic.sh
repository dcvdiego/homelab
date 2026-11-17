# Install this commit's scripts/db-dumps.sh on docker-prod (CT 101): MariaDB containers are now found
# by image instead of by name, so the script covers the private repo's stacks without naming them.
# Today that finds the same two containers as the old list (checked from the agents box).
#
# The current script is kept as /docker/scripts/db-dumps.sh.bak-2026-11-17. Nothing is dumped now:
# the nightly cron (01:30) runs the new one. The output lists the MariaDB containers it will dump.
#
# Undo: `pct exec 101 -- mv /docker/scripts/db-dumps.sh.bak-2026-11-17 /docker/scripts/db-dumps.sh`.
set -u
PVE() { ssh -F "$OPS_SSH_CONFIG" pve "$@"; }

PVE 'set -e; umask 077; cat > /root/db-dumps.sh' < scripts/db-dumps.sh
PVE 'set -e
     pct exec 101 -- sh -c "[ -e /docker/scripts/db-dumps.sh.bak-2026-11-17 ] || cp -p /docker/scripts/db-dumps.sh /docker/scripts/db-dumps.sh.bak-2026-11-17"
     pct push 101 /root/db-dumps.sh /docker/scripts/db-dumps.sh --perms 700 --user 0 --group 0
     rm -f /root/db-dumps.sh
     pct exec 101 -- bash -n /docker/scripts/db-dumps.sh'
echo "db-dumps: installed"
echo "MariaDB containers the next run dumps:"
PVE "pct exec 101 -- docker ps -a --format '{{.Names}} {{.Image}}'" \
  | awk '$2 ~ /^(docker\.io\/(library\/)?)?mariadb[:@]/ {print "  " $1}'
