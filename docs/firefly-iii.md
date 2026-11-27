# Firefly III

Personal finance manager plus its Data Importer, stack `firefly-iii` on docker-prod
(`docker-compose/firefly-iii`). Set up by `ops/requests/2026-11-27-firefly-iii.sh`.

| What | Where |
|---|---|
| Firefly III | `https://firefly.$DOMAIN` (container `firefly-iii`) |
| Data Importer | `https://firefly-importer.$DOMAIN` (container `firefly-iii-importer`) |
| Database | MariaDB 11.8 `firefly-iii-db`, data in `/docker/firefly-iii/db` |
| Attachments | `/docker/firefly-iii/upload` (33:33) |
| Daily cron | `firefly-iii-cron`, 03:00 UTC, calls `/api/v1/cron/<STATIC_CRON_TOKEN>` |
| Secrets | Komodo stack env (`example.env` lists them). Never in git. |
| Backups | vzdump/PBS (`/docker`), nightly MariaDB dump (`scripts/db-dumps.sh`), Komodo pre-deploy |

Reachable on LAN/tailnet directly (Technitium split DNS → Traefik) and from outside only through
Cloudflare Access (tunnel wildcard). Phone apps therefore work on the tailnet, not over the internet.

## First start (owner)

1. **Register immediately** at `https://firefly.$DOMAIN`: the first account becomes the admin, and
   registration stays open until you turn it off. Then *Administration → Configuration →
   "Single user mode"* on, so nobody else can register.
2. *Profile → 2FA*: turn it on.
3. *Profile → OAuth → Create new client*: name `Data Importer`, redirect URL
   `https://firefly-importer.$DOMAIN/callback`, **uncheck "Confidential"**. Note the client ID.
4. Open `https://firefly-importer.$DOMAIN`, enter the client ID, authorise. The importer keeps no
   token: it asks Firefly III every session (that's what keeps it safe without a login of its own).
5. Create your asset accounts in Firefly III (current account, each credit card) before importing,
   so imports map onto them instead of creating new ones.

## Getting bank data in (UK, as of 2026-11)

The importer pulls from aggregators, not from banks directly. What's usable for UK banks now:

| Route | Cost | UK? | Notes |
|---|---|---|---|
| **CSV / OFX export from online banking** | free | yes, every bank | Manual: download, upload to the importer, save the config JSON and reuse it. Works today for all five banks. |
| **Lunch Flow** (`LUNCH_FLOW_API_KEY`) | £4.99/mo for 4 connections, +£1 each (or £29.99/yr for 2) | yes: its UK/EU route is GoCardless | Easiest automated option for UK. 7-day trial. Check each bank on its coverage page before paying. |
| **Enable Banking** (`ENABLE_BANKING_*`) | free "restricted mode" for your own accounts | **unclear, probably no** | Its docs list 30 EEA countries, no GB; users report UK isn't in the free tier. Check the country list in its control panel: it costs nothing to look. |
| GoCardless Bank Account Data | — | — | Closed to new sign-ups (July 2025); the importer docs keep it for existing users only. |
| SimpleFIN | paid | no | North American banks. |

Aggregator consents expire (often after 90 days, up to 180 for some banks). Expect to re-authorise
each bank in the aggregator now and then; the importer then returns no new transactions.

### Lloyds first (trial)

- **Free, now:** Lloyds online banking → statement → *Export* → CSV. Importer → *Import file* → upload →
  map the columns (date, description, amount: Lloyds uses separate debit and credit columns) → at the
  end, *download the configuration file*. The next import reuses it in a couple of clicks.
- **Automated:** sign up for Lunch Flow (or Enable Banking if the control panel shows GB banks), connect
  Lloyds, and put the key in the Komodo stack env (`LUNCH_FLOW_API_KEY`, or `ENABLE_BANKING_APP_ID` +
  `ENABLE_BANKING_PRIVATE_KEY`). Redeploy the stack. In the importer, pick the provider and map the
  Lloyds account to your Firefly III asset account.
  - Enable Banking needs the app's redirect URL `https://firefly-importer.$DOMAIN/eb-callback` (HTTPS,
    need not be public), and the accounts linked in its portal **before** importing. The key goes in
    as one line in double quotes, with `\n` after `BEGIN PRIVATE KEY-----` and before `-----END`.

### Later: AMEX, Chase, Santander, Virgin Money

Same flow per bank, one connection each in the aggregator. Things to check first:
- **Chase UK**: check the aggregator's coverage list first. If Chase isn't there, use its statement
  export.
- **AMEX UK**: import into an asset account with the role *Credit card*. The same goes for any other
  card.
- Transfers between your own accounts (current account → card payment) come in twice, once per side.
  Use the importer's mapping step, or a Firefly rule, so they become one transfer.

## Phase 2: scheduled imports

Not set up yet, on purpose: it needs a long-lived Firefly III token in the importer. To add it:
1. Turn on forward auth on the importer router (commented label in the compose file) and create the
   Authentik proxy provider (AGENTS.md → *Enabling Authentik forward auth*).
2. Add `FIREFLY_III_ACCESS_TOKEN` (*Profile → OAuth → Personal access tokens*), `AUTO_IMPORT_SECRET`
   (≥16 chars), `CAN_POST_AUTOIMPORT=true`, `IMPORT_DIR_ALLOWLIST=/import`, and mount
   `/docker/firefly-iii/import:/import` with the saved config JSONs.
3. A cron line in `firefly-iii-cron` that POSTs to `http://firefly-iii-importer:8080/autoimport?directory=/import&secret=…`
   ([docs](https://docs.firefly-iii.org/how-to/data-importer/import/automated/)). Keep it to once a day:
   many banks allow only 4 background fetches a day.

## Upgrades

Renovate PRs, label `review` (docs/image-versions.md). Firefly III migrates at startup and some
upgrades are destructive, so the pre-deploy backup (DB dump + uploads) runs first. Restore: see
`scripts/pre-deploy-backup.sh`. `APP_KEY` must never change after the first start.
