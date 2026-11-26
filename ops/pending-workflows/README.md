# Workflow changes waiting for the owner

The GitHub App `homelabsito[bot]` can't push to `.github/workflows/` (by design: an agent must not
change what runs in CI). Workflow changes are proposed here and moved into place by the owner.

| File | Goes to | What |
|---|---|---|
| `release-notes.yml` | `.github/workflows/release-notes.yml` (new) | Comments the official upgrade notes of pending image updates on the Renovate dashboard issue and on PRs that change versions (scripts/release-notes.py) |
| `pr-agent.yml` | `.github/workflows/pr-agent.yml` (replacement) | GLM-5.3 primary, Kimi K3.1 Pro fallback, 96k prompt budget, 300-second inference timeout, up to 3 review chunks and 6 findings, 25-minute job ceiling |

From the owner's machine, after the PR that added them is merged:

```bash
git switch main && git pull
git mv -f ops/pending-workflows/release-notes.yml .github/workflows/release-notes.yml
git commit -m "Install release-notes workflow" && git push
```

No repository settings change is needed: the workflow asks for write access only to comment
(`issues: write`, and `pull-requests: write` in the PR job). After installing it, run it once by hand
(Actions → release-notes → Run workflow) to fill the dashboard issue right away.

## Install the PR-Agent replacement

After merging the PR that adds `pr-agent.yml`, run from the owner's checkout:

```bash
git switch main
git pull --ff-only
# Inspect the replacement; preserve any newer workflow changes before installing.
git diff --no-index .github/workflows/pr-agent.yml ops/pending-workflows/pr-agent.yml
# The command above exits 1 when the files differ; that is expected.
git mv -f ops/pending-workflows/pr-agent.yml .github/workflows/pr-agent.yml
git commit -m "Install GLM-5.3 PR reviews with larger budgets"
git push
```

The merge alone does **not** activate the replacement. Installation changes no
secrets or permissions; streaming and trusted-user command restrictions are retained.
After installing, comment `/review` on an open PR and inspect the run details for
the model used. Check Go usage in Console; the models share one allowance.

The live [Go model catalog](https://opencode.ai/inference/go/v1/models), checked
2026-11-26, lists GLM-5.3's model-equivalent monthly allowance as $200 on Go /
$400 on Go Plus, versus $60 / $120 for Kimi K3.1 Pro. These are not separate cash
balances. [Go limits](https://opencode.ai/docs/console/go#usage-limits) still apply.
Larger prompts, high reasoning effort, and chunking can increase consumption and
runtime. The 3-call limit is the chunk-review budget, not a guarantee of 3 total
requests when fallbacks or review post-processing are needed; the 25-minute job
timeout is the outer ceiling. No paid overflow setting is changed by this file.

Undo after installation by reverting the installation commit, or disable the
PR Agent workflow in Actions. Leave this README here for the next one.
