# Issue 124: App raises system volume automatically on Home

**Triage:** bug · needs-triage
**Status:** Filed 2026-07-28 from the founder's TestFlight field test. Mechanism is LIKELY (not proven): the Home screen arms Voice Processing I/O on the mic and (re)activates a `.playAndRecord` session with no user audio action, both code-confirmed; which one the founder heard needs a device A/B. Needs `/prepare-issue` before an agent run.
**Created:** 2026-07-28

> **2026-08-04 — #136 landed and changes this issue's ground truth.** The launch-time eager `setupAudioSession`/`setActive(true)` in `AppState.init` (candidate (A)'s trigger) is REMOVED. Home now activates a *quiet mixable* session (`AudioService.setupQuietListeningSession`: `.playAndRecord`, `[.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker]`, no ducking) only when the command window arms, and the settle loop's repeated `setActive(true)` now re-activates under that mixable category. Candidate (B) — VPIO armed by the Home listener — still fires exactly as before. **Re-run the device A/B after #136 is on the founder's device**; if the volume jump is gone, (A) was the mechanism and this issue closes with #136.

## Symptom

Founder, TestFlight, 2026-07-28: **"Volume increases automatically on the home screen. That must not happen."**

No screenshot. The report does not say whether the founder saw the system volume HUD/slider move or only heard louder output, and does not state whether Bluetooth (car / AirPods) was connected — both matter for triage (see Founder decisions).

## Root cause

**LIKELY, narrowed to one primary candidate.** Two automatic audio-session actions fire on Home with default settings and zero user audio interaction. Both are code-confirmed; the link from either to a *perceived volume increase* is not.

**(B) — primary: Voice Processing I/O is enabled on the idle Home screen.**
`HomeView.onAppear` calls `viewModel.refreshCommandWindow()` whenever `voiceStartOnHomeEnabled` is true (`Views/HomeView.swift:61-69`), which is `Config.voiceHomeStartEnabled = true` (`Utilities/Config.swift:166`) surfaced as `VoiceCommandCoordinator.voiceStartOnHomeEnabled` (`ViewModels/VoiceCommandCoordinator.swift:60`), gated only by `settings.voiceCommandsEnabled` (declared `Models/QuizSettings.swift:74`, default `true` at `:95` / `:135` / `:174`). `currentCommandScreen` maps `quizState == .idle` to `.home` (`ViewModels/VoiceCommandCoordinator+Listening.swift:26-50`), so the listener arms, and `startListening()` calls `configureVoiceProcessing(on: inputNode)` → `inputNode.setVoiceProcessingEnabled(true)` (`Services/SilenceDetectionService+Engine.swift:88-89`, `Services/SilenceDetectionService+InputTap.swift:34-36`). Enabling VPIO moves the app's I/O into the system's voice-processing path, a long-documented iOS behavior for an unrequested output-volume jump. The existing comment at `+InputTap.swift:31-33` already reasons about VPIO being orthogonal to the session category/mode — but only for the #104 HFP concern, never for volume. The `duckingLevel: .min` config at `+InputTap.swift:41-45` only limits ducking of *other* audio; it does not bound the app's own output level.

**(A) — secondary, and weaker than it looks.**
`AppState.init()` calls `try? audioService.setupAudioSession(mode: AudioMode.default)` unconditionally on every cold launch (`Utilities/AppState.swift:115`), which sets `.playAndRecord` / `.spokenAudio` and calls `setActive(true)` (`Services/AudioService.swift:204-234`). *Refuting part of the obvious story:* Media Mode's options are `[.defaultToSpeaker, .allowBluetoothA2DP]` plus `.duckOthers` and `.interruptSpokenAudioAndMixWithOthers` (`AudioService.swift:180-198`) — activation therefore *lowers or pauses* other audio, and `.defaultToSpeaker` is a route change that has no audible effect while the app itself is playing nothing on an idle Home. What (A) can still explain is the **volume domain** the hardware buttons and the HUD address flipping to the app's playback domain on activation, so the slider reads at a different (often higher) level than the ringer volume it showed a moment earlier.

