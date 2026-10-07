#!/usr/bin/env bash
# Registers once (state lives in the ops_runner volume), then runs jobs with the guard hook.
set -euo pipefail
cd /home/runner
if [ ! -f .runner ]; then
  : "${RUNNER_TOKEN:?first start needs RUNNER_TOKEN: repo Settings > Actions > Runners > New self-hosted runner (valid 1h)}"
  ./config.sh --unattended --replace --url "https://github.com/${REPO:?}" --token "$RUNNER_TOKEN" \
    --name "${RUNNER_NAME:-homelab-ops}" --labels homelab-ops --no-default-labels --work _work
fi
unset RUNNER_TOKEN
export ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/ops/job-started.sh
exec ./run.sh
