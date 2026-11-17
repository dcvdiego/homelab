# Venture hub

Captured 2026-10-04. This is the durable handoff for the user's venture platform and the experiments developed during research. Documentation only: no orchestration engine installed, no experiments published, no outreach conducted, no spending approved.

## Objective and operating principle

Build a reusable self-hosted hub that moves ideas through evidence gathering, competition analysis, validation, scope, implementation, distribution, measured experiments, and decisions. The user has technical/creative experience but wants agents to research business methods and explain decisions in plain language. Agents can discover new ideas as well as develop user-supplied ones.

Several ventures should progress concurrently. DeskSpacer is the worked example, not the entire purpose of the platform. Spanish adaptations of AI fruit videos and other low-cost content formats belong in the portfolio. Do not eliminate experiments solely because they are familiar, replicable, or uncertain candidates for platform ad revenue. Evaluate costs, rights to source material, actual distribution and alternative revenue routes per experiment. Cheap/free trials are preferred; broad exploration is explicitly desired.

User strengths: software engineering, music production, gaming, homelabbing, cubing, VFX and editing. Native Spanish; understands Portuguese/French, without assuming professional production proficiency. Willing to learn niche areas. No blanket excluded venture categories.

## Venture records

- [DeskSpacer](ventures/deskspacer/brief.md): existing user-owned project; extensive [market/capture research](ventures/deskspacer/research.md). Resume after a minimal platform exists.
- [FLP repair](ventures/flp-repair/brief.md): existing working personal script; investigate paid convenience versus open-source core.
- [Spanish video experiments](ventures/spanish-video-experiments/brief.md): deliberately retained as a parallel low-cost experiment class.
- Other researched leads, currently unselected: game localisation release checks, sound-library metadata/QC, technical tutorial localisation, customer-run Proxmox restore verification, asset delivery checks, cubing teaching assets, and specialised AV tender qualification. These remain hypotheses with uneven commercial evidence.

## Reusable venture lifecycle

1. **Discover:** identify a buyer/audience, problem, workaround, and possible route to revenue. User ideas and agent discoveries use the same record.
2. **Research:** retain dated primary evidence, user complaints, competitors, existing prices, substitutes, distribution channels and unresolved questions. Distinguish observations, seller claims and agent inference.
3. **Validate:** state the riskiest assumption and cheapest useful test. Choose a business method suited to the assumption; explain why it applies and its limits. Research volume is not customer validation.
4. **Scope:** define a concrete deliverable, exclusions, time/cash/attention budget, success/failure measures and a review point before building.
5. **Build:** prepare a prototype, content batch, utility or offer. Prefer deterministic processing; apply AI to uncertain semantic/creative tasks. Validate outputs independently of agent exit status.
6. **Approve:** present exact artifacts and proposed external actions for human review. Approval must precede publication, customer contact, purchases and consequential external changes.
7. **Distribute and measure:** after approval, run the experiment; track exposure, retention/conversion, revenue, costs, support, time and defects as appropriate.
8. **Decide:** continue, change, pause or archive using the evidence; retain lessons and reusable assets. User approval for venture actions is not approval to change goal-tool status.

Each venture needs: status, hypothesis, sources/date, competitors, next action, unresolved dependencies, experiment design, artifacts, approval record, results and decision. Jobs need durable state; a venture status is distinct from a running agent session.

## Business-method research backlog

The user wants literature-informed methods, with recommendations explained and checked rather than arbitrary agent confidence. Candidate reading includes Rob Fitzpatrick's *The Mom Test*, David J. Bland/Alexander Osterwalder's *Testing Business Ideas*, Eric Ries's *The Lean Startup*, and Gabriel Weinberg/Justin Mares's *Traction*. These are a reading backlog, not sources already consumed or verified in this session.

Use accessible authorised material and primary author/publisher sources where possible; never claim to have read a full book from a summary. For each method record its purpose, evidence strength, assumptions, suitable venture stages, cost of applying it and alternatives. Treat frameworks as aids, not proof a business will work. Distinguish small-sample discovery from causal experiments and credible measured outcomes.

## Resume order

First establish the minimal platform: one durable pipeline, official CLI execution, approval handling, queued unavailable workers, artifacts and terminal visibility. Use a local/read-only DeskSpacer research job to exercise it. Then run a second venture through the same workflow to establish reusability. Avoid building a bespoke dashboard or a large platform before the first useful pipeline works. Full tool choice and deployment remain pending.
