# Issue 116: Split AudioService into focused audio units

**Triage:** refactor · needs-triage
**Reversibility:** a
**Status:** Created by /prepare-issue 2026-07-20 from the iOS architecture review 2026-07-18 — Top 10 item 7. Prep pipeline running on branch `arch-review-ios`.
**Created:** 2026-07-20

**Source:** [iOS architecture review 2026-07-18](../research/ios-architecture-review-2026-07-18.md) — Top 10 item 7 + dimension 7. Link, don't restate.

## Why

One 1,246-line class conflates 5 audio responsibilities (Research → *Cluster map*): session config/routing/interruptions, input-device mgmt, batch M4A recording, streaming PCM recording, AVPlayer playback+stall. Every future audio change pays the god-class tax — to touch CarPlay session policy (#97 — CarPlay support) or any further car-audio work you must hold all 5 clusters and their shared `AVAudioSession` process singleton in your head at once. The class just absorbed #104 — car audio (HFP flapping + mic capture) and #106 TTS-stall, and will keep growing. Research verdict: the split is **call-site-neutral** (single construction site `AppState.swift:65`; every consumer depends only on `AudioServiceProtocol`), so this tax is removable at **zero behavioral cost** — pure internal decomposition.

## Scope

**In:**
- Internal decomposition into 5 owned units behind the **unchanged** `AudioServiceProtocol` facade (`:34`): **AudioSessionManager, AudioDeviceManager, BatchRecorder, StreamingPCMRecorder, AudioPlaybackService** (Research → *Cluster map*).
- `makeStreamingEngine(targetFormat:hardwareFormat:chunkInterval:onChunk:)` extraction from the 133-line `startStreamingRecording` (Research → *makeStreamingEngine*; tap closure captures only locals + injected `onChunk`, lifts cleanly).
- Facade aggregation: AudioService OR-aggregates `isRecording` (batch+streaming), forwards `recordingStartedAt`/`isPlaying`, re-publishes device state.
- Interruption wiring **session→units via explicit callbacks** (Research → *Shared-state hazards*).

**Out (hard boundaries):**
- Any behavior change, protocol-surface change (`AudioServiceProtocol :34`), call-site change, or new feature.
- The `AVAudioSession` activation **ORDERING is preserved verbatim** — real session state is the process singleton, coordinated by activation order, not an AudioService field (Research → *Shared-state hazards*). CarPlay is out (see second-order note).

## Resolved design decisions

1. **Facade stays the sole conformer; units are internal.** `AudioService` remains the only `AudioServiceProtocol` conformer and composes 5 owned units; the units are internal types, **not** injected via AppState — single construction site stays `AppState.swift:65`. *Why:* research proves zero call-site changes are possible; injecting units would leak the decomposition into every consumer for no gain.
2. **Interruption wiring = explicit callbacks.** The session unit exposes interruption-outcome callbacks; `AudioService` wires them to the batch/streaming/playback units. *Why:* replaces the session handler's implicit self-reach-ins (`:478-525`) with explicit, testable seams — the ScenePhaseTeardown + Interruption suites (the highest-risk part of the split) then pin real wiring instead of a monolith.
3. **Static #104 seams move with their units; tests updated by qualifier only.** Move each `nonisolated static` seam to its owning unit and update the test qualifier (`AudioSessionManager.categoryOptions`, `StreamingPCMRecorder.waitForValidHardwareFormat`, …) rather than leaving thin forwarders. *Why:* forwarders leave dead indirection on the facade; moving co-locates each seam with the code it guards and the suite still runs with no live session (Research → *#104/#106 seams*).
4. **Split order (safest-first, most-isolated → most-depended-on):** AudioDeviceManager → BatchRecorder → *(makeStreamingEngine prep commit)* → StreamingPCMRecorder → AudioPlaybackService → **AudioSessionManager last**. *Why (coupling, Research):* device mgmt has no cross-unit deps (extract first); batch+streaming only share `isRecording`/`recordingStartedAt`, resolved by facade aggregation; playback depends on session but the session methods (`withPlaybackCategory`, `setupAudioSession`) still live on the facade when playback is extracted; session goes last because its interruption handler references all three other units, so extracting it last lets it wire callbacks to units that already exist. `makeStreamingEngine` is its own prep commit right before StreamingPCMRecorder to de-risk the 133-line method first.
5. **One unit per commit; full pinning suites green each step.** Each unit lands as its own commit with the seam + contract + teardown suites green (`AudioServiceTests`, `AudioDevicePickerTests`, `ScenePhaseTeardownTests`, `MockAudioServiceContractTests`/`PlaybackStateTests`). *Why:* behavior-preservation proof per step, so any regression bisects to a single extraction.
6. **Precondition / sequencing gate.** Do **not** start until the #104 — car audio (HFP flapping + mic capture) founder on-device car legs pass. *Why:* the split must not sit on an unverified build — a mid-refactor audio regression would be unbisectable between "the split broke it" and "#104 never worked on device". Ordering vs **#115 — Raise deployment target to iOS 26**: `AudioService.swift` contains **no** `@available`/`#available` guards (verified 2026-07-20), so #115 does not simplify this file and is **not** a prerequisite — run in either order.

*Second-order lens (note, not a build item):* draw unit boundaries so AudioSessionManager owns **all** category/mode/activation policy in one place. #97 — CarPlay support needs a different session policy (CarPlay audio route), and a single session unit is the natural seam to vary later. Do not add CarPlay branching now — just don't spread session policy across units.

## Research (Phase 1, 2026-07-20)

All anchors `Services/AudioService.swift` unless noted. Facade = `AudioServiceProtocol` (`:34`, `@MainActor`).

### Cluster map (5 responsibilities)
1. **Session config/routing/interruptions** — `categoryOptions` `:169`, `setupAudioSession` `:198`, `deactivateSession` `:267`, `shouldSwapCategoryForTTS` `:293`, `withPlaybackCategory` `:314`, `switchAudioMode` `:387`, `handleRouteChange` `:410`, interruption seams+handler `:439-526`; observer tokens `:135-146`, `currentAudioMode` `:123`. → **AudioSessionManager**.
2. **Input-device mgmt** — device @Published props `:81-93`, `refreshAvailableDevices` `:531`, `updateCurrentInputDevice` `:553`, `setPreferredInputDevice` `:570`. → **AudioDeviceManager**.
3. **Batch M4A recording** — `prepareForRecording` `:611`, `startRecording` `:623`, `stopRecording` `:687`, `AVAudioRecorderDelegate` ext `:1195`; `audioRecorder` `:121`. → **BatchRecorder**.
4. **Streaming PCM (AVAudioEngine)** — `audioEngine` `:735`, `streamingGeneration` `:743`, `isValidHardwareFormat` `:749`, `waitForValidHardwareFormat` `:765`, `startStreamingRecording` `:794`, `stopStreamingRecording` `:932`. → **StreamingPCMRecorder**.
5. **AVPlayer playback + stall** — `PlaybackState` `:99`, `playOpusAudio` `:953`, `performPlaybackBody` `:981` (KVO + 5s stall timer `:1054`, #106), `cleanupPlayback` `:1134`, `stopPlayback` `:1157`, breadcrumb `:1179`. → **AudioPlaybackService**.

### Shared-state hazards (what makes the split hard)
- `isRecording` @Published written by **both** batch (`:676/:693`) and streaming (`:917/:939`) → facade must OR-aggregate. Same for `recordingStartedAt` (both stop-breadcrumbs).
- **Interruption handler (session, `:478-525`) reaches into all 3 other units** — `stopStreamingRecording`, `stopRecording`, `stopPlayback`, `onInterruptionBegan?()`, and reads `audioEngine != nil`/`isRecording`. Session unit needs references/callbacks to streaming+batch+playback.
- **Playback depends on session**: `performPlayback` calls session-owned `withPlaybackCategory` (`:976`); its failure-recovery calls `setupAudioSession(mode: currentAudioMode)` (`:374`).
- Real "session state" is the **`AVAudioSession.sharedInstance()` process singleton** touched by all 5 clusters — coordinated by activation ordering, not an AudioService field (this is what keeps a clean split feasible *and* order-sensitive).
- Observer tokens boxed in `OSAllocatedUnfairLock` for the nonisolated `deinit` (`:138-146`) — move with session unit.

### #104/#106 load-bearing behavior + pinning tests
Nearly all #104 behavior lives in **pure `nonisolated static` seams**, unit-tested with no live session — the split preserves them verbatim (move to the new type + update test qualifier, OR keep thin static forwarders on AudioService). Suites in `HangsTests/AudioServiceTests.swift`:
- `AudioSessionCategoryOptionsTests` (6, `:194`) — media excludes HFP, distinct sets, ducking, `shouldSwapCategoryForTTS` both ways.
- `StreamingHardwareFormatSettleWaitTests` (5, `:264`) — 0 Hz settle/timeout + `stopStreamingRecording` invalidates in-flight start (generation bump).
- `InterruptionTeardownRoutingTests` (3, `:337`) · `InterruptionResumeRoutingTests` (2, `:371`) · `MockAudioServiceInterruptionTests` (4, `:386`) · `QuizViewModelInterruptionTests` (`:465`).
- `HangsTests/AudioDevicePickerTests.swift` (2) — Media-Mode footer hint + `setPreferredInputDevice` persistence.
- `HangsTests/ScenePhaseTeardownTests.swift` (9) — #67 interruption path + background-kills-input-never-playback (pins cross-cluster teardown wiring — the highest-risk part of the split).
The #104 outcome's "33 tests / 7 suites targeted" ≈ these seam suites. Contract suites `MockAudioServiceContractTests`/`PlaybackStateTests` pin the protocol surface itself.

### makeStreamingEngine extraction (`startStreamingRecording` `:794`, 133 lines)
Internals: target-format build `:795-803` → capture generation `:807` → settle-wait probe loop + outcome `:809-834` → generation-race guard→`CancellationError` `:836-842` → real engine + re-validate `:844-854` → converter `:860` → accumulator + `installTap` conversion closure `:864-911` → `prepare()`/`start()` `:913` → state mutation (`audioEngine`/`isRecording`/breadcrumb) `:916-925`. **Extract `makeStreamingEngine(targetFormat:hardwareFormat:chunkInterval:onChunk:) -> AVAudioEngine`** covering `:844-914` — the tap closure captures only locals + injected `onChunk` (no self-state), so it lifts cleanly; caller keeps settle-wait, generation guard, state mutation.

### Facade verdict — call-site-neutral split IS possible
Single construction site `Utilities/AppState.swift:65` (`AudioService()`); every consumer depends only on `AudioServiceProtocol`, never the concrete type: QuizViewModel main (`setupAudioSession`/`onInterruptionBegan`/`availableInputDevices`/`currentOutputDeviceName`), `+Audio` (playback/device/`switchAudioMode`), `+Recording` (batch+streaming), `+ScenePhase` (`deactivateSession`/`isPlaying`/`stopRecording`), `OnboardingViewModel` (`requestMicrophonePermission`). Views read via the VM, not the service. So `AudioService` stays the protocol conformer, owns the 5 units, OR-aggregates `isRecording`/`isPlaying` + re-publishes device state, and wires interruption→units — **zero call-site changes, purely internal**. Caveat: the cross-cluster interruption/teardown wiring (pinned by ScenePhaseTeardown + Interruption suites) is the real risk, not the facade.

### Prior-art / web
- **Build-vs-adopt:** BUILD (internal decomposition of one file into 5 same-target `@MainActor` types behind the existing protocol) — no external audio framework; AVFoundation already provides the primitives.
- Web pass skipped: internal Swift refactor, no external/library research needed.

## Prep progress

> *Maintained by `/prepare-issue` — durable record of where prep is; safe to resume from a fresh session.*

| Phase | State | Latest gate verdict |
|-------|-------|---------------------|
| 1 · Research          | ✅ done | — |
| 2 · Plan              | ✅ done | — |
| 3 · Plan review       | ⬜ pending | ready-check — · design-soundness — |
| 4 · Impl-plan         | ⬜ pending | — |
| 5 · Impl-plan review  | ⬜ pending | ready-check — · design-soundness — |
| 6 · Split             | ⬜ pending | — |

**Last updated:** 2026-07-20 (Phase 2 plan) · **Next:** Phase 3 (dual gate) · **Gate attempts:** P3 0/3 · P5 0/3
