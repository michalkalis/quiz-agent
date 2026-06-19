# Plan 54.4 / 54.6 / 54.7 — items that need live-simulator reproduction first

**Parent:** `issue-54-design-refresh-regressions.md` (§54.4, §54.6, §54.7) · **Priority:** P0
**Status:** ready · **Common workflow:** these are **not** confident code fixes — each must be
**reproduced in the simulator first** (light + dark), then located, then fixed with a behavioural
test. Don't change code before the repro confirms the trigger.

> Context note from the parent: the VM logic files (`QuizViewModel*`) were **not** modified by the
> #52 branch, so these may be the redesigned Views calling the unchanged VM differently, or
> pre-existing VM bugs newly *exposed*. The full `SilenceDetectionService` unit suite **passes** on
> this branch (verified 2026-06-12), so the silence state machine itself is **not** broken — focus
> 54.4 on the hard cap, not the state machine.

---

## 54.4 — recording doesn't auto-stop when the user says nothing (founder #5)
**✅ FIXED 2026-06-12.** Code-trace found **four** holes that together meant dead air could leave
the UI in `.recording` forever (silence auto-stop requires speech first — `.silenceAfterSpeech` —
so the hard cap is the only net, and the post-cap path itself leaked):
1. **Service swallowed empty commits** — `ElevenLabsSTTService` only yielded `committed_transcript`
   when `text` was non-empty, so a forced commit after dead air produced *no event at all*. Now
   always yields (empty string = dead-air signal).
2. **No post-commit timeout** — `stopRecordingAndSubmit`'s streaming branch fired `commitAndClose()`
   and waited for an event that might never come. New **commit watchdog**
   (`startCommitWatchdog`, TaskKey `.sttCommitWatchdog`, `Config.sttCommitWatchdogSecs = 5 s`)
   escalates to `handleTranscriptionFailure()` if nothing arrives.
