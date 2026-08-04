# Issue 136: Audio session activates at app launch — Spotify pauses before any quiz starts

**Triage:** bug · fixed-pending-device-verify
**Reversibility:** a
**Status:** Founder field report 2026-08-04. Confirmed in code same day. **Fix implemented 2026-08-04 (option B)** — see Implementation below; remaining leg = founder on-device A2DP check (sim cannot exercise Bluetooth mixing).
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

## Product decision — RESOLVED (founder in-chat, 2026-08-04)

**Option (B): quiet listening on Home.** Home keeps command listening in a non-interrupting, mixable configuration (no `.duckOthers`/interrupt options — external music keeps playing); the full quiz audio session activates only at quiz start. **Fallback clause (founder-approved): if a spike shows mixable capture still audibly ducks/pauses A2DP audio, fall back to (A)** — no session at all until quiz start, Home voice commands sacrificed. Spike first, record the result here.

## Implementation (2026-08-04, option B)

- `AppState.init` no longer touches the audio session at launch — the eager `setupAudioSession(mode: .default)` at `AppState.swift:125` is removed outright (nothing replaces it at init; the #105 speech-authorization request stays).
- New `AudioService.setupQuietListeningSession()` + pure `AudioService.quietListeningCategoryOptions`: `.playAndRecord` / `.default` mode / `[.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker]` — no `.duckOthers`, no `.interruptSpokenAudioAndMixWithOthers`, no HFP. Observer registration shared with the quiz path (`registerSessionObservers()`).
- `VoiceCommandCoordinator.syncCommandListenerWindow` applies the quiet session **only when the window arms on `.home`** (injected `configureQuietListeningSession` closure). This covers cold launch AND post-quiz return to Home; in-quiz re-arms never touch the session `startNewQuiz` configured.
- `SilenceDetectionService.requestAuthorizationAndPrepareAssets` verified: asset prep + authorization only, no `setActive` — stays at init.
- Tests: `QuietListeningSessionOptionsTests` (mixable vs. ducking option pins; note `.interruptSpokenAudioAndMixWithOthers` bit-includes `.mixWithOthers`, so the contrast pins on the ducking options) + `QuietListeningWindowTests` (no session config at construction; Home arm → quiet only; in-quiz arm → none; commands OFF → none).
- Fallback clause (A) NOT triggered: mixable capture behavior over real A2DP is unverifiable on the simulator — the spike's audible check is the founder's on-device leg below.

## Acceptance

- [x] Cold-launch the app while audio plays in another app (sim: verify via `AVAudioSession` state + no `setActive(true)` call before quiz start; unit-pin the call order) — external audio is not interrupted on launch. *(Unit-pinned: no session call at construction; Home arm applies only the mixable config. Audible A2DP check = founder device leg.)*
- [x] Starting a quiz still configures the session exactly as today (`startNewQuiz` path unchanged; targeted quiz-audio suites green).
- [x] #105's speech-authorization launch request still fires (existing test/grep pin — `AppState.swift` call untouched, `SilenceDetectionServiceTests` green).
- [x] Home command listening runs in the mixable configuration (unit test pins the category/options used on Home vs. in-quiz), OR the (A) fallback is recorded in this file with the spike evidence.
- [x] Full targeted audio/voice suites green (full `HangsTests`: 922/922); note in #124 what changed. *(Note added to issue-124.)*
- [ ] `[HUMAN]` Founder device check: cold-launch + sit on Home while Spotify plays over car/AirPods A2DP — music must keep playing, unducked. If it still audibly ducks/pauses, invoke the approved fallback (A): drop the quiet session too, Home voice commands sacrificed.
