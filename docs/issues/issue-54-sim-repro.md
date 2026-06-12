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
**Confidence: LOW — reproduce first.** The wiring *looks* correct: `OnboardingView.swift:238`
"Continue" → `viewModel.advance()`; `OnboardingViewModel.advance()` (`:46`) steps
welcome→features→permission and is unit-tested. Candidates to check in-sim: (a) `HangsPrimaryButton`
tap target / an overlay swallowing taps; (b) the secondary "Skip" (`continueWithoutMic()` → finishes
onboarding) mistaken for "next"; (c) the root `.animation(value: viewModel.page)` interfering.
**Plan:** repro in-sim → if confirmed, locate via the candidates → fix + a UI test that taps Continue
and asserts the page advances. If **not** reproducible, close 54.7 as not-a-defect with a note.

## Done criteria (per item)
- [ ] Repro confirmed (or 54.7 closed as non-defect) with sim evidence.
- [ ] Behavioural test red→green. Screenshot-verify (54.6 light+dark).
- [ ] Pencil synced for 54.6 minimized frame. Update parent §54.4/§54.6/§54.7.
