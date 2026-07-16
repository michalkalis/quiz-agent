# Issue #79 — Bug: typed answer during live voice capture → double submission + stale voice confirmation sheet

**Triage:** bug · fixed 2026-07-16 — branch `worktree-issue-79-typed-voice-race` (`4254fdb`), merge to main pending; see Resolution

**Note (2026-07-06):** Line anchors may be stale — 77.2 refactored the interruption teardown into `AudioService.interruptionTeardown(...)`; re-verify anchors before implementing.

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

- [x] Typed submit while recording/transcript-commit in flight → exactly **one** backend submission (race tests a+b, verified failing pre-fix)
- [x] Confirmation sheet never appears with the voice transcript after a typed submit (and is dismissed if already up) (tests a+c)
- [x] Rejected state transitions abort the caller path — on the submission paths (`submitMCQAnswer`, `resubmitAnswer`); other transition call sites unchanged, out of scope
- [x] Unit test covering the interleaving (4 tests in `QuizViewModelSubmissionRaceTests`, gated suspendable mock `disconnect()`)
- [x] Result header and question header agree on the question counter — verified they **already agree** (pre/post-increment phases); documented with cross-referencing comments, no logic change; the sim mismatch is the mock fixture pinning `answeredCount: 1`
- [~] Existing RS regression scenarios pass — covered here by targeted suites (23/23) + sim smoke (typed / MCQ / next-question); **full RS run deferred to the #48 pre-release gauntlet**

## Resolution (2026-07-16)

Fixed on branch `worktree-issue-79-typed-voice-race` (`4254fdb`); merge to main pending (#91 session had the main checkout busy). Recon re-verified all anchors first (plan's were stale; the 77.2 teardown refactor turned out unrelated to this race).

Mechanism: monotonic `submissionEpoch` on `QuizViewModel`, bumped before the first `await` of every submission path (`resubmitAnswer` / `submitMCQAnswer` / `skipQuestion`). `handleCommittedTranscript` snapshots it after its `.recording` entry guard and aborts after its only pre-branch suspension point (`await sttService?.disconnect()`) if it moved — both the MCQ direct-submit branch and the free-text confirmation tail become unreachable once superseded. `resubmitAnswer` additionally (pre-await): dismisses the sheet, cancels auto-confirm + `.sttEvent`, tears down streaming STT regardless of `quizState`, and dedupes double-fire entry (`isSubmittingAnswer`); rejected `.processing` transitions abort (confirmAnswer's already-`.processing` dual-entry preserved). Tap-to-edit flow untouched and re-verified.

Verification: 23/23 targeted tests (new `QuizViewModelSubmissionRaceTests` ×4 + resubmit + streaming + MCQ voice); both new race tests reproduce the bug on unfixed code (double submission with voice answer winning / stale sheet with clobbered transcript). Adversarial reviews (race-correctness, regression/conventions): ship, no blockers. Sim smoke: typed, MCQ and next-question flows PASS; counter consistent.

## Founder decisions 2026-07-05 (pre-implementation UI approval)

Binding record: `docs/design/ui-proposals-2026-07-decisions.md` (decision 12). Not on the #86 gate list — no new UI here, not blocked on Pencil sync.
- APPROVED as recommended. Added context: on the voice-answer confirmation screen, tapping the answer text opens the keyboard for manual transcript editing — the fix must preserve this flow.
