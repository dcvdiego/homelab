# Workflow changes waiting for the owner

The GitHub App `homelabsito[bot]` can't push to `.github/workflows/` (by design: an agent must not
change what runs in CI). Workflow changes are proposed here and moved into place by the owner.

| File | Goes to | What |
|---|---|---|
| `image-policy.yml` | `.github/workflows/image-policy.yml` (new) | Image policy check on PRs, companion sync on Renovate PRs, weekly drift issue (docs/image-versions.md) |
| `pr-agent.yml` | `.github/workflows/pr-agent.yml` (replace) | Adds instructions for Renovate PRs (breaking changes and manual steps from the release notes) |

From the owner's machine, after the PR that added them is merged:

```bash
git switch main && git pull
git mv -f ops/pending-workflows/image-policy.yml .github/workflows/image-policy.yml
git mv -f ops/pending-workflows/pr-agent.yml .github/workflows/pr-agent.yml
git commit -m "Install image-policy workflow and PR-Agent Renovate instructions" && git push
```

No repository settings change is needed: the workflow asks for write access only in the jobs that
need it (`sync-companions`: push to the Renovate branch; `drift`: the issue). Optionally make
`image-policy / check` a required status check on `main`.

Leave this README here for the next one.
