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
