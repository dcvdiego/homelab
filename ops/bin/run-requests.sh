#!/usr/bin/env bash
# Runs the ops requests added in this push (or the one named in a manual re-run).
# Output goes to /results/<run id>/<request>.log (/docker/ops/results on docker-tower), never to the
# public job log.
set -euo pipefail

if [ -n "${REQUEST:-}" ]; then
  [[ "$REQUEST" =~ ^ops/requests/[A-Za-z0-9._-]+\.sh$ && -f "$REQUEST" ]] || {
    echo "::error::request must be an existing ops/requests/<name>.sh"; exit 1; }
  requests=("$REQUEST")
elif [ -n "${BEFORE:-}" ] && [[ ! "$BEFORE" =~ ^0+$ ]]; then
  mapfile -t requests < <(git diff --diff-filter=A --name-only "$BEFORE" "$GITHUB_SHA" -- 'ops/requests/*.sh')
  git diff --diff-filter=M --name-only "$BEFORE" "$GITHUB_SHA" -- 'ops/requests/*.sh' |
    sed 's/^/::warning::edited, not re-run (add a new request instead): /'
else
  requests=()
fi
[ ${#requests[@]} -gt 0 ] || { echo "No ops requests to run."; exit 0; }

out="${RESULTS_DIR:-/results}/$GITHUB_RUN_ID"
mkdir -p "$out"
chmod 755 "$out"  # agents read results as ai-agent over `ssh docker-tower-ro`

# SSH alias "pve" = root on pvehost through Warpgate (user ops, target pve-root-ops, no approval:
# the owner already approved this job). The ops key exists only in the GitHub environment and only
# for this step; Warpgate accepts it only from docker-tower (192.168.1.248) and records the session.
ssh_dir="$(mktemp -d)"
trap 'rm -rf "$ssh_dir"' EXIT
if [ -n "${OPS_SSH_KEY:-}" ]; then
  printf '%s\n' "$OPS_SSH_KEY" > "$ssh_dir/key"
  printf '%s\n' "${WARPGATE_KNOWN_HOSTS:-}" > "$ssh_dir/known_hosts"
  chmod 600 "$ssh_dir/key"
  cat > "$ssh_dir/config" <<CFG
Host pve
  HostName 192.168.1.227
  Port 2222
  User ops:pve-root-ops
  IdentityFile $ssh_dir/key
  IdentitiesOnly yes
  UserKnownHostsFile $ssh_dir/known_hosts
  StrictHostKeyChecking yes
CFG
  export OPS_SSH_CONFIG="$ssh_dir/config"
fi

rc=0
for r in "${requests[@]}"; do
  log="$out/$(basename "$r" .sh).log"
  if (cd "$GITHUB_WORKSPACE" && bash -euo pipefail "$r") >"$log" 2>&1; then
    chmod 644 "$log"; echo "ok      $r"
  else
    code=$?; rc=1; chmod 644 "$log"
    echo "::error::$r failed with exit $code (output: /docker/ops/results/$GITHUB_RUN_ID/)"
  fi
done
exit $rc
