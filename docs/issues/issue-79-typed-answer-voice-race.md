# Issue #79 — Bug: typed answer during live voice capture → double submission + stale voice confirmation sheet

**Triage:** bug · needs-triage (draft from UI/UX review 2026-07-03)

**Created:** 2026-07-03 · **Founder:** Michal · **Source:** UI/UX review 2026-07-03 (reproduced on sim under `--ui-test`; race code-verified as production-reachable)

**Severity:** high — two answers can hit the backend for one question; user sees a confirmation sheet with the *voice* transcript after submitting a *typed* answer.

## Problem

The typed-answer path and the committed-voice-transcript path both mutate the same submission state
and are not mutually exclusive across their `await` suspension points (both `@MainActor`, but they
interleave). If the user submits a typed answer while auto-record/streaming STT is live and a
transcript commit is in flight, the typed submit goes out, then the voice handler resumes and
re-raises the confirmation sheet populated with the **voice** transcript — nothing dismisses it.
On the MCQ path the voice handler even submits directly, i.e. a **second concurrent network
submission** for the same question.

The "stuck quiz / repeating question / streak climbing while score frozen" symptom observed on the
sim is **mock-only** (`MockNetworkService` returns a static response — see Evidence), but the race
itself is live in production: auto-record + streaming STT are the default on iOS 26
(`Config.useElevenLabsSTT = true`, `Config.swift:126`). Real-world impact depends on backend
idempotency for a second input on an already-answered question — plus the guaranteed stale-sheet UX bug.

## Evidence (code-verified 2026-07-03)

- Typed path: `QuestionView.submitTypedAnswer()` (`QuestionView.swift:477-483`) → `QuizViewModel.resubmitAnswer()` (`QuizViewModel.swift:626-672`): tears down recording only `if quizState == .recording` (`:638`), transitions to `.processing` (`:651`), `await submitTextInput` (`:659`) — and **never sets `showAnswerConfirmation = false`**.
- Voice path: `handleCommittedTranscript()` (`QuizViewModel+Recording.swift:173-224`): first suspension is `await sttService?.disconnect()` (`:186`) while state is still `.recording`; its tail **unconditionally** sets `transcribedAnswer` + `showAnswerConfirmation = true` (`:219-220`); MCQ branch submits directly via `submitMCQAnswer` (`:214`).
- `isProcessingResponse` guard (`QuizViewModel.swift:837-842`) dedupes only `handleQuizResponse`, not the two `submitTextInput` network calls.
- The state machine already *sees* the collision: second submit logs "❌ REJECTED transition: processing → processing" (`QuizViewModel.swift:89`, `:610`) but the return value is ignored and the call proceeds.
- Mock-artifact explanation of the sim "stuck loop": `MockNetworkService.submitTextInput` ignores input and always returns static `previewAnswerCorrect` (`MockNetworkService.swift:69-84`; fixture `QuizResponse.swift:142-180`) → same question re-served, `questionsAnswered` pinned at 1, while local `quizStats.recordAnswer` (`QuizViewModel.swift:886-889`) keeps incrementing the streak.
- Related display split (fix alongside): `ResultView.counterString` uses raw `questionsAnswered` ("01/10") while `QuestionView.counterString` uses `questionsAnswered + 1` ("02/10") — `ResultView.swift:307-308` vs `QuestionView.swift:96-100`.

## Recommendation

Single-flight submission per question: a submission token/epoch owned by the ViewModel — starting a
typed submit invalidates any in-flight committed-transcript continuation (check the epoch after every
`await`), dismisses the confirmation sheet, and hard-stops recording regardless of `quizState`.
Honor the rejected `processing → processing` transition (bail instead of proceeding). Add an
interleaving unit test (typed submit racing a committed transcript).

Cross-refs: #67 Part A (streaming interruption teardown — same recording-teardown surface), #59 (quiz-flow bug cluster).

## Acceptance

- [ ] Typed submit while recording/transcript-commit in flight → exactly **one** backend submission
- [ ] Confirmation sheet never appears with the voice transcript after a typed submit (and is dismissed if already up)
- [ ] Rejected state transitions abort the caller path (no proceed-after-reject)
- [ ] Unit test covering the interleaving (typed submit during suspended `handleCommittedTranscript`)
- [ ] Result header and question header agree on the question counter
- [ ] Existing RS regression scenarios pass

## Founder decisions 2026-07-05 (pre-implementation UI approval)

Binding record: `docs/design/ui-proposals-2026-07-decisions.md` (decision 12 + globals G1–G4). Pencil frames update first via #86 — Pencil sync of approved UI; implement only after frame review.
- APPROVED as recommended. Added context: on the voice-answer confirmation screen, tapping the answer text opens the keyboard for manual transcript editing — the fix must preserve this flow.
