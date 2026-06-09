# Issue 51: Product analytics for PRD success metrics

**Triage:** enhancement · ready-for-agent
**Status:** Tool chosen 2026-06-09 — **reuse Sentry** (founder: "anything free; sentry or firebase"). Sentry is already integrated, EU-aligned, free tier, and satisfies this issue's own "don't ship two analytics SDKs" guard; Firebase Analytics is the fallback if Sentry's funnel surface proves too thin post-launch. From launch decision #11 (`docs/product/launch-decisions-2026-06-08.md`).
**Created:** 2026-06-09
**Related:** `docs/product/launch-decisions-2026-06-08.md` (#11), `reference_sentry` memory, PRDs in `docs/product/INDEX.md`

## TL;DR

We need **product analytics** to measure the PRD success metrics — the app currently has crash
monitoring (Sentry) but no product-event instrumentation. This issue defines **which events to
track**, picks an **analytics tool**, and instruments the core voice-quiz funnel on iOS + backend.

## Why this matters here

The PRDs define success in terms we can't currently observe: **quiz completion rate**, **voice
reliability** (how often an answer is captured/understood on first try), and **wrong-answer rate**.
Without instrumentation we launch blind — we can't tell whether the voice-first model actually works
for users or where they drop off. Analytics is a stated launch need (#11).

## Tool decision (resolved 2026-06-09)

**Reuse Sentry.** Founder constraint was "anything free; sentry or firebase." Of those:
- **Sentry** — already integrated (org `missinghue` / project `carquiz`), EU-aligned, free tier, no
  second SDK. Funnel/event surface is thinner than a dedicated product-analytics tool, but adequate
  at MVP scale (founder + close circle). **← chosen.**
- **Firebase Analytics** — best-in-class free mobile funnels, but US data residency (GDPR friction
  for SK/CZ/EN) and a second SDK. Kept as the fallback if Sentry funnels prove too thin post-launch.
- PostHog (the earlier EU-hosted candidate) was dropped — founder narrowed to Sentry/Firebase.

Instrument via Sentry custom events/measurements on the existing state-machine transitions.

## What to implement (once tool is chosen)

### Define the event taxonomy (the core deliverable)
Map the PRD metrics to concrete events with properties:
- `quiz_started` / `quiz_completed` / `quiz_abandoned` → **completion rate**.
- `question_presented` / `answer_captured` / `answer_retry` / `transcription_failed` →
  **voice reliability** (first-try capture rate).
- `answer_correct` / `answer_incorrect` → **wrong-answer rate** (by category, by question type).
- Daily-active + questions-per-session (feeds the #49 cost model and the 20/day limit tuning).

### Instrument
- iOS: emit events at the state-machine transitions (reuse the existing phase model — don't add a
  parallel state source).
- Backend: server-side events where the truth lives (answer evaluation result, retrieval).
- Respect privacy: no PII; align with the App Store privacy labels declared in #50.

## Scope guards

- **Don't instrument everything** — only the events that map to a named PRD metric or to #49/#50.
- No new state machine; hook the existing transitions.
- Privacy labels (#50) and analytics events must agree — don't collect what you didn't declare.
- Decide the tool first (this issue is blocked on that); don't ship two analytics SDKs.

## Success criteria

- Tool + region chosen and recorded.
- Event taxonomy documented, each event traceable to a PRD success metric.
- Core funnel (start → question → answer → complete) emits events on iOS + backend, verified end-to-end.
- A dashboard shows completion rate, first-try voice capture rate, and wrong-answer rate.

## Memory references

- `feedback_api_first_tools` — prefer an analytics tool with a REST API for agent automation
- `feedback_company_accounts` — register the analytics account under the company
- `feedback_secrets_management` — analytics keys in `.env`, gitignored
- `reference_sentry` — existing observability; consider reuse before adding a second SDK
- `feedback_plain_language_explanations` — present the tool tradeoff to the founder in plain language
