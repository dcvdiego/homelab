#!/usr/bin/env bash
# Runner-side guard, enforced before every job. Workflow YAML can't override it, so a fork PR or a
# workflow on any other branch can never run here, even if someone approves it by mistake.
want_repo="${REPO:-dcvdiego/homelab}"
want_wf="${want_repo}/.github/workflows/apply.yml@refs/heads/main"
if [[ "${GITHUB_REPOSITORY:-}" == "$want_repo" && "${GITHUB_WORKFLOW_REF:-}" == "$want_wf" \
   && "${GITHUB_REF:-}" == refs/heads/main \
   && ( "${GITHUB_EVENT_NAME:-}" == push || "${GITHUB_EVENT_NAME:-}" == workflow_dispatch ) ]]; then
  exit 0
fi
echo "::error::homelab-ops runner refuses ${GITHUB_EVENT_NAME:-?} from ${GITHUB_WORKFLOW_REF:-?}"
exit 1
