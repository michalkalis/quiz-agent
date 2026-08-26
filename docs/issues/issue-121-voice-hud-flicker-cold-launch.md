# Issue 121: Voice-command HUD flickers on cold launch (shown → hidden → shown)

**Triage:** bug · needs-triage
**Status:** Filed 2026-07-28 from the founder's TestFlight field test. Symptom and the failing state transition are CONFIRMED against code + Sentry telemetry from that morning's sessions; the *ordering* that produces the first (premature) "shown" beat is LIKELY, not proven. Needs `/prepare-issue` before an agent run.
**Created:** 2026-07-28

## Symptom

Founder, TestFlight build, 2026-07-28: after app launch the green "LISTENING FOR COMMANDS" bar appeared, disappeared for a moment, and then appeared again.

Cosmetic in isolation, but it is the app's only signal that hands-free control is live — a driver who sees it blink cannot tell whether commands currently work. Sentry shows the identical three-beat pattern in all three of that morning's sessions (traces `c54f1b96…` 09:10:56–09:11:05Z, `f659fbb7…` 09:15:41–53Z, `cb198224…` 09:20:39Z with recovery at 09:32:09Z), so this is not a one-off.

## Root cause

**CONFIRMED (the hide-then-show half).** The HUD is gated on `commandListenerHint` (`VoiceCommandCoordinator+Listening.swift:56-65`), which requires three independently-written conditions: `commandCapturePhase == .listening`, `currentCommandScreen != nil`, and `commandAvailability == .ready`. Nothing makes those transition together.

The middle beat is `commandAvailability` flipping to `.unavailable` and back:

- `SilenceDetectionService.startListening()` retries a 0 Hz cold mic 12 × 250 ms (`SilenceDetectionService+Engine.swift:107-132`); on exhaustion it calls `markCommandsUnavailable(reason: "Command listener: invalid input format (after N settle retries)")` and `cleanupAfterStartFailure()`.
- Field telemetry carries that exact reason string ~4 s after the first `voice cmd consumer started`, i.e. the 3 s budget commit `c95b6885` introduced is still being exhausted on this device.
- A later successful arm calls `recoverAvailabilityForLiveWindow()` (`SilenceDetectionService+Assets.swift:141-148`) and restores `.ready` — the recovery path `c95b6885` added. So `c95b6885` removed the permanent latch but left the transient flip visible.

**LIKELY (the first, premature "shown" beat).** For the HUD to be up *before* the failure, a `startCommandConsumer()` must have run against an engine that was never confirmed live. Two facts make that reachable:

- `startListening()`'s reentrancy guard `guard audioEngine == nil else { return }` (`SilenceDetectionService+Engine.swift:29`) is evaluated once, synchronously, before an `await SpeechAnalyzer.bestAvailableAudioFormat(...)` and the `audioEngine = engine` assignment that follows (`:78-86`). A second concurrent caller can bounce off that stale nil-check silently (no log on that branch) while the winner is still settling the cold mic. #100.4's `shouldStartEngine` identity check (`:203`) only covers the *later* window, after the engine is tracked.
- `AudioDeviceState.startSilenceDetectionListening()` (`ViewModels/AudioDeviceState.swift:160-210`) re-validates foreground + not-playing-TTS after the await, but **never checks that the inner call produced a live engine** before calling `startCommandConsumer()` — so a bounced caller still flips the capture phase to `.listening`.

Two known triggers fire near cold launch and could be the racing pair: `HomeView.onAppear` (`Views/HomeView.swift:61-69`) and the `.active` scene-phase handler (`ViewModels/QuizViewModel+ScenePhase.swift:56-58`). Neither was instrumented, so **which two calls actually raced is inferred, not observed** — and a purely sequential arm → teardown → cold re-arm ordering fits the same telemetry equally well.

**What would settle it:** a Sentry breadcrumb inside `syncCommandListenerWindow()` naming its caller, plus a log on the `guard audioEngine == nil` early-return branch, over one cold launch.

## Scope of a fix

**(A) Stop the HUD from lying (the user-visible half).**
- Gate `startCommandConsumer()` on the inner `startListening()` having produced a live engine, rather than on the post-await foreground/TTS check alone.
- Decide whether `commandAvailability`'s transient `.unavailable` should be user-visible at all during the first seconds of a launch, or damped (the HUD is a driver-facing confidence signal, not a debug readout).

**(B) Close the reentrancy gap (the mechanism).**
- Re-check `audioEngine == nil` (or hold a generation token / lock) immediately before the `audioEngine = engine` assignment, not only at the top of the function and after the 50 ms settle sleep.
- Log the early-return branch so a bounced concurrent call stops being invisible in telemetry.
- Decide whether the two known cold-launch `refreshCommandWindow()` triggers should also be deduped/debounced at the call sites, as a second layer.
- Regression coverage at flow/state-machine altitude: two `refreshCommandWindow()` calls in the same runloop tick must never leave `commandCapturePhase == .listening` while `commandAvailability != .ready`.

**Open, worth answering during prep:** why the 3 s settle budget still exhausts on this build — is 3 s occasionally too short on this device/route, or is a second engine starved by the first one already running, which would make the race a *cause* of the retry exhaustion rather than a coincidence?

## Founder decisions needed

- **Own issue or fold into [#100 — iOS driving-loop robustness](issue-100-ios-driving-loop-robustness.md) finding 4?** Same missing-reentrancy-guard root cause in adjacent code; folding avoids a second guard-audit pass over `SilenceDetectionService+Engine.swift`. Tradeoff: #100 is scoped as a crash-severity launch gate, this is a cosmetic-but-confidence-eroding flicker — folding risks either inflating this or diluting #100's priority.
- **Is a visible flicker acceptable if commands actually work throughout?** If yes, track (A) alone (damp the indicator) is a much smaller change than (B).

## Related

- [#100 — iOS driving-loop robustness](issue-100-ios-driving-loop-robustness.md) — finding 4 ("two concurrent audio engines") is the same bug class; its `shouldStartEngine` guard has already landed in code while its INDEX line still reads `ready-for-agent`, so that status looks stale and is worth reconciling independently of this issue.
- Commit `c95b6885` (`fix(ios): voice-command status latched "Unavailable" after a cold-launch mic race`) — the prior fix for the same cold-mic settle failure; this issue is the flicker that fix converted a silent latch into.
- [#119 — voice-command recognition quality](issue-119-voice-command-recognition-quality.md) and [#120 — transcriber abstraction + Slovak commands](issue-120-transcriber-abstraction-slovak-commands.md) — adjacent voice work, but recognition *accuracy* and engine choice are explicitly OUT of scope here.
- Out of scope: retuning the settle-retry budget as a standalone change (it is a symptom knob), and any change to the Settings voice-status row's wording.

## TODO detail (migrované z TODO.md 2026-08-26)

- [ ] #121 Voice-command HUD flickers on cold launch — [plan](../issues/issue-121-voice-hud-flicker-cold-launch.md) — TF 2026-07-28. Green "LISTENING FOR COMMANDS" bar shows → hides → shows within the first 5–10 s; hide→show half CONFIRMED against Sentry (exhausted cold-mic settle loop flips `commandAvailability`), the premature first beat is LIKELY a `startListening()` reentrancy race. Founder call: own issue or fold into #100 — iOS driving-loop robustness.

