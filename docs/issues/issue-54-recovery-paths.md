# Plan 54.17 + 54.18 — broken recovery paths (UI entry points removed, VM still expects them)

**Parent:** `issue-54-design-refresh-regressions.md` (§54.17, §54.18) · **Priority:** P1
**Status:** ready · **Found:** 2026-06-12 second review pass (gap-hunt) — not founder-reported
**Type:** the #52 redesign removed UI entry points while the ViewModel (untouched by the branch)
still supports — and in one case actively *directs users to* — the removed UI. Both are
"dead-end state" bugs: a user can reach a state with no actionable way out.

---

## 54.17 — Settings "Reset question history" removed; VM error directs users to it
**Mechanism:** `QuizViewModel.swift:370–374` — the startup guard checks
`persistenceStore.isAtCapacity` (500-question cap) and surfaces
*"Question history is full. Please reset your history in Settings to continue."*
The #52 Settings redesign (52.9, Pencil frame `Jjcs5`) **removed the "Clear question history"
row** — the instruction points at UI that no longer exists. A user at the cap is permanently
locked out. `resetQuestionHistory()` and `questionHistoryCount` remain on the VM and
`PersistenceStoreProtocol`; only the UI entry point is gone. **Confidence: high.**

**Fix approach (pick one, lean (a)):**
(a) add a "Reset question history" row back to SettingsView (e.g. in the about/danger group),
keeping the new design language; or (b) put a direct reset CTA on the error itself
(`AppErrorModel` action) and reword the copy. Either way the copy must be SK-first (see 54.15).
**Test:** inspector test that the row exists and calls `resetQuestionHistory()`; VM test that
the at-capacity error's recovery action is actually reachable.

## 54.18 — Onboarding promises typed answers; the TextField was removed from QuestionView
**Mechanism:** two subtitle strings added by 52.13 promise a keyboard fallback —
`OnboardingView.swift:99` ("You can also type answers as a fallback.") and `:119`
("Turn it on in Settings, or keep playing by typing your answers."). The "Type answers
instead" CTA (`OnboardingView.swift:275` → `continueWithoutMic()`) finishes onboarding. But the
52.10 QuestionView redesign **removed the TextField + submit button** (not in the Pencil frame).
A mic-denied user reaches the quiz and **cannot answer voice/open questions at all** (MCQ still
works via tap; voice questions offer only Skip). The VM's `submitTextInput` path still exists —
no View calls it. **Confidence: high.**

**Founder decision needed (product call):** restore a typed-answer input on the voice question
screen (recommended — it's the accessibility/no-mic path and the VM already supports it), or
drop the no-mic mode entirely (remove the onboarding promise + CTA, require mic). Don't silently
pick — the app is voice-first by vision, but onboarding currently *offers* the no-mic path.

**Fix approach once decided:** (restore) add a minimal typed-input affordance to `voiceBody`
wired to `submitTextInput`, mirror it in the Pencil voice frames (`f9csl`/`uGhZg`), coordinate
with 54.2's layout work so it's done in one QuestionView pass; (drop) delete the two onboarding
strings + the "Type answers instead" CTA and make the denied page require mic to proceed.
**Test:** (restore) behavioural — mic-denied launch can submit a typed answer and reach the
result screen; (drop) onboarding denied page shows no typed-answer promise.

## Pencil 1:1 sync
Whichever option lands changes Settings and/or the voice-question + onboarding frames — batch
with `issue-54-pencil-snapshot-sync.md`.

## Done criteria
- [ ] 54.17: reset-history path reachable again (test green); SK copy.
- [ ] 54.18: founder decision recorded here, then implemented + behavioural test.
- [ ] Pencil frames updated. Update parent §54.17/§54.18.