**Not noted before: the settle loop re-activates the session repeatedly.** On a cold launch the command mic can come up at 0 Hz, and the recovery loop calls `AVAudioSession.setActive(true)` up to 12 times at 250 ms intervals (`Services/SilenceDetectionService+Engine.swift:107-118`) — i.e. repeated session re-activation on Home, in exactly the launch window this report describes. Any activation-driven volume behavior is amplified there.

**Ruled out.** No software volume write exists: `outputVolume`, `MPVolumeView`, and `.volume =` have no hits anywhere in `apps/ios-app/Hangs/Hangs`. Nothing sets `.voiceChat` mode. Home launches in Media Mode (`Models/AudioMode.swift:33-34`), so the [#104 — car audio: HFP call-volume domain](issue-104-car-audio-session-call-mode.md) HFP theory does not apply to a default Home screen.

**Evidence that would settle it.** A device A/B: (1) Settings → voice commands OFF, cold launch, sit on Home — kills the command window and its VPIO enable while leaving `AppState.init`'s session setup intact; (2) voice commands ON but Home arming skipped. Whichever leg still shows the jump names the mechanism. Cross-check against the "voice command listener started" log and its `voiceProcessing` attribute in Sentry around the founder's session.

## Scope of a fix

**Track A — diagnose (must run first).**
- Run the two-leg device A/B above and record which leg reproduces; note Bluetooth state and whether the HUD moves vs. only loudness changes.
- Pull the matching Sentry `voice` events (listener start, `settleAttempts`) for the founder's TestFlight session.

**Track B — if VPIO is the mechanism.**
- Decide the arming policy for the idle Home screen: keep VPIO armed for the whole idle window, or defer it until an utterance is actually detected.
- Whatever the policy, the app must not leave the system output level changed after the listener tears down.

**Track C — if session activation is the mechanism.**
- Decide whether Home needs an active `.playAndRecord` session at all before the first quiz or recording, or whether launch-time setup defers to first use.
- Bound the `setActive(true)` settle loop so a cold launch does not re-activate the session a dozen times on Home.

**Out of scope at triage.** No implementation plan, no audio refactor — `AudioService` restructuring belongs to [#116 — split AudioService into focused audio units](issue-116-audioservice-split.md).

## Founder decisions needed

1. **What exactly did you observe?** (a) the on-screen volume HUD/slider jumped, or (b) audio genuinely got louder, or (c) both. Tradeoff: (a) points at the volume-domain switch (Track C), (b) at VPIO (Track B); guessing wrong costs a wasted implementation round.
2. **Was Bluetooth connected (car / AirPods) at the time?** `.defaultToSpeaker` and VPIO behave differently over Bluetooth than on the built-in speaker, and #104's known HFP flapping can compound whichever is primary.
3. **Is "always listening for start on Home" worth its audio-session cost?** Options: keep default ON (current, hands-free from the lock screen up), make it opt-in, or arm it only after an explicit tap. Tradeoff: opt-in removes the mechanism entirely but breaks the fully hands-free launch the product is built around.

## Related

- [#104 — car audio: HFP "phone call" flapping + mic capture dead](issue-104-car-audio-session-call-mode.md) — owns the Media/Call mode routing contract this issue must not break. Its call-volume-domain behavior is **not** the cause here (Home defaults to Media Mode).
- [#116 — split AudioService into focused audio units](issue-116-audioservice-split.md) — the natural landing spot for any session-lifecycle refactor this motivates; gated on #104 car legs.
- [#119 — voice-command recognition quality](issue-119-voice-command-recognition-quality.md) and [#120 — transcriber abstraction + Slovak commands](issue-120-transcriber-abstraction-slovak-commands.md) — own the listener engine lifecycle this touches; neither mentions volume.
- [#105 — voice commands dead](issue-105-voice-commands-dead.md) — source of the cold-launch 0 Hz settle loop referenced above.

## TODO detail (migrované z TODO.md 2026-08-26)

> - [ ] #124 App raises volume automatically on Home — [plan](../issues/issue-124-home-auto-volume-raise.md) — TF 2026-07-28, LIKELY not CONFIRMED. Two candidates both fire on Home with no user action: Voice-Processing I/O armed by the command listener (primary) vs. the volume **domain** flipping to the app on `setActive(true)` (secondary). Verifier refuted the "`.defaultToSpeaker` = louder" reading. Needs a device A/B; founder input: HUD jump vs. actually louder, and was Bluetooth connected.

