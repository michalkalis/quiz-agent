# Issue 116: Split AudioService into focused audio units

**Triage:** refactor · ready-for-agent — start gated on #104 car-audio founder on-device legs
**Reversibility:** a
**Status:** Prep complete 2026-07-20 (branch `arch-review-ios`): all 6 phases ✅, both gates green (ready-check READY · design-soundness SOUND 0.87), split into 3 sessions ([`issue-116-execution-prompts.md`](issue-116-execution-prompts.md)) — ready-for-agent, but do not start until the #104 — car audio founder on-device car legs pass (decision 6).
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

## Tasks (atomic)

> **START PRECONDITION (blocks every task):** do **not** start until **#104 — car audio (HFP flapping + mic capture)** founder on-device car legs pass (decision 6). The split must not sit on an unverified build — a mid-refactor audio regression would be unbisectable between "the split broke it" and "#104 never worked on device". Confirm #104 sign-off before T1.
>
> One unit per commit (decision 5); order is **locked** (decision 4) — do not reorder. After **every** commit the full pinning-suite set is green and the diff stays inside `Services/` (+ the audio test files) — see **Acceptance**. The facade (`AudioService`) stays the sole `AudioServiceProtocol` conformer throughout and OR-aggregates `isRecording`/`recordingStartedAt`, forwards `isPlaying`, re-publishes device state (decision 1).

