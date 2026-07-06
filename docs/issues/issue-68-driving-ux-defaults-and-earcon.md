# Issue #68 — UX: driving-critical defaults + recording earcon + expose settings + render image questions

**Triage:** enhancement · implementing 2026-07-06 (#86 design gate lifted)

**Status (2026-07-06, implementation session):** Earcon acceptance item was delivered by #77 task 77.10 (ede204e). This session implements the rest per founder decision 6 + Pencil frames (Settings `Jjcs5` sessionWrap/audioWrap, Home `rJ7dB` configCard row4):
- iOS: `thinkingTime` default 60→10 (+10s option, decode fallback tracks product default), Settings "session" group (4 menu rows), "Recording sounds" toggle (default ON, gates only mic-live/got-it — command/skip cues stay), Home "Image questions" toggle (default OFF) riding `include_images` on create-session, image block rendered in the voice-body hero via restyled `ImageQuestionView` (Theme.Hangs), dead duplicate options arrays removed from `Config.swift`.
- Backend: `include_images` on `CreateSessionRequest` + shared `QuizSession` (default False), retriever admits `image` type only on opt-in (primary + all 3 fallbacks). OpenAPI verified. 295 backend tests green.
- In-quiz settings chip resolution: keeps opening full Settings (now with the session group) — #86 approved the session card on the Settings screen only; no separate in-quiz menu frame exists.

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

- [x] `QuizSettings.default.thinkingTime == 10`; a unit test asserts `< 30` (`defaultThinkingTimeIsDrivingShort`). Decode fallback also 10. NB: a previously-persisted settings blob keeps its stored 60 — the new Settings row is the user's lever; no silent migration of a stored value.
- [x] `SettingsView` shows pickers for `numberOfQuestions`, `thinkingTime`, `autoAdvanceDelay`, `answerTimeLimit` — "session" group, Menu rows per frame `Jjcs5`; on-sim verified (menu opens, 10s selectable, value persists)
- [x] Recording start emits an **audio** cue (not only haptic) — delivered via #77 task 77.10 (ede204e); this session added the "Recording sounds" toggle (default ON, gates only mic-live/got-it; command/skip cues stay — driving-safety feedback), unit-tested
- [x] `QuestionView` renders `ImageQuestionView` when `question.type == .image` — image block in the voice-body hero (scrolls with the text), restyled to Theme.Hangs; ViewInspector tests both ways (image renders / absent for plain voice)
- [x] Home "Image questions" toggle (decision 6), default OFF, rides `include_images` on create-session; backend retriever admits `image` only on opt-in (primary + 3 fallbacks, 5 new backend tests). ⚠ Whether approved `image`-type rows exist in prod pgvector is UNVERIFIED — opt-in may serve nothing until image questions are generated/imported.
- [ ] RS-01..RS-18 regression scenarios pass — NOT re-run this session (529 HangsTests + on-sim visual/interaction verify done instead; all RS a11y identifiers preserved). Run `/regression` before the next TestFlight if desired.

## Founder decisions 2026-07-05 (pre-implementation UI approval)

Binding record: `docs/design/ui-proposals-2026-07-decisions.md` (decision 6 + globals G1–G4). Pencil frames update first via #86 — Pencil sync of approved UI; implement only after frame review.
- APPROVED as recommended: add 10s to thinkingTime options; Variant A menu rows; system sounds 1113/1114 now (unify in #77 earcon set later); recording-sounds toggle default ON. Image questions = Home-screen user option, DEFAULT OFF (fun, but not while driving).