3. **Hard cap skipped on re-record** — `guard !isRerecording` removed from
   `startAutoStopRecordingTimer` (silence detection is *also* off for re-records and never runs on
   the streaming path, so a silent re-record had no stop mechanism at all). The old
   `autoStopSkippedDuringRerecord` test encoded that opt-out as intent — flipped to
   `autoStopArmedDuringRerecord` with documented rationale (CLAUDE.md rule #4).
4. **`.disconnected` mid-recording stranded state** — handler now stops the stream, clears flags,
   sets a retry message, and returns to `.askingQuestion`.
`handleCommittedTranscript` now routes empty/whitespace text to `handleTranscriptionFailure()`
(3-tier: retry prompt → "closer to the mic" → auto-skip) instead of showing an empty confirmation.
**Tests (red→green):** `QuizViewModelStreamingTests` Tests 4–7 (disconnect returns to
`.askingQuestion`; empty commit escalates; watchdog rescues silent commit via
`commitEmitsNothing` mock seam; cap fires during re-record), `ElevenLabsSTTServiceTests`
empty-commit emission flipped, `QuizViewModelTimerTests.autoStopArmedDuringRerecord`. Full suite
370 tests green except 3 pre-existing snapshot fails; streaming-suite full-run flakiness fixed by
widening `waitUntil` deadline (1 s wall-clock starved under 70 parallel suites).
**Plan item (c)** — shorter cap + visible countdown — deliberately **not** done: 15 s cap +
5 s watchdog now guarantee escape; a countdown UI is scope beyond the regression. Live dead-air
verify is batched into the 54.5 live-streaming sim-confirm (needs backend + real ElevenLabs token).

## 54.6 — can't end quiz from the minimized view; not redesigned (founder #1)
**✅ FIXED 2026-06-12.** Full rewrite of `MinimizedQuizView.swift` to `Theme.Hangs.*` tokens (mono
progress, Anton score, pink mic pill, hairline divider). The 22×22 offset ✕ chip replaced by a
full-width 44 pt "End Quiz" row — large driving-context tap target, no offset hit-area loss.
**Bonus bug fixed:** `resetState()` never cleared `isMinimized`, so ending a quiz from the widget
left a stale floating card over Home. Fix: `QuizViewModel.swift:1007` now sets `isMinimized = false`
inside `resetState()`. New test: `QuizViewModelEndQuizTests.endQuizResetsMinimized`.
**Commit:** `0f1563a`. Screenshot-verified light+dark (`/tmp/hangs-54-6/`; screenshots 07/09 widget,
08 end-quiz dismissal). **Full suite after commit:** 371 tests, 368 passed; only the 3 known
pre-existing snapshot fails (HomeViewSnapshotTests.idleWithStats,
QuestionViewSnapshotTests.askingState, QuestionViewSnapshotTests.recordingState).
**Pencil sync done:** new frame `Widget/Minimized-Quiz` (id AAEkz) created in
`design/quiz-agent.pen`, matching the implementation, reusing `$bg-card/$accent-pink/$error/$font-mono/$font-display`
tokens. Known pre-existing token gap: Swift `Radius.card=18` vs design `$radius-xl=16` (frame uses 18).

**Mechanism (original):** `MinimizedQuizView.swift` was **not touched by #52** — still old `Theme.Colors.*`
(non-adaptive) + old visuals. An end-quiz control exists: a 22×22 "✕" chip top-trailing with
`.offset(x:6,y:-6)` partly off the card edge (`MinimizedQuizView.swift:98–114`) → tiny/hard to hit;
it opens an End-Quiz dialog → `viewModel.endQuiz()`.
**Original plan:** redesign MinimizedQuizView to the new design system (`Theme.Hangs.*`) and make end-quiz an
obvious, comfortably-tappable control. Verify the confirmation dialog presents from the floating
overlay. **Pencil:** add/repair the minimized-quiz frame (it currently has no redesigned design).
Overlaps with 54.1 (adaptive tokens) — do the token migration here too.

## 54.7 — onboarding "Continue" reportedly doesn't advance (founder #7)
**✅ FIXED 2026-06-12.** Repro (4/4 in sim): tapping Continue **crashed the app** (process died →
springboard), which on device reads as "doesn't advance". Crash reports: `Hangs-*.ips`, SIGTRAP in
`dispatch_assert_queue_fail` via `_swift_task_checkIsolatedSwift`, faulting frame
`closure #1 in Color.init(light:dark:)` (`Color+Theme.swift`).
**Root cause:** none of the plan's candidates — `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
(`Shared.xcconfig:35`) made the `UIColor(dynamicProvider:)` closure inferred MainActor-isolated;
iOS 26 SwiftUI resolves dynamic colors on its **async render thread** during animated transitions
(`.animation(value: viewModel.page)` → `ViewGraph.updateOutputsAsync`), so the runtime executor
check trapped before the closure body even ran. The earlier fix (`9fca8a8`) had made the closure
*body* pure but couldn't remove the inferred isolation *tag*.
**Fix:** `nonisolated` on both adaptive `Color(light:dark:)` inits + `UIColor(hex:)`, `@Sendable`
provider closures (`Color+Theme.swift`). Affects every adaptive token app-wide, not just onboarding
— any animated transition could hit this trap.
**Test (red→green):** `AdaptiveColorIsolationTests` bridges the adaptive tokens on main and resolves
them off-main (`Task.detached`) — trapped pre-fix exactly like the app, passes post-fix.
**Live verify:** replay intro → Continue → HANDS-FREE → Continue → MIC ACCESS → Maybe later → Home;
process alive at every step (screenshots /tmp/hangs-54-7/).

## Live-simulator verification (54.4 / 54.5)

**Confirmed 2026-06-12 on iPhone 17 Pro / iOS 26.5 sim** (real ElevenLabs WebSocket to
`api.elevenlabs.io`, real mic audio, local backend on :8002):
- **54.4 escalation tiers + 15 s cap + tier-3 auto-skip:** tier-1/tier-2 dead-air banners confirmed
  live; 15 s cap closes WebSocket exactly on time (app log: token from :8002 + wss to
  api.elevenlabs.io); tier-3 auto-skip fires after 3rd failure. All four escalation tiers confirmed.
- **54.5 full live ElevenLabs streaming loop:** audible speech (built-in mic + speakers) produced live
  transcript "Oj. Pravda." → auto-confirm sheet → auto-confirm timer → result screen → question 02/10,
  **no OOPS** (54.5 confirm PASSED). Real WebSocket, real mic audio, no mocks.
- **54.5 CompletionView light+dark screenshots:** live sim run completing a quiz produced
  `completion-light.png` and `completion-dark.png` at `/tmp/hangs-54-6/` — both clean renders,
  no visual bugs.

## Done criteria (per item)
- [x] Repro confirmed (or 54.7 closed as non-defect) with sim evidence. *(54.7 ✅ — crash repro 4/4 · 54.4 ✅ — code-trace, 4 holes; live dead-air check confirmed · 54.6 ✅ — sim-verified light+dark)*
- [x] Behavioural test red→green. Screenshot-verify (54.6 light+dark). *(54.7 ✅ — AdaptiveColorIsolationTests · 54.4 ✅ — streaming Tests 4–7 + service + timer tests · 54.6 ✅ — screenshots 07/09 widget, 08 end-quiz dismissal)*
- [x] Pencil synced for 54.6 minimized frame. Update parent §54.4/§54.6/§54.7. *(§54.7 ✅ · §54.4 ✅ · §54.6 ✅ — frame AAEkz created)*

<!-- obsidian-links:start -->
## Súvisiace issues
[[issue-52-design-refresh-sweep|#52 iOS design-refresh sweep]]
<!-- obsidian-links:end -->
