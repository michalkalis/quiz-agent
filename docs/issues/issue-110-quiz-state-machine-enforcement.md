# Issue 110: Quiz state-machine enforcement (driving-loop correctness bugs)

**Triage:** bug · needs-triage
**Reversibility:** a
**Status:** Created by /prepare-issue 2026-07-20 from the iOS architecture review 2026-07-18 — Top 10 item 1. Prep pipeline running on branch `arch-review-ios`.
**Created:** 2026-07-20

**Source:** [iOS architecture review 2026-07-18](../research/ios-architecture-review-2026-07-18.md) — Top 10 item 1 + dimension 3 (state management). Link, don't restate.

## Why

These are four **driving-loop correctness bugs**. The founder drives with the screen unattended and answers by voice, so a path that keeps working out-of-state doesn't just render wrong — it leaves the streaming mic live into the result, submits the wrong MCQ option, or floats a stale widget over the finished quiz with no one watching. `QuizState` already has a validated transition table (`transition(to:) -> Bool`, `QuizViewModel.swift:322`) but it is bypassed on exactly these hot paths. Four confirmed bugs, all deterministic and machine-reproducible:

1. **Error-screen "Try Again" bypasses the state machine + no single-flight** — `startNewQuiz()` ignores the rejected `error→startingQuiz` transition and runs session creation while `quizState` stays `.error`; a double-tap fires two concurrent `createSession` calls that clobber `currentSession` (`QuizViewModel.swift:555`).
2. **Skip-undo expiry commits mid-recording** — the 2.5 s undo-window expiry rechecks only `pendingSkipWindow`, never `quizState`, so speaking/tapping during the window lets expiry commit `skipQuestion()` during `.recording` — leaving the streaming mic live into the result — or fire a concurrent skip against an in-flight answer (`QuizViewModel.swift:1069`).
3. **Stale minimized overlay on finish** — `.finished` never clears `isMinimized` and nothing cancels auto-advance on minimize → CompletionView with a stale MinimizedQuizView floating on top (`QuizViewModel.swift:1379`).
4. **MCQ selection has two sources of truth** — view-local `selectedKey` vs VM `mcqVoiceMatchedKey` (local-wins): tap A then voice-match B submits B while the UI highlights A (`MCQOptionPicker.swift:44`).

## Scope

**In** — the four fixes above, each landing as a small, self-contained diff with a pinning test:

1. Bug 1: add `startingQuiz` to `.error`'s successors in `validTransitions`, `guard transition(...) else { return }` in `startNewQuiz`, and an `isStarting` single-flight flag.
2. Bug 2: guard the undo-window expiry closure on `quizState == .askingQuestion`, and cancel the `.skipUndo` task + `pendingSkipWindow` in both `startRecording` and `submitMCQAnswer`.
3. Bug 3: clear the stale minimized overlay on `.finished`.
4. Bug 4: give MCQ selection a single VM owner (drop the view-local `@State`).
5. Pinning tests for all four (seams in Research → *Test seams*).

**Out** —
- The broader ~50-free-variables restructure and the god-object decomposition → **#113 — Decompose the QuizViewModel god object** (Top 10 item 2). This issue enforces the *existing* state machine on four paths; it does not fold clusters into associated values.
- Navigation ownership (NotificationCenter → route state) → **#111 — navigation-owned state**.
- Any new UX, copy, or behavior change — these are correctness fixes; the observable happy path is unchanged.

## Resolved design decisions

> Grounded in Research (Phase 1). No founder decision needed — all five are technical correctness choices with a deterministic right answer; the two "options" the review raised (bug-3 fix site, bug-2 supersede rule) are decided below.

