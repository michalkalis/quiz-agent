# Issue #68 — UX: driving-critical defaults + recording earcon + expose settings + render image questions

**Triage:** enhancement · ready-for-agent

**Created:** 2026-06-21 · **Founder:** Michal · **Source:** #64 full-project review (ranks 12, 13 + image-render — verified first-hand)

**Severity:** high — three eyes-free/driving-safety gaps in a driving-first product.

## Problem

1. **60-second default thinking time.** Auto-record waits a full minute before it fires, and the
   field isn't exposed anywhere in Settings — a driver can't shorten it without code access. This
   directly undermines the hands-free proposition.
2. **No audio earcon on recording start/stop.** The only feedback is haptic. A driver has no
   eyes-free confirmation that the mic is live (already flagged P0 in the #12 product review).
3. **Image questions render blank.** `ImageQuestionView` exists but has no caller; `QuestionView`
   dispatches only to MCQ or voice. Any served `image`-type question shows nothing.

## Evidence (verified first-hand 2026-06-21)

- `apps/ios-app/Hangs/Hangs/Models/QuizSettings.swift:71,106` — `thinkingTime` default `60`. (Options array `thinkingTimeOptions = [0,15,30,45,60,90,120]` exists at `:153` but is unused by the UI.)
- `apps/ios-app/Hangs/Hangs/Views/SettingsView.swift` — **zero** references to `thinkingTime`, `numberOfQuestions`, `autoAdvanceDelay`, `answerTimeLimit` (all configurable fields, none in the UI).
- `apps/ios-app/Hangs/Hangs/Views/QuestionView.swift:44` — `.sensoryFeedback(.start, …)` (haptic only). No `AudioServicesPlaySystemSound` / `SystemSoundID` anywhere in the Swift sources.
- `apps/ios-app/Hangs/Hangs/Views/QuestionView.swift:31-35` — body dispatches to `mcqBody` / `voiceBody` only; no `.image` branch. `ImageQuestionView.swift` has no non-Preview caller.

## Recommendation

1. Change `QuizSettings.swift:106` default `thinkingTime` `60 → 10`. Add a "Session" group to
   `SettingsView` with pickers for `numberOfQuestions`, `thinkingTime`, `autoAdvanceDelay`,
   `answerTimeLimit` (reuse the existing options arrays).
2. Play a short system sound (`AudioServicesPlaySystemSound`, e.g. 1113) on the `.recording`
   transition in `QuizViewModel+Recording.swift`, and a distinct stop sound on recording end.
3. Add a third branch in `QuestionView.body` for `question.type == .image` → `ImageQuestionView`,
   and confirm the question text is still read aloud via TTS.

## Acceptance

- [ ] `QuizSettings.default.thinkingTime == 10`; a unit test asserts `< 30`
- [ ] `SettingsView` shows pickers for `numberOfQuestions`, `thinkingTime`, `autoAdvanceDelay`, `answerTimeLimit`
- [ ] Recording start emits an **audio** cue (not only haptic) — `[HUMAN]` real-device confirm
- [ ] `QuestionView` renders `ImageQuestionView` when `question.type == .image`
- [ ] RS-01..RS-18 regression scenarios pass

## Founder decisions 2026-07-05 (pre-implementation UI approval)

Binding record: `docs/design/ui-proposals-2026-07-decisions.md` (decision 6 + globals G1–G4). Pencil frames update first via #86 — Pencil sync of approved UI; implement only after frame review.
- APPROVED as recommended: add 10s to thinkingTime options; Variant A menu rows; system sounds 1113/1114 now (unify in #77 earcon set later); recording-sounds toggle default ON. Image questions = Home-screen user option, DEFAULT OFF (fun, but not while driving).
