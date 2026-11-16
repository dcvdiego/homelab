# Forgejo and the private repo

Some stacks don't belong in a public repo. They live in **`diego/homelab-private`** on a self-hosted
Forgejo (`http://git.homelab.lan:3200`, LAN only). This repo keeps all the infrastructure, including
Forgejo itself. Komodo deploys from both. Which stacks moved, and the history clean-up, are recorded in
the private repo (`docs/forgejo-split.md` there), not here.

## Pieces

| Piece | Where | Notes |
|---|---|---|
| Forgejo | `docker-compose/forgejo` on docker-tower, port 3200 | Rootless image, SQLite. Sign-in required for every page, no self-registration, every repo private, no SSH. DNS: `git.homelab.lan` on both Technitium instances; no Cloudflare record or tunnel rule. |
| Users | `diego` (admin), `homelabsito` (agents: write, can't push or merge `main`), `renovate-bot` | Created by `ops/requests/2026-11-14-forgejo.sh`. |
| Runner | `forgejo-runner` in the same stack | Registered to `diego/homelab-private` only, label `homelab-private-ci`, host executor: jobs run in the container, which has **no Docker socket and no secrets**. CI only (image policy check on PRs). |
| Renovate | its own Komodo stack (Phase 3) | Not a runner job: its token stays in Komodo, not in Forgejo. Scheduled for Saturdays like the Mend app here. One Renovate per platform: the Mend GitHub app keeps serving this repo. |
| Deploys | Komodo UI | After merging in Forgejo, deploy the stack in Komodo (the stack shows the new commit). |
| Backups | Komodo pre-deploy (`scripts/pre-deploy-backup.sh forgejo`), vzdump of CT 104, and a **push mirror** of `homelab-private` to a private GitHub repo | Forgejo must not be the only copy of that code. The GitHub mirror is a backup, never the working copy. |

## Why no secrets in Forgejo

Here, deploy credentials are protected twice: the `homelab` environment needs an approval from
the phone, and the runner's `job-started.sh` refuses any job other than `apply.yml` on `main`. Forgejo
has neither: Actions secrets are repo-wide (no environments), and push-triggered workflows on any
branch of the repo get them. A branch pushed by `homelabsito`, which has write access, could run a
workflow that reads them. Branch protection on `main` doesn't help, because the workflow runs from the
branch. Registering the runner to one repo limits *which repo* can use it, not *which workflow*.

So Forgejo stores no deploy secrets at all:

- **No apply workflow.** You merge in Forgejo and deploy from the Komodo UI, which is already how you
  deploy ops stacks. The approval step is the same one tap, in Komodo instead of GitHub Mobile.
- **Renovate runs outside Forgejo Actions** (a Komodo stack with its token in the stack env).
- **No PR-Agent on the private repo.** Its job needs a model API key and would process untrusted PR
  text on the same runner. If it's wanted later, it gets its own runner and its own repo-scoped key.
- The runner then has nothing to steal. It uses the host executor because the docker executor needs
  the Docker socket, which means root on docker-tower, the host that also runs Komodo Core.

## Agent flow

Same rule as here: propose and stop.

- Public repo: `gh` as `homelabsito[bot]` (AGENTS.md).
- Private repo: `git` and the Forgejo API with the `homelabsito` token at `~/.config/homelab/forgejo-token`
  on the agents box (mode 600). Push a branch and open a PR. The token can't push or merge `main`.
- Ops requests here still run on the GitHub `homelab-ops` runner. A request for a private stack is
  written so it doesn't name the stack's contents, or is done live through `pve-root` with you
  watching.

## Phases

1. **Forgejo stack** (this repo): compose, DNS, users, repo with history, branch protection,
   runner, bot token: `ops/requests/2026-11-14-forgejo.sh`. Then, by hand: sign in as `diego`
   (initial password in CT 104 `/root/forgejo-initial-password`), set a password and 2FA, and add the
   push mirror (Settings → Repository → Mirror settings) to a private GitHub repo with a fine-grained
   PAT scoped to that one repo (contents: read and write).
2. **Seed `homelab-private`**: one trim commit on top of the copied history, keeping only the moved
   stacks plus their CI scaffolding (scripts, Renovate config, image docs, `AGENTS.md`). Opened as a PR
   by `homelabsito`, merged by you.
3. **Renovate** for the private repo: a Komodo stack, `platform: forgejo`, endpoint
   `http://git.homelab.lan:3200/api/v1/`, one repository, Saturdays.
4. **Repoint Komodo**: add a `[[git_provider]]` for `git.homelab.lan:3200` (`https = false`, account
   `homelabsito`, read token) to Komodo Core's config and restart Core. Then point the moved stacks at
   `diego/homelab-private` with the same branch and run directories, and deploy each one. Expect a no-op.
   Rollback: point them back at GitHub.
5. **Clean up this repo**: remove the moved files and references, then rewrite history. This is the
   only irreversible step, so do it last, on a quiet morning, after a vzdump. Force-pushing doesn't
   remove GitHub's pull-request refs and diff pages, so ask GitHub Support to purge them. Clones made
   before the rewrite keep the old history.
6. **Docs**: AGENTS.md and docs/agent-access.md get the private-repo flow and a Forgejo section.

Phases 1–4 only add things: nothing in this repo changes, and the stacks keep deploying from GitHub
until Phase 4's repoint proves out.

## Accepted trade-offs

- Two copies of CI scaffolding (scripts, Renovate config) that can drift. Keep shared files
  byte-identical; trim only what's stack-specific.
- Two Renovate dashboards on Saturdays.
- The infrastructure stays public by design. If that stops being comfortable, the escape hatch is
  the private repo absorbing everything.
