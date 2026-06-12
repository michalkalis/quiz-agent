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
**Mechanism:** silence auto-stop (`startSilenceDetection`, `+Recording.swift:203`) only fires on
`.silenceAfterSpeech` — it **requires speech first**. No speech → no silence event → no stop. The
only net is the hard cap `startAutoStopRecordingTimer()` (`+Timers.swift:119`) =
`Config.autoRecordingDuration` (**15 s**), and it's gated `guard !isRerecording` (`:120`) so it's
skipped on re-record.
**Plan:** (a) confirm in-sim that 15 s dead air really fails to stop; (b) ensure the hard cap fires
on the **streaming-STT no-speech path** (and on re-record); (c) consider a shorter no-speech cap +
a visible countdown so the cap is legible. **Test:** VM/integration test that with no speech the
recording transitions out of `.recording` within the cap.

## 54.6 — can't end quiz from the minimized view; not redesigned (founder #1)
**Mechanism:** `MinimizedQuizView.swift` was **not touched by #52** — still old `Theme.Colors.*`
(non-adaptive) + old visuals. An end-quiz control exists: a 22×22 "✕" chip top-trailing with
`.offset(x:6,y:-6)` partly off the card edge (`MinimizedQuizView.swift:98–114`) → tiny/hard to hit;
it opens an End-Quiz dialog → `viewModel.endQuiz()`.
**Plan:** redesign MinimizedQuizView to the new design system (`Theme.Hangs.*`) and make end-quiz an
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

## Done criteria (per item)
- [ ] Repro confirmed (or 54.7 closed as non-defect) with sim evidence. *(54.7 ✅ — crash repro 4/4)*
- [ ] Behavioural test red→green. Screenshot-verify (54.6 light+dark). *(54.7 ✅ — AdaptiveColorIsolationTests)*
- [ ] Pencil synced for 54.6 minimized frame. Update parent §54.4/§54.6/§54.7. *(§54.7 ✅)*
