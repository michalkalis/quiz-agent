# Issue 136: Audio session activates at app launch — Spotify pauses before any quiz starts

**Triage:** bug · ready-for-agent
**Reversibility:** a
**Status:** Founder field report 2026-08-04. Confirmed in code same day.
**Created:** 2026-08-04

Founder: opening the app immediately pauses external audio (e.g. Spotify). The mic/audio session should only take over when a quiz actually starts, not on app launch.

## Root cause (confirmed)

- `HangsApp.swift:12` constructs `AppState()` → `AppState.init` (`AppState.swift:31`) creates `AudioService` (`AppState.swift:84`) and calls **`setupAudioSession(mode: .default)` unconditionally at `AppState.swift:125`**.
- `AudioService.swift:209` → `setCategory(.playAndRecord, mode: .spokenAudio, …)` at `:233` and **`setActive(true)` at `:239`** — the activation that interrupts other audio.
- `QuizViewModel.startNewQuiz` **already** calls `setupAudioSession` at quiz start (`QuizViewModel.swift:885`), so the launch-time call is redundant for the quiz path.

## Fix

Remove/defer the eager `setupAudioSession` call at `AppState.swift:125` so `setActive(true)` first fires from the `startNewQuiz` path.

Constraints:
- **Do not undo #105's launch-time speech-authorization request** — permission *prompting* at launch stays; only session *activation* moves.
- `AppState.swift:~99-104` also kicks `SilenceDetectionService.requestAuthorizationAndPrepareAssets()` at init — verify it does not itself `setActive` the session; asset prep may stay.
- Home command listener: #124 — app raises volume on Home — attributes the Home-time Voice-Processing I/O arming to the same eager activation. Fixing this issue likely fixes/changes #124's primary candidate — re-check #124 after landing.

## Product decision (founder, pending in-chat)

Home-screen voice commands ("start" hands-free) need a live mic. Two scopes:
- **(A)** No audio session until quiz start — music never touched on launch; Home voice commands stop working until the first quiz starts.
- **(B)** Home uses a non-interrupting, mixable listening configuration (no duck/interrupt options) and the full quiz session only activates at quiz start. Preserves hands-free start; needs a spike to confirm mixable capture doesn't still duck A2DP audio.

Founder's literal ask matches (A). Decision recorded here once answered.

## Acceptance

- [ ] Cold-launch the app while audio plays in another app (sim: verify via `AVAudioSession` state + no `setActive(true)` call before quiz start; unit-pin the call order) — external audio is not interrupted on launch.
- [ ] Starting a quiz still configures the session exactly as today (`startNewQuiz` path unchanged; targeted quiz-audio suites green).
- [ ] #105's speech-authorization launch request still fires (existing test/grep pin).
- [ ] Per the founder's (A)/(B) decision: chosen Home-listening behavior covered by a unit test.
- [ ] Full targeted audio/voice suites green; note in #124 what changed.