1. **Bug 1 — mirror the #79 single-flight pattern exactly.** Add `error → startingQuiz` to the table and `guard transition(to: .startingQuiz) else { return }` + an `isStarting` flag reset in `defer`, cloning `resubmitAnswer`'s `isSubmittingAnswer` shape (`:950/:993`). *Rationale: the rejected-transition-guard + re-entrancy-flag idiom is already proven live in `submitMCQAnswer`/`resubmitAnswer`; reusing it keeps one single-flight convention instead of inventing a second.*
2. **Bug 2 — one invariant, two enforcement points.** Invariant: *a pending skip is only ever committed while the quiz is still asking the question, and starting an answer (voice or tap) supersedes any pending skip.* Enforce by (a) guarding the expiry closure on `quizState == .askingQuestion` before it calls `skipQuestion()`, and (b) cancelling the `.skipUndo` task + clearing `pendingSkipWindow` at the top of both answer-entry paths (`startRecording`, `submitMCQAnswer`). *Rationale: the closure-only recheck of `pendingSkipWindow` is the exact hole (`:1067`); pinning the commit to the phase that legitimately owns a skip closes it, and cancelling in both entry paths stops a stale skip racing an in-flight answer.*
3. **Bug 3 — reset `isMinimized` in the VM on entering `.finished` (primary).** The view-side `ContentView.swift:121` gate (`isMinimized && canMinimize`) is defense-in-depth to add *only if trivial*, not the fix. *Rationale: state truth lives in the VM, and `endQuiz`/`resetState` already own the `isMinimized` reset (54.6 precedent, `QuizViewModelTests.swift:1095`) — resetting on `.finished` matches that precedent and fixes the source, not the symptom; the view gate alone would leave `isMinimized` lying `true` for any other observer.*
4. **Bug 4 — the VM key is the single owner; tap writes it through a binding.** Drop `MCQOptionPicker`'s local `@State selectedKey`, make `externalSelectedKey` a `Binding`, and have the tap path set the *same* variable the voice path submits from (`mcqVoiceMatchedKey`) — so voice-match and tap converge on one value and the highlight can never disagree with what is submitted. *Rationale: the bug is precisely two sources of truth with local-wins (`:44`); collapsing to one owner is the only fix that removes the divergence rather than re-ordering it.*
5. **`transition(to:)` is already `@discardableResult` (`:321`) — leave it in place; only the four edited sites branch on the returned `Bool`.** Removing the attribute now would force auditing every existing call site that legitimately drops the result and would raise unused-result warnings across dozens of them — that repo-wide sweep is the god-object decomposition and belongs to **#113 — Decompose the QuizViewModel god object**, not here. So this issue keeps the attribute and only makes the sites it actually edits (`startNewQuiz`, plus the skip/MCQ entry paths where relevant) branch on the `Bool`, per the target-arch rule *"every caller handles a rejected transition"*. Bug 1 compiles silently today *because* the attribute is present and `startNewQuiz` drops the result; adding the explicit `guard transition(...) else { return }` at the edited site is what closes it, independent of the attribute. *Rationale: correcting only the edited call sites is the minimal, independently-committable fix; the full "every caller handles a rejected transition" audit is the #113 sweep and must not be pulled forward here.*

**Second-order lens.** These four fixes harden the exact seams #113 will later extract (recording/skip single-flight, minimize lifecycle, MCQ selection ownership). They must therefore land as small, independently-committable, test-pinned diffs so #113 rebases cleanly on top — no opportunistic restructuring here that #113 would then have to re-untangle.

## Research (Phase 1, 2026-07-20)

**Anchor drift: none.** All four cited anchors are exact on this branch.

**State machine.** `QuizState` enum, `validTransitions` table, `transition(to:caller:) -> Bool` all in `QuizViewModel.swift:22 / :83 / :322`. `transition` guards on `validTransitions.contains(to)`, logs + returns `false` on reject, and only on success clears `mcqVoiceMatchedKey` when entering `.askingQuestion` (`:333`). It is already `@discardableResult` (`:321`), so most call sites drop the result silently (this is why bug 1 compiles) — see decision 5 for why the attribute stays. Single-flight precedent to adopt: #79 `submissionEpoch` (`:369-385`) + rejected-`.processing`-abort — `submitMCQAnswer` uses `guard transition(to: .processing) else { return }` (`:931`); `resubmitAnswer` adds `isSubmittingAnswer` flag (`:950`) + same guard (`:993`); skip/MCQ bump the epoch before their first await.

**Bug 1 (`:555`).** `startNewQuiz` calls `transition(to: .startingQuiz)` and ignores the result; `error→startingQuiz` is NOT in the table (`.error → ["idle","askingQuestion"]`, `:93`), so Try-Again runs the whole flow while `quizState` stays `.error`. No `isStarting` flag exists (re-entrancy guards `:361-385`). `createSession` overwrites `currentSession` at `:608/:617`. Fix = add `startingQuiz` to `.error` successors + `guard transition(...) else { return }` + `isStarting` flag mirroring `isSubmittingAnswer`.

