# Issue #116 — Execution plan + ready-to-paste session prompts

**Created:** 2026-07-20 — from the prepared #116 plan (Phase 6 split of `/prepare-issue`). #116 is a **6-commit internal refactor of one 1,246-line safety-critical audio file** (`AudioService.swift`), so it's split into 3 session-sized, independently-committable chunks. Each chunk below has a self-contained prompt: open a fresh session, paste the fenced block, go. The codebase is already mapped in the Recon snapshot — sessions do **not** re-map.

> Parent plan: [`issue-116-audioservice-split.md`](issue-116-audioservice-split.md). Source: [iOS architecture review 2026-07-18](../research/ios-architecture-review-2026-07-18.md) — Top 10 item 7.

> **START PRECONDITION (gates every session):** do **not** begin T1 until the **#104 — car audio (HFP flapping + mic capture)** founder on-device car legs pass (decision 6). A mid-refactor audio regression on an unverified build would be unbisectable between "the split broke it" and "#104 never worked on device". See Human prerequisites.

---

## Recon snapshot — what the codebase already gives us

**Target file (`apps/ios-app/Hangs/Hangs/`):**

- `Services/AudioService.swift` — **1,246 lines, `@MainActor`, the sole `AudioServiceProtocol` conformer**. Protocol declared at `:34` and is **out of scope to touch** (Acceptance 3, byte-identical). This is a **call-site-neutral** split: `AudioService` stays the only conformer and OR-aggregates `isRecording`/`recordingStartedAt`, forwards `isPlaying`, re-publishes device state.
- **Single construction site:** `Utilities/AppState.swift:65` (`AudioService()`) — the **only** one, and it must stay the only one (Acceptance 4). Every consumer (`QuizViewModel` + its `+Audio`/`+Recording`/`+ScenePhase` extensions, `OnboardingViewModel`) depends on `AudioServiceProtocol`, never the concrete type; views read via the VM. So the 5 units are **internal**, never injected via AppState (decision 1).
- **New unit files all land under `Services/`** (keeps the diff inside the Acceptance-2 boundary): `AudioDeviceManager.swift`, `BatchRecorder.swift`, `StreamingPCMRecorder.swift`, `AudioPlaybackService.swift`, `AudioSessionManager.swift`.
- `Services/Mocks/MockAudioService.swift` — the mock. **It is under `Services/`, so editing it stays inside the Acceptance-2 diff boundary.** It references two #104 seams to re-qualify at T6: `interruptionTeardown` (`:34`) and `shouldResumeSession` (`:57`). Grep it clean of streaming-seam / `PlaybackState` refs at T4/T5.

**Cluster map (5 responsibilities → 5 units; all anchors in `AudioService.swift`):**

