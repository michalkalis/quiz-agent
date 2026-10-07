# Issue 51: Product analytics for PRD success metrics

**Triage:** enhancement · ready-for-agent
**Reversibility:** a
**Status:** **Tool decision REVISED 2026-10-07 — own first-party solution** (events in our Postgres, emitted mainly server-side; Sentry stays for crashes/health only). Supersedes the 2026-06-09 "reuse Sentry" call: Sentry has no funnels/retention/cohorts. Taxonomy (51.1/51.2) still valid. Tasks 51.3–51.5 rewritten below.
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

## Tool decision — revised 2026-10-07 (founder, in-chat)

**Own solution: an append-only analytics events table in the quiz-agent Postgres.** Why:
- Most taxonomy events already pass through the backend (quiz start, answer evaluation + correctness, quota hit, purchases via RevenueCat webhook) → emit there, no client SDK, nothing stored on device for analytics (cleanest ePrivacy Art. 5(3) / GDPR position, no consent UI).
- The few client-only events (paywall viewed, quiz abandoned, transcription failed / retry) go to our own endpoint, not a third party.
- Identity = existing anonymous subject id; `daily_usage` already gives DAU + retention.
- Building it is cheap with agentic coding; data stays in one place; €0.
- **Viewing:** for now ask Claude to query the DB on demand. A dashboard (Metabase or similar) is wanted later, not now.
- Also turn on App Store Connect App Analytics (free: downloads, D1/7/28 retention, subscriptions; hides rows < 5 users).
- Rejected: Firebase (US vendor, consent), PostHog/Mixpanel/Amplitude (overkill, consent), Sentry (no funnels/retention). Fallback if own solution proves too costly to maintain: TelemetryDeck (EU, free tier).

## Tool decision (original, 2026-06-09 — superseded)

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

- [x] **51.2 Founder skim of the taxonomy** (~5 min). Confirm the event list + properties; check nothing conflicts with the privacy labels planned in #50. Edit inline, flip to `[x]`.
      **Done 2026-07-14**: founder-approved 2026-07-14 — 10 events incl. `quota_hit` (G2, interactive in-chat).

- [ ] **51.3 Backend events store + emits.** Append-only events table (name, subject id, session id, properties JSON, app version, timestamp) + migration; emit the backend-truth taxonomy events where they happen (answer evaluated w/ correctness + category + question type, quiz started/completed, quota hit, purchase from the RC webhook). Add purchase/paywall events to `docs/product/analytics-events.md` (taxonomy is otherwise approved). Retention: delete raw events after a fixed window; deletion on account delete.
      **Acceptance**: `pytest` green; each emit has a test asserting name + properties; no event outside the taxonomy; no transcript/answer text stored.

- [ ] **51.4 iOS client-only events.** Small `AnalyticsClient` seam posting the client-only events (paywall viewed, quiz abandoned, transcription failed, answer retry) to a backend ingest endpoint, batched, fire-and-forget; hooked on existing `QuizViewModel` transitions (no parallel state source).
      **Acceptance**: unit tests with a mocked client assert each event fires on its transition.

- [ ] **51.5 Privacy label + manifest.** Update `PrivacyInfo.xcprivacy` and the App Store privacy label: Product Interaction (analytics, not linked to identity if we keep only the anonymous id, not tracking) **plus the already-missing Sentry declarations** (crash + performance data). Pre-launch blocker.

- [SESSION] **51.6 E2E verify + saved queries.** Drive the app, confirm events land; write saved SQL for completion rate, first-try voice capture rate, wrong-answer rate, DAU/retention so Claude can answer on demand. Dashboard deferred.

## Success criteria

- Tool + region chosen and recorded.
- Event taxonomy documented, each event traceable to a PRD success metric.
- Core funnel (start → question → answer → complete) emits events on iOS + backend, verified end-to-end.
- A dashboard shows completion rate, first-try voice capture rate, and wrong-answer rate.

