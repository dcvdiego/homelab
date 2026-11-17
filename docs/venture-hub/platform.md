# Platform requirements and research handoff

Captured 2026-10-04. Requirements come from the user's conversation. Product capability references below were researched during the session; recheck relevant versions before implementation. Nothing here is a deployed architecture.

## Requirements

- Proxmox LXC is the always-on control plane; existing agents LXC documented in [agents.md](../agents.md).
- Terminal-first, Herdr multiplexer and phone access for supervision/intervention/approval. Optional ready-made web UI; avoid maintaining a bespoke frontend unnecessarily.
- Use native official subscription CLI agents wherever offered. No reverse-engineered subscription proxies; no paid metered model API usage or automatic paid fallback.
- Current subscriptions: OpenCode Go, ChatGPT Plus, Claude Pro, Google AI Plus personal. z.ai is expiring and excluded from planning.
- Quota exhaustion leaves jobs waiting. Switching provider, using a different subscription-backed agent or requesting local GPU work requires asking the user under the current preference.
- Make productive use of included capacity and seek high weekly utilisation. Also retain venture outcomes and attention/cost measurements; quota usage alone does not establish business progress.
- RTX 5090 is on the user's PC, which can dual-boot Ubuntu Server. Ubuntu choice is motivated by low idle wattage. GPU can be unavailable while PC is used elsewhere. Queue GPU work until available; measure wall power rather than assuming an OS guarantees minimum power.
- Human approval required for proposed consequential external actions until the user grants more autonomy. Sandbox development/research can proceed within authorised scope.
- Active open-source, self-host-friendly components; new models/providers should require adapters rather than platform rewrites. Deterministic pipelines may use no model at all.

## Candidate components

**Dagu + existing Herdr/Collie** is the current provisional minimal trial. [Harness steps](https://docs.dagu.sh/step-types/harness/) support external CLIs and custom commands; [queues](https://docs.dagu.sh/server-admin/queues) and [distributed workers](https://docs.dagu.sh/server-admin/distributed/workers/) can express unavailable workers. [Human tasks](https://docs.dagu.sh/writing-workflows/human-tasks) persist waiting state but have placement/interaction constraints: design and test an explicit gate before a consequential executable step. Do not assume terminal-only approval wiring is already complete. Disable automatic provider fallback. [Edition limits](https://docs.dagu.sh/overview/self-host-license) and implementation details should be checked before adoption.

**Windmill** remains an alternative: mature workflow primitives and [approval steps](https://www.windmill.dev/docs/flows/flow_approval), but [self-hosting](https://www.windmill.dev/docs/advanced/self_host) adds PostgreSQL/server/workers and some advanced features are paid. User accepts maintenance where it buys useful capabilities.

Headless bounded jobs with logs/artifacts plus interactive Herdr sessions for planning or intervention are the initial preference. Making every background job an indefinitely live interactive session adds lifecycle/PTY/state maintenance; token cost depends on model work performed rather than the existence of a pane.

Keep custom glue narrowly focused on quota admission, durable job/provider/session IDs, structured outputs and approval-to-artifact binding. Replacing execution tools or models must not discard venture evidence.

Other researched tools: [Herdr orchestrator](https://github.com/sean1588/herdr-orchestrator) is a small issue-to-PR workflow, not established general venture management. [Agent Orchestrator](https://github.com/Untrivial-ai/agent-orchestrator), [CommandCenter](https://github.com/cgeene/commandcenter), [Hermes](https://github.com/NousResearch/hermes-agent), and [OpenClaw ACP](https://docs.openclaw.ai/tools/acp-agents) may provide useful session/agent patterns, but do not automatically solve subscription quotas and business workflow. coder/agentapi was archived and should not be the default new dependency.

## Subscription execution findings

- Codex supports native subscription login and non-interactive jobs. Official account-rate-limit capabilities in app-server are worth using where available; check installed CLI/docs before implementation.
- Claude Code supports Pro subscription login and headless execution. ANTHROPIC_API_KEY can select paid API billing; isolate task environments to respect the user's exclusion. Permission prompts need deliberate handling in unattended runs.
- Google AI Plus is not a paid Gemini CLI entitlement according to researched CLI quota documentation. Official Antigravity CLI is another route; the researched plans gave Plus baseline rather than Pro/Ultra quota. Verify current eligibility and limits. Disable credit fallback. [Antigravity headless](https://www.antigravity.google/docs/cli/headless/), [plans](https://www.antigravity.google/docs/plans/), [credits](https://www.antigravity.google/docs/cli/credits/).
- [OpenCode Go](https://dev.opencode.ai/docs/go/) is an included subscription allowance with its own credential; distinguish it from metered APIs and disable optional paid balance fallback.
- Existing CodexBar usage tracking is advisory. Do not assume every provider offers an official stable quota endpoint or that estimates are authoritative.

## Minimal acceptance checks

One pipeline must produce a dated, sourced artifact through an official CLI; preserve logs and session ID; validate output; survive restart without silently repeating consequential work; wait for approval before an external step; wait for unavailable GPU or exhausted quota without charging a paid fallback; expose status and next action through the existing terminal workflow. No deployment approval or live infrastructure mutation was requested in this documentation turn.