1. **Session** → `AudioSessionManager` — `categoryOptions` `:169`, `setupAudioSession` `:198`, `deactivateSession` `:267`, `shouldSwapCategoryForTTS` `:293`, `withPlaybackCategory` `:314`, `switchAudioMode` `:387`, `handleRouteChange` `:410`, interruption seams+handler `:439-526`; observer tokens `:135-146` (keep `OSAllocatedUnfairLock` box for the nonisolated `deinit`), `currentAudioMode` `:123`.
2. **Device** → `AudioDeviceManager` — device `@Published` props `:81-93`, `refreshAvailableDevices` `:531`, `updateCurrentInputDevice` `:553`, `setPreferredInputDevice` `:570`.
3. **Batch M4A** → `BatchRecorder` — `prepareForRecording` `:611` (**stays facade orchestration**, see T2), `startRecording` `:623`, `stopRecording` `:687`, `AVAudioRecorderDelegate` ext `:1195`, `audioRecorder` `:121`.
4. **Streaming PCM** → `StreamingPCMRecorder` — `audioEngine` `:735`, `streamingGeneration` `:743`, `isValidHardwareFormat` `:749`, `waitForValidHardwareFormat` `:765`, `startStreamingRecording` `:794`, `stopStreamingRecording` `:932`.
5. **AVPlayer playback + stall** → `AudioPlaybackService` — `PlaybackState` `:99`, `playOpusAudio` `:953`, `performPlaybackBody` `:981` (KVO + 5 s stall timer `:1054`, #106), `cleanupPlayback` `:1134`, `stopPlayback` `:1157`, breadcrumb `:1179`.

**Shared-state hazards (the real risk — the facade + interruption wiring, not the moves):**

- `isRecording` / `recordingStartedAt` are `@Published` and written by **both** batch (`:676/:693`) and streaming (`:917/:939`) → facade must **OR-aggregate**.
- The **interruption handler (`:478-525`) reaches into all 3 non-session units** — `stopStreamingRecording`, `stopRecording`, `stopPlayback`, `onInterruptionBegan?()`, and reads `audioEngine != nil` / `isRecording`. This is why the session unit is extracted **last** (T6), so it can wire callbacks to units that already exist.
- **Verified source fan-out order** (`.began`): `interruptionTeardown` routing → *streaming branch:* `stopStreamingRecording()` then `onInterruptionBegan?()` (batch branch: `stopRecording()`; none: break) → **then** `if isPlaying { stopPlayback() }` → warning. `.ended`: `shouldResumeSession(options:)` → `setActive(true)`. `onInterruptionBegan` fires **inside teardown, before** the playback stop — preserve this order verbatim.
- Playback depends on **session**: `performPlayback` calls session-owned `withPlaybackCategory` (`:976`); failure-recovery calls `setupAudioSession(mode:)` (`:374`). At T5 those still live on the facade → **inject them as closures** so playback stays free of the session type until T6.
- Real "session state" is the **`AVAudioSession.sharedInstance()` process singleton**, coordinated by **activation ordering**, not an AudioService field — so preserve activation ordering verbatim (Scope, decision-order-sensitive).

**#104/#106 `nonisolated static` seams (pure, unit-tested with no live session — move + re-qualify, decision 3):** `isValidHardwareFormat` `:749`, `waitForValidHardwareFormat` `:765` (→ `StreamingPCMRecorder`, T4); `categoryOptions` `:169`, `shouldSwapCategoryForTTS` `:293`, `interruptionTeardown`, `shouldResumeSession` (→ `AudioSessionManager`, T6). No thin forwarders left behind.

**Tests (Swift Testing, `HangsTests/`):** `AudioServiceTests.swift` holds the seam suites (`AudioSessionCategoryOptionsTests`, `StreamingHardwareFormatSettleWaitTests`, `InterruptionTeardownRoutingTests`, `InterruptionResumeRoutingTests`, `MockAudioServiceInterruptionTests`, `QuizViewModelInterruptionTests`, `PlaybackStateTests`) + the two real-object tests to retarget (`stopWithoutEngineBumpsGeneration` `:312` → T4; `PlaybackState` refs `:155,163,173–176` → T5). Separate files: `AudioDevicePickerTests.swift`, `ScenePhaseTeardownTests.swift`, `MockAudioServiceContractTests`. ⚠️ The streaming `AVAudioEngine` is **never live on the Simulator** — keep pins on the pure settle-wait/generation seams; real-object assertions are cheap no-live-object checks (T4/T5); the true streaming-interruption path is the [HUMAN] on-device leg (Acceptance 7).

**The gate command (Acceptance 1 — run green after EVERY unit commit, zero skipped):**
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
From T6 onward, **add** `-only-testing:HangsTests/InterruptionHandlerFanOutTests` (new suite, Acceptance 6). Per `.claude/rules/ios.md`, build/test via shell `xcodebuild` (pipe `| tail`) or the `ios-tester` agent — not MCP `build_sim`/`test_sim`.

---

## Locked decisions (carry into every session — verbatim from the parent plan)

| # | Decision |
|---|---|
| **1** | **Facade stays the sole conformer; units are internal.** `AudioService` remains the only `AudioServiceProtocol` conformer, composes 5 owned units; units are **not** injected via AppState — single construction site stays `AppState.swift:65`. Injecting units would leak the decomposition into every consumer for no gain. |
| **2** | **Interruption wiring = explicit callbacks.** The session unit exposes interruption-outcome callbacks; `AudioService` wires them to the batch/streaming/playback units. Replaces the handler's implicit self-reach-ins (`:478-525`) with explicit, testable seams. |
| **3** | **Static #104 seams move with their units; tests updated by qualifier only.** Move each `nonisolated static` seam to its owning unit and **re-qualify ALL references** (test file + MockAudioService) — no thin forwarders left on the facade. |
| **4** | **Split order is LOCKED (safest-first): AudioDeviceManager → BatchRecorder → *(makeStreamingEngine prep)* → StreamingPCMRecorder → AudioPlaybackService → AudioSessionManager last.** Do not reorder. Session goes last because its interruption handler references all three other units. |
| **5** | **One unit per commit; full pinning suites green each step.** Each unit lands as its own commit with all pinning suites green, so any regression bisects to a single extraction. |
| **6** | **Precondition / sequencing gate.** Do **not** start until the #104 — car audio founder on-device car legs pass. Ordering vs #115 (iOS 26 target) is free — `AudioService.swift` has **no** `@available`/`#available` guards, so #115 is not a prerequisite. |

*Second-order (note, not a build item):* `AudioSessionManager` owns **all** category/mode/activation policy in one place — the natural seam for #97 — CarPlay support's different session policy later. Do **not** add CarPlay branching now; just don't spread session policy across units.

---

## Session breakdown

| Session | Tasks | Risk | Notes |
|---|---|---|---|
| **A — Isolated units** | T1 (`AudioDeviceManager`) + T2 (`BatchRecorder`) | Low | The two most-isolated clusters: device mgmt has no cross-unit deps; batch shares only `isRecording`/`recordingStartedAt` (facade OR-aggregates). `prepareForRecording` stays facade orchestration; `stopPlayback` still on facade at T2. **Blocks B.** |
| **B — Streaming** | T3 (`makeStreamingEngine` prep, no move) + T4 (`StreamingPCMRecorder`) | Med | T3 de-risks the 133-line `startStreamingRecording` in place, T4 moves it + 2 static seams + retargets `stopWithoutEngineBumpsGeneration` to a real `StreamingPCMRecorder`. Depends on **A merged**. **Blocks C.** |
| **C — Playback + Session** | T5 (`AudioPlaybackService`) + T6 (`AudioSessionManager`, last) | **High** | The hardest, most-coupled pair. T5 injects session methods as closures (facade still owns them); T6 moves the largest cluster, repoints those closures to the real session unit, wires interruption callbacks (decision 2), lands the falsifiable `InterruptionHandlerFanOutTests`, and is the one unit at real risk of the ~300-line cap (flag, don't silently exceed). Depends on **B merged**. |

**Sessions run strictly sequentially** (A → B → C); each depends only on the prior, already-merged session. **Escape hatch for Session C** (the heaviest): if context pressure hits after T5 lands green, commit T5 and spill **T6 to its own follow-up session** — the T5→T6 handoff is clean (T5 leaves session methods on the facade behind closures; T6's job is fully specified in the parent plan). Prefer one session; split only if actually pressured.

---

## Human prerequisites

Class `a` refactor, but two **human** gates bracket the run (neither is class `b`/`c` sensitive scope — they are a start-precondition and a final on-device leg, per the #104 founder-legs pattern):

1. **START (gates all sessions):** #104 — car audio (HFP flapping + mic capture) founder on-device **car legs pass**. Confirm sign-off before pasting Session A. Do not begin otherwise (decision 6 / Acceptance 0).
2. **DONE (gates "split complete"):** the **[HUMAN] on-device interruption + streaming leg** (Acceptance 7) — start a voice answer (streaming active) → take an incoming call (`.began`) → hang up (`.ended`) → confirm the **mic recovers** with no stranded mic (#67/#104 failure class). Founder sign-off after Session C. No Simulator suite covers this (streaming `AVAudioEngine` is never live on the Simulator).

---

## Ready prompt — Session A (Isolated units: AudioDeviceManager + BatchRecorder)

```
Work on issue #116 (Split AudioService), Session A only: extract AudioDeviceManager (T1) then BatchRecorder (T2) — two separate commits. This is a pure internal, behavior-preserving refactor: zero behavior/protocol/call-site change. Do NOT touch StreamingPCMRecorder / AudioPlaybackService / AudioSessionManager — those are Sessions B/C. Confirm the #104 car-audio founder on-device legs have passed before starting (Acceptance 0); stop and ask if not.

Read first (already mapped — do NOT re-map the codebase):
- docs/issues/issue-116-execution-prompts.md  → "Recon snapshot" + "Locked decisions" (esp. 1, 3, 4, 5). The gate command is there.
- docs/issues/issue-116-audioservice-split.md  → Tasks T1 + T2 (exact line anchors + what stays on the facade) and the full Acceptance list.
- apps/ios-app/Hangs/Hangs/Services/AudioService.swift  → the source clusters (device :81-93/:531/:553/:570; batch :121/:611/:623/:687/:1195).
- apps/ios-app/Hangs/HangsTests/AudioServiceTests.swift + AudioDevicePickerTests.swift  → Swift Testing patterns; the pinned batch/device tests.

Build (one commit per task; the gate command must be green after EACH):
1) T1 — Move the device cluster into Services/AudioDeviceManager.swift. Facade owns one instance and RE-PUBLISHES its device state so availableInputDevices / currentOutputDeviceName reach consumers unchanged. Pins: AudioDevicePickerTests (2).
2) T2 — Move the batch M4A cluster into Services/BatchRecorder.swift. prepareForRecording (:611) STAYS facade orchestration: facade calls the playback stop (stopPlayback is still on the facade at T2 — `await stopPlayback()`), then delegates settle/prep to BatchRecorder.prepareForRecording(). BatchRecorder gets NO playback reference. Facade OR-aggregates isRecording / recordingStartedAt across batch+streaming. Pins: AudioServiceTests batch paths + MockAudioServiceContractTests/PlaybackStateTests.

After EACH commit verify Acceptance 1-5: gate command green (10 suites, 0 skipped); git diff --name-only touches ONLY Services/** + the audio test files (no AppState.swift, no consumers, no views); the AudioServiceProtocol block (:34) is byte-identical; exactly one AudioService() site (AppState.swift:65); each new file ≤ ~300 lines.

Done = the gate command is green after both commits, all five Acceptance checks hold. Commit per task, push to arch-review-ios (NEVER main). Tick T1/T2 in issue-116-audioservice-split.md + update the docs/todo/TODO.md #116 line. Update this file's Status. This is safety-critical audio: fail loud, no silent skips.
```

---

## Ready prompt — Session B (Streaming: makeStreamingEngine prep + StreamingPCMRecorder)

```
Work on issue #116 (Split AudioService), Session B only: T3 (extract makeStreamingEngine IN PLACE, no move) then T4 (extract StreamingPCMRecorder) — two separate commits. Session A (AudioDeviceManager + BatchRecorder) must be merged first. Behavior-preserving; do NOT touch playback/session units (Session C). Confirm #104 legs passed (Acceptance 0).

Read first (already mapped — do NOT re-map):
- docs/issues/issue-116-execution-prompts.md  → "Recon snapshot" (streaming cluster + the makeStreamingEngine internals note + the "never live on Simulator" caveat) + "Locked decisions" (3, 4, 5) + the gate command.
- docs/issues/issue-116-audioservice-split.md  → Tasks T3 + T4 (exact anchors, the seams to re-qualify, the test retarget) + Acceptance + Research "makeStreamingEngine extraction".
- apps/ios-app/Hangs/Hangs/Services/AudioService.swift  → startStreamingRecording (:794, 133 lines) + the streaming cluster (:735/:743/:749/:765/:932).
- apps/ios-app/Hangs/HangsTests/AudioServiceTests.swift  → StreamingHardwareFormatSettleWaitTests (5) + stopWithoutEngineBumpsGeneration (:312).
- apps/ios-app/Hangs/Hangs/Services/Mocks/MockAudioService.swift  → confirm it carries NO streaming-seam reference (grep clean).

Build (one commit per task; gate command green after EACH):
1) T3 — Extract makeStreamingEngine(targetFormat:hardwareFormat:chunkInterval:onChunk:) -> AVAudioEngine INSIDE AudioService, from startStreamingRecording (:844-914). No file move, no behavior change. The tap closure captures only locals + injected onChunk (no self-state) — it lifts cleanly; caller keeps settle-wait, generation guard, state mutation. Keep the pin on the pure settle-wait/generation seams (the returned AVAudioEngine is never live on the Simulator — do NOT add live-engine infra). Pins: StreamingHardwareFormatSettleWaitTests (5).
2) T4 — Move the streaming cluster + makeStreamingEngine (from T3) into Services/StreamingPCMRecorder.swift. Move BOTH nonisolated static #104 seams — isValidHardwareFormat and waitForValidHardwareFormat — and RE-QUALIFY ALL references in AudioServiceTests.swift (isValidHardwareFormat 3x, waitForValidHardwareFormat 2x) → StreamingPCMRecorder.…; confirm MockAudioService has none. RETARGET stopWithoutEngineBumpsGeneration (:312) to construct a REAL StreamingPCMRecorder() (not the mock) and read its streamingGeneration, so a broken stop/generation rewire fails on the real engine seam. Facade OR-aggregates recording state. Pins: StreamingHardwareFormatSettleWaitTests (5, incl. the retargeted test).

After EACH commit verify Acceptance 1-5 (gate green; diff only in Services/** + audio tests; protocol :34 byte-identical; one AudioService() site; each file ≤ ~300 lines).

Done = gate command green after both commits, Acceptance 1-5 hold. Commit per task, push to arch-review-ios (NEVER main). Tick T3/T4 + update TODO #116 line + this file's Status. Safety-critical audio: fail loud.
```

---

## Ready prompt — Session C (Playback + Session: AudioPlaybackService + AudioSessionManager last)

```
Work on issue #116 (Split AudioService), Session C only: T5 (extract AudioPlaybackService) then T6 (extract AudioSessionManager, LAST) — two separate commits. Sessions A+B merged first. This is the hardest, most-coupled pair. Behavior-preserving; preserve AVAudioSession activation ORDERING verbatim. Confirm #104 legs passed (Acceptance 0). If context pressure hits after T5 lands green, commit T5 and spill T6 to a follow-up session (the handoff is clean).

Read first (already mapped — do NOT re-map):
- docs/issues/issue-116-execution-prompts.md  → "Recon snapshot" (playback-depends-on-session closures; the VERIFIED interruption fan-out order; the T6 static seams incl. MockAudioService :34/:57) + "Locked decisions" (2, 3, 4, 5) + the gate command (and the InterruptionHandlerFanOutTests addition from T6).
- docs/issues/issue-116-audioservice-split.md  → Tasks T5 + T6 (exact anchors; the handler injection-seam split; the ~300-line flag) + Acceptance 6 (the falsifiable fan-out test spec) + Acceptance 7 (the [HUMAN] on-device leg).
- apps/ios-app/Hangs/Hangs/Services/AudioService.swift  → playback cluster (:99/:953/:981/:1054/:1134/:1157/:1179) + session cluster (:169-526, incl. the interruption handler :467-526) + observer tokens :135-146.
- apps/ios-app/Hangs/HangsTests/AudioServiceTests.swift + ScenePhaseTeardownTests.swift  → PlaybackStateTests (AudioService.PlaybackState 8x at :155,163,173-176), the interruption/teardown suites, the #67 teardown pins.
- apps/ios-app/Hangs/Hangs/Services/Mocks/MockAudioService.swift  → the interruptionTeardown (:34) + shouldResumeSession (:57) refs to re-qualify.

Build (one commit per task; gate command green after EACH; add InterruptionHandlerFanOutTests to the gate from T6):
1) T5 — Move the AVPlayer playback+stall cluster into Services/AudioPlaybackService.swift. Move the nested PlaybackState type → AudioPlaybackService.PlaybackState and RE-QUALIFY ALL references (PlaybackStateTests 8x); confirm MockAudioService has no PlaybackState ref. Repoint the facade prepareForRecording playback-stop (from T2) to playback.stopPlayback(). Playback depends on session methods (withPlaybackCategory :976, setupAudioSession(mode:) :374) that STILL live on the facade at T5 — INJECT them as closures so playback stays free of the session type until T6. Facade forwards isPlaying. Add the cheap real-object assertion (real AudioPlaybackService, stopPlayback()/cleanupPlayback() with no live AVPlayer → safe no-op + isPlaying == false / state cleared). Pins: PlaybackStateTests + MockAudioServiceContractTests.
2) T6 — Move the session cluster into Services/AudioSessionManager.swift (owns ALL category/mode/activation/route/interruption policy — the #97 CarPlay seam; do NOT add CarPlay branching). Move the 4 remaining static seams — categoryOptions, shouldSwapCategoryForTTS, interruptionTeardown, shouldResumeSession — and RE-QUALIFY ALL references: AudioServiceTests.swift (categoryOptions 8x, shouldSwapCategoryForTTS 2x, interruptionTeardown 4x, shouldResumeSession 3x) PLUS MockAudioService.swift :34/:57 → AudioSessionManager.…. Interruption wiring = explicit callbacks (decision 2): the session unit exposes interruption-outcome callbacks; the facade wires them to batch/streaming/playback (all now exist). Repoint the T5 closures to the real session unit. Split the handler (:467-526) into (a) a thin notification-parsing handleInterruption(_ notification:) and (b) a directly-callable effect core handleInterruptionEvent(_ type:options:) async performing the fan-out — teardown routing → onInterruptionBegan?() (inside the streaming branch) → playback stop → resume-session decision — PRESERVING the Task { @MainActor } boundary and setActive ordering verbatim. Inject reactivateSession: () throws -> Void (default AVAudioSession.sharedInstance().setActive(true)) so a spy can count .ended/.shouldResume. Land the new InterruptionHandlerFanOutTests (Acceptance 6): real AudioSessionManager + spy units, scripted .began/.ended through handleInterruptionEvent, asserting streaming-.began → streaming stopped + onInterruptionBegan fired (batch NOT), batch-.began → batch stopped (streaming NOT), playing → playback stopped, .ended+.shouldResume → reactivateSession exactly once (else never). It must go RED on a mis-wired callback, a missing audioEngine != nil read, or altered setActive ordering. ~300-LINE FLAG: run wc -l on AudioSessionManager.swift on landing — if > ~300, FLAG it, don't silently exceed (natural sub-seam: route/interruption vs category/mode/activation). Pins: AudioSessionCategoryOptionsTests + InterruptionTeardownRoutingTests + InterruptionResumeRoutingTests + MockAudioServiceInterruptionTests + QuizViewModelInterruptionTests + ScenePhaseTeardownTests + InterruptionHandlerFanOutTests (new).

After EACH commit verify Acceptance 1-6 (gate green — 11 suites from T6; diff only in Services/** + audio tests; protocol :34 byte-identical; one AudioService() site at AppState.swift:65; every new unit file AND the residual AudioService.swift facade ≤ ~300 lines — flag AudioSessionManager if over).

Done = gate command green after both commits (incl. InterruptionHandlerFanOutTests), Acceptance 1-6 hold. Commit per task, push to arch-review-ios (NEVER main). Tick T5/T6 + update TODO #116 + this file's Status. THEN flag the [HUMAN] on-device interruption+streaming leg (Acceptance 7) for founder sign-off — the split is not "done" until that passes. Safety-critical audio: fail loud, no silent skips.
```

---

## Status

- ✅ Recon + split done (this doc, 2026-07-20). Decisions 1–6 locked; 3 sessions (A → B → C, sequential). Start-gated on #104 founder on-device car legs.
- ⬜ **Session A — Isolated units (T1 AudioDeviceManager + T2 BatchRecorder)** — not started (gated on #104).
- ⬜ **Session B — Streaming (T3 makeStreamingEngine prep + T4 StreamingPCMRecorder)** — blocked on A.
- ⬜ **Session C — Playback + Session (T5 AudioPlaybackService + T6 AudioSessionManager)** — blocked on B; heaviest; may spill T6 to a follow-up session under context pressure.
- ⬜ **[HUMAN] Acceptance 7** — on-device interruption + streaming leg (founder sign-off after Session C).
