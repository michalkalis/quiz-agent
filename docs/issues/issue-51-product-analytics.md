# Issue 51: Product analytics for PRD success metrics

**Triage:** enhancement · ready-for-agent
**Status:** Tool chosen 2026-06-09 — **reuse Sentry** (founder: "anything free; sentry or firebase"). Sentry is already integrated, EU-aligned, free tier, and satisfies this issue's own "don't ship two analytics SDKs" guard; Firebase Analytics is the fallback if Sentry's funnel surface proves too thin post-launch. From launch decision #11 (`docs/product/launch-decisions-2026-06-08.md`). **2026-06-10: decomposed into tasks 51.1–51.5** (Ralph 51.1/51.3/51.4 via `scripts/ralph/launch-issue51.sh`; founder gate 51.2; laptop session 51.5).
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

## Tasks (atomic, Ralph-ordered) — added 2026-06-10

> 51.1 / 51.3 / 51.4 are Ralph tasks (`scripts/ralph/launch-issue51.sh`; 51.4 builds iOS unit tests
> on mba under Xcode 26.3 — same pre-flight as `launch-issue46.sh`). 51.2 is founder; 51.5 needs the
> live Sentry dashboard + simulator (laptop session).
> **Gate:** 51.3 and 51.4 must not start before 51.2 is `[x]` — if Ralph reaches them while 51.2 is
> open, exit `status: no-tasks` and leave a note.

- [x] **51.1 Event taxonomy doc.** Write `docs/product/analytics-events.md`: one table — event name · exact trigger (iOS state-machine transition or backend call site, `file:function`) · properties · PRD metric it feeds · emitter (iOS / backend) · Sentry mechanism (custom event / span / measurement — verify what the current SDK versions support before committing to one). Cover exactly the events in "What to implement" above — no extras (scope guard). No-PII rule per property: no transcript text, no audio refs; question id + category + correctness are fine.
      **Acceptance**: each of the 3 PRD metrics (completion rate, voice reliability, wrong-answer rate) traces to ≥ 1 event AND every event traces to a metric (or to the #49 cost model); every trigger names a real, grep-verified call site.
      **Done 2026-06-11**: `docs/product/analytics-events.md` written. 9 events covering 3 PRD metrics. All trigger line numbers grep-verified. Sentry mechanism: `capture_event`/`SentrySDK.capture(event:)` (custom events, both SDK versions confirmed). 51.2 (founder gate) must be `[x]` before 51.3/51.4 start.

- [HUMAN] **51.2 Founder skim of the taxonomy** (~5 min). Confirm the event list + properties; check nothing conflicts with the privacy labels planned in #50. Edit inline, flip to `[x]`.

- [ ] **51.3 Backend instrumentation.** *(Gated on 51.2.)* Emit the backend-truth events from the taxonomy (answer correctness with category + question type; transcription failures) via the existing `sentry_sdk` init (`apps/quiz-agent/app/main.py:50`). Mock Sentry in tests.
      **Acceptance**: `pytest tests/ -v` green; each emit covered by a unit test asserting event name + properties; zero events not in the taxonomy doc.

- [ ] **51.4 iOS instrumentation — code + unit tests.** *(Gated on 51.2.)* Small `AnalyticsClient` seam (protocol + Sentry-backed impl, mock in tests); hook the existing `QuizViewModel` phase transitions per the taxonomy — no parallel state source (scope guard). Sentry SDK is already initialised in `HangsApp.swift`.
      **Acceptance**: unit tests with the mocked client assert each iOS taxonomy event fires on its transition; iOS unit-test suite green on mba (Xcode 26.3).

- [SESSION] **51.5 End-to-end verify + dashboard.** Laptop: drive the app in the simulator, confirm events arrive in Sentry (org `missinghue` / project `carquiz`); build the dashboard/queries for completion rate, first-try voice capture rate, wrong-answer rate. Record the dashboard URL here.
      **Acceptance**: all three metrics visible on a live dashboard fed by real simulator events.

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
