# Workflow changes waiting for the owner

The GitHub App `homelabsito[bot]` can't push to `.github/workflows/` (by design: an agent must not
change what runs in CI). Workflow changes are proposed here and moved into place by the owner.

| File | Goes to | What |
|---|---|---|
| `ops-check.yml` | `.github/workflows/ops-check.yml` (new) | Before merge: renders every stack as Komodo's periphery sees it (scripts/check-compose-komodo.py) and rehearses added or edited ops requests in a sandboxed shell (tools/rehearse, Go); no secrets, read-only |
| `release-notes.yml` | `.github/workflows/release-notes.yml` (new) | Comments the official upgrade notes of pending image updates on the Renovate dashboard issue and on PRs that change versions (scripts/release-notes.py) |

From the owner's machine, after the PR that added them is merged:

```bash
git switch main && git pull
git mv -f ops/pending-workflows/<file>.yml .github/workflows/<file>.yml
git commit -m "Install <file> workflow" && git push
```

No repository settings change is needed: the workflow asks for write access only to comment
(`issues: write`, and `pull-requests: write` in the PR job). After installing it, run it once by hand
(Actions → release-notes → Run workflow) to fill the dashboard issue right away.

Leave this README here for the next one.
