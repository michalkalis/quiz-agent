# Issue #67 — Bug: audio interruption misses the streaming path; barge-in is structurally dead

**Triage:** bug · Part A done / Part B deferred

**Status (2026-07-06):** Part A shipped via #77 task 77.2 (ce349bd, teardown refactored into `AudioService.interruptionTeardown`). Part B barge-in deferred by founder decision 2026-07-02 (out of #77 scope).
- [HUMAN] on-device phone-call-interruption recovery check not yet verified (sim-only tests so far).

**Created:** 2026-06-21 · **Founder:** Michal · **Source:** #64 full-project review (ranks 4, 5 — verified first-hand)

**Severity:** high — both affect the primary driving scenario (AirPods + phone-call interruptions).

## Problem

**Part A — interruption handler misses streaming STT.** When a phone call / Siri interrupts an
active ElevenLabs streaming session, the handler calls the *batch* `stopRecording()`, which bails
because `audioRecorder` is nil during streaming. The `AVAudioEngine` keeps running (and keeps
transmitting PCM to ElevenLabs), and `QuizViewModel` is never notified — the UI is stranded in the
listening/recording state when the call ends.

**Part B — barge-in never works.** The barge-in gate requires `isTTSPlaybackActive == true`, but
that flag is **never set to true** anywhere in production, and the silence detector is torn down
before TTS plays. So "interrupt the question while it's being read" is architecturally impossible
in the current design.

## Evidence (verified first-hand 2026-06-21)

- `apps/ios-app/Hangs/Hangs/Services/AudioService.swift:385-388` — `.began` case calls `try? await self.stopRecording()`.
- `AudioService.swift:555-556` — `stopRecording()` guards on `guard let recorder = audioRecorder`; during streaming only `audioEngine` is set (`:691`). `stopStreamingRecording()` (`:704`) is the correct method and is **never** called from the interruption handler.
- `apps/ios-app/Hangs/Hangs/Services/SilenceDetectionService.swift:242-243` — `setTTSPlaybackActive(active)` setter; `:252` — barge-in gate `if isTTSPlaybackActive && isExternalAudioRoute()`.
- Only production caller of `setTTSPlaybackActive` is `ViewModels/QuizViewModel+Audio.swift:50`, passing **`false`** (the `true` call is missing). `isTTSPlaybackActive` defaults `false` (`SilenceDetectionService.swift:63`).

## Recommendation

**Part A (automatable now):** in `handleInterruption().began`, also stop the streaming engine and
reset VM state:

```swift
if self.audioEngine != nil { self.stopStreamingRecording() }
// then notify QuizViewModel to reset isStreamingSTT and leave .recording
```

**Part B (needs a decision):** real barge-in requires keeping the detector running during TTS,
which currently conflicts with the `AVAudioEngine` + `AVPlayer` audio-session design. Either
(a) revisit the session design (mixed mode) and wire `setTTSPlaybackActive(true)` before
`playOpusAudio` / `false` after, or (b) defer barge-in post-launch and **remove the dead barge-in
infrastructure** with a TODO so it isn't mistaken for working. Recommend deciding explicitly.

## Acceptance

- [ ] A simulated `AVAudioSession` interruption during an active streaming session calls `stopStreamingRecording()`; afterward `audioEngine == nil` and `isRecording == false`
- [ ] `QuizViewModel` transitions out of `.recording` on interruption (state-machine assertion)
- [ ] Either `setTTSPlaybackActive(true)` is wired before TTS **or** the barge-in infrastructure is explicitly removed with a documented TODO
- [ ] Existing RS regression scenarios pass
- [ ] `[HUMAN]` real-device confirm: phone-call interruption mid-question recovers cleanly (AirPods)