- [ ] **T1 — Extract `AudioDeviceManager`** (first; no cross-unit deps). Move device `@Published` props (`:81-93`), `refreshAvailableDevices` (`:531`), `updateCurrentInputDevice` (`:553`), `setPreferredInputDevice` (`:570`) into `Services/AudioDeviceManager.swift`. Facade owns one instance and **re-publishes** its device state so `availableInputDevices`/`currentOutputDeviceName` reach consumers unchanged. Pins: `AudioDevicePickerTests` (2).
- [ ] **T2 — Extract `BatchRecorder`** (M4A). Move `startRecording` (`:623`), `stopRecording` (`:687`), `AVAudioRecorderDelegate` ext (`:1195`), `audioRecorder` (`:121`) into `Services/BatchRecorder.swift`. **`prepareForRecording` (`:611`) stays facade orchestration** (gate note 1 — the batch→playback edge): the facade calls the playback stop, then delegates the settle/prep (200 ms + log) to `BatchRecorder.prepareForRecording()`. BatchRecorder gets **no** playback reference — at T2 `stopPlayback` still lives on the facade (`await stopPlayback()`); T5 moves it and the facade updates its one call site to `playback.stopPlayback()`. Facade OR-aggregates `isRecording`/`recordingStartedAt` across batch+streaming. Pins: `AudioServiceTests` batch paths + `MockAudioServiceContractTests`/`PlaybackStateTests`.
- [ ] **T3 — Prep commit: extract `makeStreamingEngine(targetFormat:hardwareFormat:chunkInterval:onChunk:) -> AVAudioEngine`** *inside* `AudioService` from `startStreamingRecording` (`:844-914`) — no file move, no behavior change (decision 4 / Research → *makeStreamingEngine*). Tap closure captures only locals + injected `onChunk`; caller keeps settle-wait, generation guard, state mutation. De-risks the 133-line method before it moves. Pins: `StreamingHardwareFormatSettleWaitTests` (5). *Same-class note (mild):* `makeStreamingEngine` returns a **real `AVAudioEngine` that is never live on the Simulator**, so keep the pin on the pure settle-wait/generation seams — the cheap real-object engine assertion arrives at **T4** (retargeted `stopWithoutEngineBumpsGeneration` on a real `StreamingPCMRecorder`). Do **not** add live-engine test infra here.
- [ ] **T4 — Extract `StreamingPCMRecorder`** (AVAudioEngine PCM). Move `audioEngine` (`:735`), `streamingGeneration` (`:743`), `isValidHardwareFormat` (`:749`), `waitForValidHardwareFormat` (`:765`), `startStreamingRecording` (`:794`), `stopStreamingRecording` (`:932`) + `makeStreamingEngine` (from T3) into `Services/StreamingPCMRecorder.swift`. Move **both** `nonisolated static` #104 seams — `isValidHardwareFormat` (`:749`) **and** `waitForValidHardwareFormat` (`:765`) — and **re-qualify ALL references** (decision 3): in `AudioServiceTests.swift` (`isValidHardwareFormat` 3×, `waitForValidHardwareFormat` 2×) → `StreamingPCMRecorder.…`; confirm `Services/Mocks/MockAudioService.swift` carries **no** streaming-seam reference (grep clean). **Retarget `stopWithoutEngineBumpsGeneration` (`AudioServiceTests.swift:312`)** (gate note 2): it constructs a real `AudioService()` and reads internal `streamingGeneration` — retarget it to construct a **real `StreamingPCMRecorder()`** (not the mock) and read *its* `streamingGeneration`, so a broken stop/generation rewire fails on the real engine seam — the cheap same-class real-object assertion for streaming (no new infra). Facade OR-aggregates recording state. Pins: `StreamingHardwareFormatSettleWaitTests` (5, incl. the retargeted test).
- [ ] **T5 — Extract `AudioPlaybackService`** (AVPlayer + stall). Move `PlaybackState` (`:99`), `playOpusAudio` (`:953`), `performPlaybackBody` (`:981`) incl. KVO + 5 s stall timer (`:1054`, #106), `cleanupPlayback` (`:1134`), `stopPlayback` (`:1157`), breadcrumb (`:1179`) into `Services/AudioPlaybackService.swift`. Moving the **nested `AudioService.PlaybackState` type** → `AudioPlaybackService.PlaybackState`: **re-qualify ALL references** (decision 3) — `PlaybackStateTests` uses `AudioService.PlaybackState` **8×** (`AudioServiceTests.swift:155,163,173–176`); confirm `Services/Mocks/MockAudioService.swift` carries **no** `PlaybackState` reference (grep clean). Repoint the facade `prepareForRecording` playback-stop (T2) to `playback.stopPlayback()`. Playback depends on **session** methods (`withPlaybackCategory` `:976`, `setupAudioSession(mode:)` `:374`) that **still live on the facade** at T5 (decision 4) — inject them as closures so playback stays free of the session type until T6. Facade forwards `isPlaying`. *Same-class note (mild):* add a **cheap real-object assertion** — construct a real `AudioPlaybackService`, call `stopPlayback()`/`cleanupPlayback()` with **no live `AVPlayer`**, assert safe no-op + `isPlaying == false`/state cleared (exercises the real cleanup path off the mock; no live player needed). Pins: `PlaybackStateTests` + `MockAudioServiceContractTests`.
- [ ] **T6 — Extract `AudioSessionManager`** (last; owns all category/mode/activation policy — second-order seam for #97 CarPlay). Move `categoryOptions` (`:169`), `setupAudioSession` (`:198`), `deactivateSession` (`:267`), `shouldSwapCategoryForTTS` (`:293`), `withPlaybackCategory` (`:314`), `switchAudioMode` (`:387`), `handleRouteChange` (`:410`), interruption seams+handler (`:439-526`), observer tokens (`:135-146`, keep the `OSAllocatedUnfairLock` box for the nonisolated `deinit`), `currentAudioMode` (`:123`) into `Services/AudioSessionManager.swift`. Move the **4 remaining `nonisolated static` #104 seams** — `categoryOptions`, `shouldSwapCategoryForTTS`, `interruptionTeardown`, `shouldResumeSession` — and **re-qualify ALL references** (decision 3): `AudioServiceTests.swift` (`categoryOptions` 8×, `shouldSwapCategoryForTTS` 2×, `interruptionTeardown` 4×, `shouldResumeSession` 3×) **plus `Services/Mocks/MockAudioService.swift:34` (`interruptionTeardown`) and `:57` (`shouldResumeSession`)** → `AudioSessionManager.…` (MockAudioService is under `Services/`, so the edit stays inside the Acceptance-2 boundary). **Interruption wiring = explicit callbacks** (decision 2): the session unit exposes interruption-outcome callbacks; the facade wires them to the batch/streaming/playback units (all now exist). Preserve `AVAudioSession` activation **ordering verbatim** (Scope).
  **Injection seam for the post-T6 gate:** split the handler `:467-526` into (a) a thin notification-parsing entry `handleInterruption(_ notification:)` that extracts `(type, options)` and (b) a directly-callable effect core `handleInterruptionEvent(_ type:options:) async` that performs the fan-out (teardown routing → `onInterruptionBegan?()` → playback stop → resume-session decision — matching source: `onInterruptionBegan` fires inside the streaming teardown branch, *before* the playback stop), **preserving the `Task { @MainActor }` boundary verbatim**. Inject session reactivation as a closure `reactivateSession: () throws -> Void` (default `AVAudioSession.sharedInstance().setActive(true)`) so a spy can count `.ended`/`.shouldResume` calls. This is a behavior-preserving internal decomposition, not a protocol change (the handler is `private nonisolated`, unaffected by Acceptance-3). Falsifiable test = new `InterruptionHandlerFanOutTests` (see Acceptance 6).
  **~300-line flag on landing (Gate A):** AudioSessionManager absorbs the largest cluster (category/mode/activation/route/interruption) — it is the **one unit at real risk of exceeding the ~300-line cap**. Run `wc -l` on landing; if over ~300, **flag it, don't silently exceed** (CLAUDE.md fail-loud). Natural sub-seam if a split is forced: route/interruption handling vs. category/mode/activation policy — split only if actually over.
  Pins: `AudioSessionCategoryOptionsTests` + `InterruptionTeardownRoutingTests` + `InterruptionResumeRoutingTests` + `MockAudioServiceInterruptionTests` + `QuizViewModelInterruptionTests` + `ScenePhaseTeardownTests` + **`InterruptionHandlerFanOutTests` (new, Acceptance 6)**.

## Acceptance

Machine-evaluable gate. **Every unit commit (T1–T6) must satisfy all of it** before the next task starts (decision 5) — not just the final commit.

- [ ] **0 — Start precondition met.** #104 — car audio founder on-device car legs signed off (decision 6). Do not begin T1 otherwise.
- [ ] **1 — Pinning suites green after every unit commit** (all 10, zero skipped):
  ```
  cd apps/ios-app/Hangs && xcodebuild test -scheme Hangs-Local \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
    -only-testing:HangsTests/AudioSessionCategoryOptionsTests \
    -only-testing:HangsTests/StreamingHardwareFormatSettleWaitTests \
    -only-testing:HangsTests/InterruptionTeardownRoutingTests \
    -only-testing:HangsTests/InterruptionResumeRoutingTests \
    -only-testing:HangsTests/MockAudioServiceInterruptionTests \
    -only-testing:HangsTests/QuizViewModelInterruptionTests \
    -only-testing:HangsTests/AudioDevicePickerTests \
    -only-testing:HangsTests/ScenePhaseTeardownTests \
    -only-testing:HangsTests/MockAudioServiceContractTests \
    -only-testing:HangsTests/PlaybackStateTests
  ```
- [ ] **2 — Zero diff outside `Services/`** (+ the moved/edited audio test files: `HangsTests/AudioServiceTests.swift` and any new per-unit test files). `git diff --name-only <base>` lists only `apps/ios-app/Hangs/Hangs/Services/**` and those test files — nothing else (no `AppState.swift`, no consumers, no views).
- [ ] **3 — `AudioServiceProtocol` declaration unchanged.** The `protocol AudioServiceProtocol { … }` block (`AudioService.swift:34`) is byte-identical to the pre-split baseline: `git diff <base> -- apps/ios-app/Hangs/Hangs/Services/AudioService.swift` shows no hunk touching the protocol block.
- [ ] **4 — Exactly one `AudioService()` construction site.** In app source (excludes `HangsTests`, excludes `MockAudioService`): `grep -rEn '(^|[^A-Za-z])AudioService\(\)' apps/ios-app/Hangs/Hangs --include='*.swift'` returns exactly one line — `Utilities/AppState.swift:65` (decision 1).
- [ ] **5 — Each new unit file ≤ ~300 lines**, and the residual `AudioService.swift` facade also ≤ ~300 after T6: `wc -l` on `AudioDeviceManager.swift`, `BatchRecorder.swift`, `StreamingPCMRecorder.swift`, `AudioPlaybackService.swift`, `AudioSessionManager.swift`, `AudioService.swift`. **`AudioSessionManager.swift` is the one unit at real risk of exceeding the cap** (largest cluster) — if `wc -l` > ~300 on landing, **flag it, don't silently exceed** (see T6; sub-split only if actually over).
- [ ] **6 — Post-T6 rewire gate (falsifiable — the one the 10 suites can't fail on).** A new `InterruptionHandlerFanOutTests` suite lands **in the T6 commit** and joins the item-1 command list **from T6 onward**. It constructs the **real `AudioSessionManager`** wired to **spy units** (spy stop-streaming / stop-batch / stop-playback callbacks + spy `onInterruptionBegan` + spy `reactivateSession`) and drives a **scripted `.began`/`.ended`** directly through `handleInterruptionEvent(_ type:options:)` (the injected seam, T6), asserting the callback fan-out: streaming-active `.began` → **streaming stopped + `onInterruptionBegan` fired**, batch **not** stopped; batch-active `.began` → **batch stopped**, streaming not; playing → **playback stopped**; `.ended` with `.shouldResume` → **`reactivateSession` called exactly once**, without → **never**. Must go **red** on a mis-wired stop/`onInterruptionBegan` callback, a missing streaming-active (`audioEngine != nil`) read, or altered `setActive` ordering — i.e. it can actually fail on a broken rewire (the #67/#104 stranded-mic class). Same-class real-object cover for T3/T4 (streaming engine) and T5 (AVPlayer) lands as their mild per-task notes.
- [ ] **7 — [HUMAN] On-device interruption + streaming leg** (final acceptance; founder on-device, per the #104 founder-legs pattern — the one path no Simulator suite covers, because the streaming `AVAudioEngine` is never live on the Simulator). On device: start a **voice answer (streaming recording active)** → take an **incoming phone call** (interruption `.began`) → **hang up** (`.ended`) → confirm the **mic recovers** and the next voice answer records with **no stranded mic** (#67/#104 failure class). Founder sign-off before the split is considered done.

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
| 3 · Plan review       | ✅ done | ready-check READY · design-soundness SOUND 0.88 |
| 4 · Impl-plan         | ✅ done | — |
| 5 · Impl-plan review  | ✅ done | cycle 2: ready-check READY · design-soundness SOUND 0.87 |
| 6 · Split             | ✅ done | 3-session execution-prompts file (T1–T2 / T3–T4 / T5–T6); ready-for-agent, start-gated on #104 |

**Last updated:** 2026-07-20 (Phase 6 split — **prep complete**) · **Next:** — (ready-for-agent; do not start until #104 founder on-device legs pass) · **Gate attempts:** P3 1/3 (PASSED) · P5 2/3 (PASSED cycle 2)