**Bug 2 (`:1069`).** Expiry closure (`:1064-1070`) rechecks only `pendingSkipWindow != nil` (`:1067`), never `quizState`; `skipQuestion` (`:1016`) legally goes `.recording/.processing → .skipping` (`:88/:89`) and never tears down the streaming mic. `beginSkipUndoWindow(duration:)` is armed only from CommandListener (`:185`); neither `startRecording` (+Recording `:33`) nor `submitMCQAnswer` cancels the window. Fix = guard expiry on `quizState == .askingQuestion` + cancel `.skipUndo`/`pendingSkipWindow` in both entry paths.

**Bug 3 (`:1379`).** `transition(to: .finished)` never clears `isMinimized` (reset lives only in resetState `:1463` / endQuiz). `canMinimize` (`:292`) already excludes `.finished`, but ContentView's floating overlay (`ContentView.swift:121`) gates on `isMinimized` ALONE, not `canMinimize` → widget floats over CompletionView. Two fixes (planner picks one): reset `isMinimized` on `.finished`, or gate `:121` on `isMinimized && canMinimize`. Direct precedent: 54.6 `endQuiz` resets `isMinimized` (`QuizViewModelTests.swift:1095`).

**Bug 4 (`MCQOptionPicker.swift:44`).** `effectiveSelectedKey = selectedKey ?? externalSelectedKey` (local-wins). VM sets `mcqVoiceMatchedKey` (+Recording `:246`) then submits directly (`:253`); QuestionView (`:338`) feeds it as `externalSelectedKey`. Tap A sets `@State selectedKey = A`, then voice B submits + cancels the pending tap (`:72`) but highlight stays A. Fix = VM single owner: drop `@State selectedKey`, tap sets the VM key (make `externalSelectedKey` a binding). Tap path currently does NOT set `mcqVoiceMatchedKey`.

**Test seams** (HangsTests: Swift Testing + ViewInspector + ConcurrencyExtras `withMainSerialExecutor`). VM built via `Fixtures.makeViewModelWithNetwork()` or explicit init with `Mock{Network,Audio,Persistence,STT}`; `quizState` is directly settable, `beginSkipUndoWindow(duration:)` is injectable, mocks expose `*CallCount` (`submitTextInputCallCount` exists; add `createSessionCallCount` for the double-tap assert). Extend: `QuizViewModelTests` (startNewQuiz transition/error `:338/:351`, isMinimized `:1095`) · `QuizViewModelSubmissionRaceTests` (#79 single-flight) · `SkipCancelWordTests` (undo-window expiry `:99`) · `MCQOptionPickerRaceTests` + hosted picker wiring · `ScreenAwakeControllerTests` (`.finished`+minimized).

**Build-vs-adopt: adopt in-repo, no external library** — this is internal state-machine enforcement; precedent is the #79 `submissionEpoch` + rejected-transition-guard single-flight already live in `submitMCQAnswer`/`resubmitAnswer`.

**Web pass skipped:** purely internal SwiftUI/state-machine invariants; no genuine external unknown.

**Product question: none** — all four are deterministic correctness fixes; bug-3's two fix options and bug-2's "an answer supersedes a pending skip" are technical choices, not UX/scope.

## Prep progress

> *Maintained by `/prepare-issue` — durable record of where prep is; safe to resume from a fresh session.*

| Phase | State | Latest gate verdict |
|-------|-------|---------------------|
| 1 · Research          | ✅ done | — |
| 2 · Plan              | ✅ done | — |
| 3 · Plan review       | ⬜ pending | ready-check — · design-soundness — |
| 4 · Impl-plan         | ⬜ pending | — |
| 5 · Impl-plan review  | ⬜ pending | ready-check — · design-soundness — |
| 6 · Split             | ⬜ pending | — |

**Last updated:** 2026-07-20 12:05 · **Next:** Phase 3 (dual gate: ready-check · design-soundness) · **Gate attempts:** P3 0/3 · P5 0/3