## Acceptance

- [ ] An event taxonomy doc exists; each event traces to a PRD success metric, and each of the three target metrics (completion rate, first-try voice capture rate, wrong-answer rate) traces to ≥1 event.
- [ ] `pytest tests/ -v` is green in `apps/quiz-agent`; every backend taxonomy event has a unit test asserting its name + required properties, and no event outside the taxonomy is emitted.
- [ ] iOS unit tests pass on mba; each iOS taxonomy event is asserted to fire on its named `QuizViewModel` state transition via the mocked analytics client.
- [ ] [HUMAN] Saved queries return completion rate, first-try voice capture rate, wrong-answer rate and DAU/retention from real (simulator) events *(task 51.6)*.
- [ ] Privacy manifest + App Store label declare analytics and Sentry data *(task 51.5)*.
- [ ] No analytics key/credential is committed (lives in gitignored `.env`).

## Memory references

- `feedback_api_first_tools` — prefer an analytics tool with a REST API for agent automation
- `feedback_company_accounts` — register the analytics account under the company
- `feedback_secrets_management` — analytics keys in `.env`, gitignored
- `reference_sentry` — existing observability; consider reuse before adding a second SDK
- `feedback_plain_language_explanations` — present the tool tradeoff to the founder in plain language

## Plan-readiness check (57.14 — 2026-06-16)

> *This was generated by AI during triage.*

**Reversibility:** a (analytics instrumentation — commits-only Swift/Python code, no schema/payment/prod-deploy).
**`/ready-check` verdict: NOT-READY for the *unattended* loop** (human/session gates), blockers recorded:
- **B3 (fixed):** the live-Sentry-dashboard acceptance criterion (task 51.5 `[SESSION]`) sat in `## Acceptance` unmarked, making the loops done-state structurally unreachable. **Resolved** by tagging it `[HUMAN]` so the 57.7 goal-check treats it as out-of-loop.
- **B2 (open):** task 51.4 (`AnalyticsClient` seam + `QuizViewModel` hook-points) names no concrete target files/symbols (C2 localization gap) — add the file paths + the iOS test scheme/`xcodebuild` invocation before an unattended run.
- **B1 (open):** no acceptance criterion names a *currently-failing* test to make green for 51.3/51.4 (C5 start-fail condition).
- Plus: 51.2 is a `[HUMAN]` founder gate that 51.3/51.4 sit behind. Net: the Ralph-suitable tracks (51.3/51.4) are human-supervised launches behind 51.2, not unattended-overnight work — kept `ready-for-agent` for supervised launch, **excluded from the unattended queue** until B1/B2 are closed.

<!-- obsidian-links:start -->
## Súvisiace issues
[[issue-49-daily-limit-cost-research|#49 Daily free-limit cost research]] · [[issue-50-app-store-connect-setup|#50 App Store Connect listing + ASC API setup]] · [[issue-57-loop-verification-backbone|#57 Autonomous loop hardening]]
<!-- obsidian-links:end -->

## TODO detail (migrované z TODO.md 2026-08-26)

> - [ ] #51 Product analytics for PRD success metrics — [plan](../issues/issue-51-product-analytics.md) (launch decision #11; **Founder decision 2026-06-09: free tool — reuse Sentry** (already integrated, EU-aligned, no second SDK; Firebase fallback)) — **decomposed 2026-06-10 into 51.1–51.5**: 51.1 event taxonomy **✓ DONE 2026-06-11** (`docs/product/analytics-events.md`, 9 events, all PRD metrics traced) → **⏳ BLOCKED on founder gate 51.2 (~5-min skim of the taxonomy — the only thing holding 51.3/51.4)** → 51.3 backend + 51.4 iOS instrumentation → 51.5 e2e verify + Sentry dashboard. NB pre 51.3/51.4: file:line anchors in analytics-events.md are stale (June snapshot) — re-grep triggers fresh, don't trust the doc's line numbers

