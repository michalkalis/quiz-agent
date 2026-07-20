# Issue 109: In-app beta feedback — voice-dictated, with screenshot + logs

**Triage:** enhancement · ready-for-agent
**Reversibility:** a (iOS UI + one additive backend route/table; no existing behavior changes except retargeting the shake gesture)
**Status:** Founder request 2026-07-18 (pre-TestFlight-beta); researched (codebase recon + prior-art web pass) and product decisions locked in-session 2026-07-18 → ready-for-agent
**Created:** 2026-07-18

## Goal

Before the TestFlight beta wave: any tester can report feedback hands-free-ish — open a feedback sheet, **dictate** their comment (same live-transcript tech as quiz answers), and the app auto-attaches a **screenshot of the screen they were on**, the **last minutes of app logs**, the **raw audio recording**, and device/app metadata, then sends everything to **our backend** as a durable inbox.

## Founder decisions — 2026-07-18 (in-session, AskUserQuestion)

1. **Inbox = own backend** (new endpoint + Postgres table). Durable, no Sentry 30/90-day retention clock, all attachment types ours. Sentry stays for crashes only.
2. **Entry points = Settings row + shake gesture anywhere** (shake captures the *current* screen's screenshot, Instabug/TestFlight convention). Our sheet **replaces** the Sentry shake widget.
3. **Voice UX = live streaming transcript (editable before send) + raw audio attached** — same ElevenLabs streaming pipeline as answers; audio kept as fallback when the transcript is wrong.

## Prior art (why this shape)

- TestFlight built-in feedback (screenshot + comment, shake) stays as a free safety net — but it has no logs, no audio, no custom data, and lands only in App Store Connect.
- Sentry `configureUserFeedback` is already enabled in `HangsApp` (shake + screenshot triggers) with a code TODO for audio input — but sentry-cocoa feedback supports only one screenshot, no first-class audio, and events expire (30 d free / 90 d paid). Rejected as the inbox.
- Shake-to-report with auto-attached screenshot + console logs + device info is the industry convention (Instabug/Luciq, Shake SDK). Voice-dictated feedback has almost no precedent — differentiator, and on-brand for a voice-first app.
- Sources + details: research agent report 2026-07-18 (Sentry feedback API/limits, OSLogStore constraints, TestFlight feedback API/webhooks) — key cites: docs.sentry.io user-feedback + size-limits + data-retention; Apple "View tester feedback"; useyourloaf OSLogStore.

## Existing building blocks (recon 2026-07-18 — all confirmed on main)

| Block | Where | Reuse |
|---|---|---|
| Streaming mic → live transcript | `AudioService` (`startStreamingRecording`) + `ElevenLabsSTTService` (actor, WS Scribe v2), orchestration pattern in `QuizViewModel+Recording.swift` | HIGH — copy the ~40-line token→connect→stream→commit pattern into `FeedbackViewModel` |
| Recent-logs export | `LogStore` (OSLogStore `.currentProcessIdentifier`, subsystem-filtered) + `LogEntry` + `DebugLogView.exportText()` | HIGH — but **`#if DEBUG`-gated today; must be promoted to release builds** |
| Multipart upload | `NetworkService.submitVoiceAnswer` multipart builder | HIGH |
| Settings navigation idiom | `SettingsView` `groupSection` + `NavigationLink`/`HangsConfigRow` | HIGH |
| Sentry feedback config to retarget | `HangsApp.init` `options.configureUserFeedback` (`useShakeGesture`, `showFormForScreenshots`) | Replace with our sheet |
| Backend multipart + rate-limit pattern | `app/api/routes/voice.py` (`/voice/transcribe`, `/voice/submit`) | HIGH — endpoint itself is greenfield |
| Admin-key auth pattern | constant-time admin-key compare (#91) | For the read/list route |

Gaps: no in-app screenshot renderer (Sentry's auto-attach is Sentry-only) · `LogStore` DEBUG-gated · no feedback endpoint/table.

## Design

### iOS (`apps/ios-app`)

- **`FeedbackView` + `FeedbackViewModel`** (new, `Views/Feedback/`): sheet with — screenshot thumbnail (tap to remove), big mic button, live transcript in an editable text editor (typing always possible; mic appends), "what gets sent" line (screenshot · logs · audio · device info), Send button.
- **Entry 1 — Settings row** "Send feedback" (visible in all builds, near About).
- **Entry 2 — shake gesture** anywhere: capture key-window screenshot **before** presenting the sheet (`UIGraphicsImageRenderer`), then present. Standard `motionEnded`/onShake modifier. Remove Sentry's `useShakeGesture` + `showFormForScreenshots` so there's exactly one feedback UI; the rest of Sentry config unchanged.
- **Voice**: reuse the **shared** `AudioService` + `ElevenLabsSTTService` instances (single-`AVAudioEngine` rule, #64/#77); entry blocked with a friendly note while quiz recording is active (rare edge). While streaming to ElevenLabs, tee the same 16 kHz PCM chunks into a WAV buffer → the audio attachment. Cap dictation at 120 s (~3.8 MB WAV, under the 10 MB audio guideline).
- **Logs**: promote `LogStore` + `LogEntry` out of `#if DEBUG` (keep `DebugLogView` itself DEBUG-only); attach `exportText()` of last 15 min, tail-capped ~200 KB.
- **Metadata JSON**: app version+build, iOS version, device model, environment, locale, quiz language, audio mode, `quizState`, active session id if any. (User identity comes from the bearer server-side.)
- Breadcrumb `feedback.sent` to Sentry for cross-correlation with crashes.
- PII note: this path bypasses `scrubEvent` (Sentry-only) by design — feedback text is the payload and goes to our own DB, so no scrubbing conflict.

### Backend (`apps/quiz-agent`)

- **`POST /api/v1/feedback`** — multipart: `message` (required, ≤5 000 chars), `metadata` (JSON string), files `screenshot` (≤5 MB), `audio` (≤10 MB), `logs` (≤1 MB text). Auth = same `require_auth_or_grace` as sessions; rate limit 5/min; 201 → `{id}`.
- **Table `feedback`** (alembic migration): id, user_id, created_at, message, metadata jsonb, app_version, logs text, screenshot bytea, audio bytea + content types. Bytea is fine at beta scale (handful of testers, ≤~15 MB/row); revisit blob storage with the Hetzner migration if volume grows.
- **Notification for the founder**: on insert, emit a Sentry message event `feedback.received` (id + first ~100 chars) → existing Sentry alerting/`/check-crashes` surfaces new feedback with zero new infra.
- **`GET /api/v1/feedback`** (+ `GET /{id}` with attachment fetch) — admin-key-gated list, so the agent can pull & report feedback on demand without DB access.
- No server-side transcription (transcript arrives from the client; audio is a fallback artifact, playable from the admin GET).

## Plan (phases, committable each)

1. **Backend**: migration + model + POST/GET routes + tests (auth, caps, rate limit, happy path). Deploy **staging** autonomously; **prod deploy carries a migration → founder heads-up first** (per standing deploy rule).
2. **iOS foundation**: promote `LogStore` to release; screenshot capture util; shake hook + Sentry widget retarget; Settings row; static `FeedbackView` (type-only) wired to `NetworkService` multipart → staging.
3. **iOS voice**: dictation via shared services + PCM tee → WAV attachment; edit-then-send; 120 s cap; blocked-while-quiz-recording guard.
4. **Verify**: iOS unit tests (`FeedbackViewModel` with mocked audio/STT/network), backend suite, sim e2e against staging (dictate → row lands with all attachments), quick visual pass. Rides the next TestFlight build.

## Acceptance

- [ ] Shake on any screen → sheet opens with a screenshot of *that* screen; Settings row opens the same sheet; Sentry's own shake/screenshot forms no longer appear.
- [ ] Dictating shows a live transcript (same feel as answers), transcript is editable, typing works without mic.
- [~] Send → one `feedback` row containing message + screenshot + WAV audio + log tail + metadata; visible via admin GET; Sentry `feedback.received` event fires. — *Agent-verified 2026-07-20 on staging: POST (grace mode) → 201; admin list + `GET /{id}` return the row with message + screenshot (43 B) + logs + metadata. Not yet exercised agent-side: WAV audio attachment + Sentry `feedback.received` event (needs the on-device/device-build path).*
- [ ] Logs attach in a TestFlight (release-config) build — i.e. `LogStore` promotion verified, not just in DEBUG.
- [x] Quiz answer flow untouched: targeted recording/STT suites green; no second audio engine ever instantiated. — *Agent-verified 2026-07-20: `AudioServiceTests` (incl. "shared AudioService refuses a second concurrent streaming start"), `ElevenLabsSTTServiceTests`, `QuizViewModelStreamingTests`, `FeedbackViewModelTests`, `FeedbackDictationTests` — 36 tests / 4 suites, all green (Hangs-Local, iPhone 17 / iOS 26.5).*
- [~] Backend suite green incl. new tests; staging deployed; prod deploy after founder heads-up (migration). — *Agent-verified 2026-07-20: backend suite 437 passed (0 failed) with a live test Postgres; staging (`quiz-agent-api-staging`) deployed from `479e472`, migration at head `0007_feedback_table`, health 200. Prod deploy still owed (carries migration → founder heads-up first).*
- [ ] `[HUMAN]` on-device: founder shakes on the quiz screen, dictates Slovak feedback, agent reads it back from the inbox (transcript + audio present).

## Cross-refs

- #96 P2 — voice observability / Settings diagnostics (same Settings idiom; no overlap)
- #105 — speech-authorization fail-loud (feedback dictation uses ElevenLabs mic path, not SpeechAnalyzer — unaffected)
- #77 / #64 — single-audio-engine rule (why shared service instances are mandatory)
- #51 — analytics-on-Sentry decision (the `feedback.received` notification rides the same rail)
- #101 — staging env used for e2e before prod
