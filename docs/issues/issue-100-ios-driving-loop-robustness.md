# #100 — iOS driving-loop robustness (MVP-review blockers)

**Triage:** bug · agent-side DONE 2026-07-16 · re-verified 2026-08-26
**Status:** Planned 2026-07-16 from the pre-MVP review (7-agent parallel review + top-level first-hand verification of the load-bearing findings). **This is the real launch gate** — five defects in the core voice loop that can stall, dead-end, or crash the app mid-drive. All iOS-only, no backend/infra dependency, so this ships to TestFlight independently of #101/#102/#103.

## 1. Why

The close-circle TestFlight is "play trivia hands-free while driving". A stall or dead-end mid-loop is the worst failure mode (safety + the one thing the product must do). The review found five confirmed robustness defects on the hot path. Backend core + money architecture verified sound separately; this cluster is what stands between the app and a friends launch.

## 2. Findings (confirmed, file:line + fix)

| # | Sev | Defect | Evidence | Fix |
|---|-----|--------|----------|-----|
| 1 | P1→P0 | **Double-tap "Next" → blank question, loop dead-ends** (restart required) | `ViewModels/QuizViewModel.swift:1159` `proceedToNextQuestion()` — guard checks `quizState.isShowingResult` (1164) but state only leaves `showingResult` at the transition (1199), *after* two awaits (`stopAnyPlayingAudio` 1175, 100 ms sleep 1178). Two concurrent calls both pass the guard; the second sets `currentQuestion = nextQuestion` after the first nil-ed it → next answer hits `guard let question = currentQuestion` (1070) → "No question to evaluate". Trigger: double-tap Next (`Views/ResultView.swift:236`) or Next racing auto-advance. | Re-entrancy flag (`isAdvancing`, like `isProcessingResponse`) or transition to a transient state *before* the awaits. |
| 2 | P1 | **Answer double-submits on the streaming (default) voice path** → wrong-question scoring | `ViewModels/QuizViewModel+Recording.swift:465` `confirmAnswer()` — streaming path (`pendingResponse == nil`) falls to `guard !transcribedAnswer.isEmpty; await resubmitAnswer(...)` (481-482); `transcribedAnswer` is never cleared and `resubmitAnswer` (785) has no dedup guard. Three callers: button (`Views/QuestionView.swift:61`), voice "ok" (`CommandListener:189`), auto-confirm timer (`Timers:216`). Auto-confirm at t≈10 s + a tap/"ok" → two `POST /input`; a late second submits against the *next* question. | Capture-then-clear `transcribedAnswer` on entry, or add a re-entrancy flag to `confirmAnswer`/`resubmitAnswer`. |
| 3 | P1 | **Mic does not recover after a phone call / Siri interruption** | `Services/AudioService.swift:433` interruption `.ended` only logs ("don't auto-resume"); no record-start path calls `setActive(true)` afterward (`setActive` lives only in `setupAudioSession` + `withPlaybackCategory`). After a call, `handleAudioInterruption` returns to `.askingQuestion` on the same question with no new TTS → a mic tap runs against a session iOS deactivated → `engine.start()`/`record()` fail → "Recording failed", repeatable until a TTS replay reactivates. | On `.ended`, if `options.contains(.shouldResume)`, re-run `setupAudioSession(mode:)` (or `setActive(true)`) before returning control. |
| 4 | P1 | **Two concurrent audio engines → documented crash path** (also: hot mic left running) | `Services/SilenceDetectionService.swift:215` `startListening()` assigns `self.audioEngine = engine` (~256) but calls `engine.start()` only after a 50 ms `Task.sleep` (~374); a `stopListening()` in that window nils `self.audioEngine`, the resumed start orphans a running engine, and `startStreamingRecording` (`+Recording.swift:97`) spins its own engine — the codebase's own "#64 two-engine crash config". *(agent-reported internal line anchors — verify on execution.)* | After the sleep, re-check `self.audioEngine === engine` (generation token) before `engine.start()`; bail if it changed. |
| 5 | P2 (policy P0) | **Banned `nonisolated(unsafe)`** on two observer tokens | `Services/AudioService.swift:134-135` `nonisolated(unsafe) private var routeChangeObserver/interruptionObserver`. Near-zero functional risk (written once on `@MainActor`, read in `deinit`) but explicitly banned in this repo. | Hold tokens in an `OSAllocatedUnfairLock` box (pattern already at `AudioService.swift:684`) or a small Sendable holder. |

## 3. Plan

