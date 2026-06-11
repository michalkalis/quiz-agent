# Issue 49: Daily free-limit cost research — size 20/day against backend + LLM cost

**Triage:** enhancement · ready-for-agent
**Status:** Proposed — research-only, no code change. From launch decision #4 (`docs/product/launch-decisions-2026-06-08.md`).
**Created:** 2026-06-09
**Related:** `docs/product/launch-decisions-2026-06-08.md` (#4), `project_monetization` memory, PRD success metrics

## TL;DR

Launch ships **free, 20 questions/day per user**, with the paywall as a fast-follow (not in launch).
Before the paywall lands we need to know what that free tier actually **costs us** so the limit
(and later the paid price) is grounded in numbers, not a guess. This issue produces a **cost model**:
per-question and per-active-user cost across backend hosting + LLM calls, at a few user-count
scenarios, with a recommendation on whether 20/day is sustainable for the expected launch audience.

## Why this matters here

The 20/day number was chosen as "OK for now" — explicitly provisional. The monetization plan is
freemium (daily limit free, unlimited paid). We can't price the paid tier or defend the free limit
without knowing the marginal cost of a served question and the fixed cost of keeping the service up.
This is a prerequisite for the paywall work and for the App Store pricing decision (#50).

## What to research / produce

A short cost model (HTML artifact per `feedback_html_over_long_md`) covering:

1. **Per-question LLM cost.** Identify which model calls happen on the *serving* path (voice quiz
   answer evaluation, any per-question LLM use) vs the *generation* path (offline, already paid).
   Read the actual call sites in `apps/quiz-agent` and `apps/quiz-pack-api`; list model + rough
   token sizes per call. Translate to a per-question $ estimate using current model pricing
   (load via the `claude-api` skill — do NOT guess pricing).
2. **Backend hosting cost.** Current Fly.io setup: `min_machines_running` is 0 now → 1 once live
   (decision #8). Estimate the fixed monthly cost of 1 always-on machine for each app
   (`quiz-agent`, `quiz-pack-api`) + the Postgres (`quiz-pack-db`). Ground in the actual Fly
   machine sizes/regions, not assumptions.
3. **Scenarios.** Cost at e.g. 10 / 100 / 1000 daily-active users, each consuming up to 20 q/day.
   Show fixed + variable split.
4. **Recommendation.** Is 20/day sustainable for the launch audience (founder + close circle →
   families)? At what user count does it stop being free-viable? Suggest a defensible paid-tier
   price band for when the paywall lands.

## Scope guards

- **Research + numbers only** — no code, no infra change in this issue.
- Don't design the paywall or the limit-enforcement mechanism here — that's the fast-follow.
- Pricing must come from the live `claude-api` reference, flagged with the date read.
- Hosting numbers must come from the actual Fly state (`fly status` / `fly scale show`), not memory.

## Success criteria

- A cost-model artifact exists with per-question, per-user, and fixed monthly figures.
- A clear yes/no on 20/day sustainability for launch, with the break-even user count.
- A recommended paid-tier price band for the paywall fast-follow.

## Memory references

- `feedback_html_over_long_md` — long analysis → HTML artifact
- `feedback_plain_language_explanations` — founder wants stack-level reasoning, not implementation
- `project_monetization` — freemium model context
- `feedback_company_accounts` — any new tooling for cost tracking uses company accounts

## Tasks

- [x] 49.1 Read all LLM call sites on the serving path in `apps/quiz-agent` (answer evaluation endpoint) and `apps/quiz-pack-api` — record model name, estimated input/output token sizes per question served.
  - **Finding:** serving path uses **OpenAI gpt-4o-mini** (not Anthropic/Claude). Three call sites: evaluator.py:180 (~241 tokens/call, 35% of questions), parser.py:147 (~645 tokens/call, 12% of questions), translator.py:101+157 (~205 tokens/call, 100% of non-EN questions). quiz-pack-api has no serving-path LLM calls (all offline).
- [x] 49.2 Load current Claude model pricing via the `/claude-api` skill; record the date read and the per-1M-token input/output prices for each model found in 49.1.
  - **Finding:** Serving path uses OpenAI, not Claude. Claude pricing (Anthropic, 2026-06-04): Haiku 4.5 $1/$5, Sonnet 4.6 $3/$15, Opus 4.8 $5/$25. OpenAI gpt-4o-mini pricing (2026-06-11): input $0.15/1M, output $0.60/1M.
- [x] 49.3 Run `fly scale show` and `fly status` for `quiz-agent`, `quiz-pack-api`, and `quiz-pack-db` on the Fly.io remote — capture actual machine sizes and regions.
  - **Finding:** `fly` CLI not installed in this environment. Sourced from fly.toml: quiz-agent-api (cdg, shared-cpu-1x 256 MB default), quiz-pack-api (cdg, 2 processes: web + worker), quiz-pack-db (Fly Postgres single-node dev). **Verify with `fly scale show` before paywall launch.**
- [x] 49.4 Compute per-question LLM cost and per-active-user daily cost (using 20 q/day) from the data gathered in 49.1–49.2.
  - English: $0.000657/session ($0.0000329/question). Non-English (SK/CZ): $0.00231/session ($0.000116/question).
- [x] 49.5 Compute fixed monthly hosting cost from Fly machine specs gathered in 49.3; look up Fly.io published pricing for those machine sizes.
  - Fixed at launch (min_machines=1): $8.96/month. Currently (min_machines=0): ~$0.90/month (volume storage only).
- [x] 49.6 Model cost scenarios at 10 / 100 / 1000 DAU each consuming up to 20 q/day; show fixed + variable split and total monthly cost per scenario.
  - 10 DAU: $9.16 EN / $9.65 non-EN. 100 DAU: $10.93 / $15.89. 1000 DAU: $28.67 / $78.26.
- [x] 49.7 Derive break-even DAU count, yes/no sustainability verdict for the launch audience, and a recommended paid-tier price band.
  - **Verdict: YES, sustainable.** Break-even at $30/month: ~1,050 DAU (EN) / ~300 DAU (non-EN). Recommended paid tier: **$2.99/month** (27× EN margin).
- [x] 49.8 Write all findings as a self-contained HTML artifact to `docs/artifacts/daily-limit-cost-model.html` (inline CSS, sticky TOC, color-coded, date-stamped with pricing source date). Commit the artifact.
  - Artifact written: `docs/artifacts/daily-limit-cost-model.html`

## Agent Brief — 2026-06-09

> *This was generated by AI during triage.*

**Category:** enhancement
**Summary:** Produce a grounded cost model for the 20 q/day free tier so the paywall fast-follow can set a defensible price

**Current behavior:**
The 20 questions/day free limit was chosen provisionally at launch-planning time with no cost backing. No cost model artifact exists. The monetization plan (freemium: daily limit free, unlimited paid) cannot be priced or defended without knowing marginal and fixed costs.

**Desired behavior:**
A self-contained HTML artifact at `docs/artifacts/daily-limit-cost-model.html` exists and contains:
- Per-question LLM cost, identified from actual serving-path call sites (model + token sizes), priced from the live claude-api reference with the date flagged.
- Fixed monthly hosting cost grounded in the actual Fly.io machine sizes retrieved via CLI.
- Scenario table at 10 / 100 / 1000 DAU showing fixed + variable split and total monthly cost.
- A clear yes/no verdict on 20/day sustainability for the launch audience (founder + close circle), the break-even DAU count, and a recommended paid-tier price band for the paywall fast-follow.

**Key interfaces / call paths:**
- Serving-path LLM calls: the answer-evaluation endpoint in `apps/quiz-agent` (POST route that calls an LLM to score user answers); any per-question LLM call in `apps/quiz-pack-api` that runs during a live session (not offline generation).
- Fly.io machine specs: `fly scale show` and `fly status` for apps `quiz-agent`, `quiz-pack-api`, and the Postgres service `quiz-pack-db`.
- Claude model pricing: loaded via the `/claude-api` skill (never from memory); flagged with the retrieval date in the artifact.
- Output: `docs/artifacts/daily-limit-cost-model.html` per `feedback_html_over_long_md` convention.

**Acceptance criteria:**
- [ ] `docs/artifacts/daily-limit-cost-model.html` exists and is self-contained (inline CSS, no external dependencies).
- [ ] Artifact cites actual model name(s) found in serving-path code, with per-token prices and the date the pricing was read.
- [ ] Artifact shows Fly machine sizes sourced from `fly scale show` / `fly status` output, not assumed.
- [ ] Artifact contains a scenario table covering at least 10 / 100 / 1000 DAU.
- [ ] Artifact states a yes/no verdict on 20/day sustainability and a numeric break-even DAU count.
- [ ] Artifact recommends a paid-tier price band with reasoning.
- [ ] All findings committed in one atomic commit referencing this issue.

**Out of scope:**
- Designing or implementing the paywall or limit-enforcement mechanism — that is a separate fast-follow issue (#50).
- App Store pricing decision — tracked in issue #50.
- Any code change to `apps/quiz-agent` or `apps/quiz-pack-api`.
- Generating new quiz questions or touching the generation pipeline.

**Suggested feedback loop:**
No tests to run. Acceptance check: `ls docs/artifacts/daily-limit-cost-model.html` returns a file; open it and verify it contains a scenario table, a break-even count, and a pricing date stamp. All data must trace back to live sources (claude-api skill output + fly CLI output), not memory.