One sweep, each item its own commit; findings 1–4 are the priority, 5 is cleanup that rides along. Add a regression test per item at the **flow/state-machine altitude** (per `#57` verification altitude — assert the state machine can't reach the bad state / can't double-submit; do not gate on pixels):

- **1** — re-entrancy guard on `proceedToNextQuestion`; test: two rapid `proceedToNextQuestion()` calls leave exactly one advance, `currentQuestion` non-nil.
- **2** — idempotent `confirmAnswer` on the streaming path; test: two `confirmAnswer()` (auto-confirm + tap) → one `resubmitAnswer`.
- **3** — resume audio session on `.ended` when `.shouldResume`; test/manual: simulate interruption end → record-start path succeeds without a TTS replay.
- **4** — generation-token guard in `SilenceDetectionService.startListening`; test: interleaved start/stop never leaves a running engine when `self.audioEngine` changed.
- **5** — remove `nonisolated(unsafe)`.

## 4. Acceptance

- Findings 1–4 each covered by a failing-then-passing test at flow altitude; suite green.
- No `nonisolated(unsafe)` in the module (`grep` clean).
- On-sim smoke of the loop (delegate to `ios-ui-driver`): normal play-through + a double-tap-Next attempt + a simulated interruption-end all keep the loop flowing.
- Founder on-device: phone call mid-question → mic recovers on next tap. (`[HUMAN]`, in the TestFlight build.)

## 5. Out of scope

Barge-in (dead feature — separate P2, see handoff), monetization (#101/#102), pack backend (#103), the open April timer bug beyond what findings 1–4 touch.

## Uzavretie (2026-08-26)

Všetkých 5 fixov shipnutých už **2026-07-16** (v deň spísania issue), TODO riadok len ostal omylom otvorený:

| # | Fix commit | Dnešný stav (po #113 dekompozícii QuizViewModel) |
|---|-----------|--------------------------------------------------|
| 1 | `3c20f96f` | `isAdvancing` guard drží v `advanceToNextQuestionOrFinish()` (`QuizViewModel.swift:1774`), nastavený pred awaitmi; oba callery (Next button aj auto-advance) idú cez neho |
| 2 | `e22c49e0` | capture-then-clear `transcribedAnswer` na vstupe `confirmAnswer()` (`RecordingCoordinator+Confirmation.swift:31`), + `isSubmittingAnswer` single-flight v `resubmitAnswer`; navyše `question_id` + 409 mismatch server-side (`dec4fe8a`, #133 — audit-deferred fixes) |
| 3 | `a669e39b` | `.ended` + `.shouldResume` → `setActive(true)` (`AudioService.swift:566-589`, helper `shouldResumeSession`) |
| 4 | `969a2a13` | identity re-check `shouldStartEngine` po sleepe pred `engine.start()` (`SilenceDetectionService+Engine.swift:223`); + `startInFlight` single-flight (`39706c71`, #133) |
| 5 | `63b0c2a6` | `grep nonisolated(unsafe)` v module čistý — observer tokeny v `OSAllocatedUnfairLock` |

Re-verifikácia 2026-08-26 (2 nezávislé code-read agenty + cielený test beh): všetky guardy prežili augustové prestavby; regresné testy `QuizViewModelAdvanceRaceTests` / `QuizViewModelSubmissionRaceTests` / `QuizViewModelResubmitTests` / `SilenceDetectionServiceTests` / interruption suites v `AudioServiceTests.swift` — **61/61 green** na sim.

**Ostáva (`[HUMAN]`):** founder on-device — telefonát mid-question → mic sa zotaví na ďalší tap (zdieľaný leg s #67 Part A).

## TODO detail (migrované z TODO.md 2026-08-26)

> - [ ] #100 iOS driving-loop robustness (MVP-review blockers) — **★ LAUNCH GATE** — [plan](../issues/issue-100-ios-driving-loop-robustness.md) — from the 2026-07-16 pre-MVP review (7 parallel reviewers + first-hand verify). 5 confirmed defects on the core voice loop, all iOS-only (ships to TestFlight independently): double-tap "Next" → blank question dead-end (`QuizViewModel.swift:1159` re-entrancy), streaming-path answer double-submit (`QuizViewModel+Recording.swift:465`), no mic recovery after a phone call (`AudioService.swift:433` `.ended` never reactivates), two-engine crash race (`SilenceDetectionService.swift:215`), banned `nonisolated(unsafe)` (`AudioService.swift:134`). Do FIRST.

