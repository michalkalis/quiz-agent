# Issue 110: Quiz state-machine enforcement (driving-loop correctness bugs)

**Triage:** bug · ready-for-agent
**Reversibility:** a
**Status:** Prep complete 2026-07-20 — all 6 prep phases ✅, both final gates green (impl-plan ready-check READY · design-soundness SOUND 0.90), class `a`, `bug · ready-for-agent`; **P1, top priority of the arch-review batch** (real driving-loop correctness bugs + the already-broken "Play Again" CTA).
**Created:** 2026-07-20

**Source:** [iOS architecture review 2026-07-18](../research/ios-architecture-review-2026-07-18.md) — Top 10 item 1 + dimension 3 (state management). Link, don't restate.

## Why

These are four **driving-loop correctness bugs**. The founder drives with the screen unattended and answers by voice, so a path that keeps working out-of-state doesn't just render wrong — it leaves the streaming mic live into the result, submits the wrong MCQ option, or floats a stale widget over the finished quiz with no one watching. `QuizState` already has a validated transition table (`transition(to:) -> Bool`, `QuizViewModel.swift:322`) but it is bypassed on exactly these hot paths. Four confirmed bugs, all deterministic and machine-reproducible:

1. **Error-screen "Try Again" bypasses the state machine + no single-flight** — `startNewQuiz()` ignores the rejected `error→startingQuiz` transition and runs session creation while `quizState` stays `.error`; a double-tap fires two concurrent `createSession` calls that clobber `currentSession` (`QuizViewModel.swift:555`). **Verified at the final gate — "Play Again" is already broken in prod today:** from `.finished`, both `finished→startingQuiz` (`:555`) and the later `finished→askingQuestion` (`:619`) reject (`.finished → ["idle"]` only), so a tap spins up a background `createSession` while the UI stays frozen on CompletionView. The fix is what makes the CTA actually work.
2. **Skip-undo expiry commits mid-recording** — the 2.5 s undo-window expiry rechecks only `pendingSkipWindow`, never `quizState`, so speaking/tapping during the window lets expiry commit `skipQuestion()` during `.recording` — leaving the streaming mic live into the result — or fire a concurrent skip against an in-flight answer (`QuizViewModel.swift:1069`).
3. **Stale minimized overlay on finish** — `.finished` never clears `isMinimized` and nothing cancels auto-advance on minimize → CompletionView with a stale MinimizedQuizView floating on top (`QuizViewModel.swift:1379`).
4. **MCQ selection has two sources of truth** — view-local `selectedKey` vs VM `mcqVoiceMatchedKey` (local-wins): tap A then voice-match B submits B while the UI highlights A (`MCQOptionPicker.swift:44`).

## Scope

**In** — the four fixes above, each landing as a small, self-contained diff with a pinning test:

1. Bug 1: add `startingQuiz` to **both** `.error`'s and `.finished`'s successors in `validTransitions` (legal-origin set {`.idle`, `.error`, `.finished`} per the call-site audit in Research), `guard transition(...) else { return }` at `startNewQuiz` entry, and an `isStarting` single-flight flag.
2. Bug 2: guard the undo-window expiry closure on `quizState == .askingQuestion`, and cancel the `.skipUndo` task + `pendingSkipWindow` in both `startRecording` and `submitMCQAnswer`.
3. Bug 3: clear the stale minimized overlay on `.finished`.
4. Bug 4: give MCQ selection a single VM owner (drop the view-local `@State`).
5. Pinning tests for all four (seams in Research → *Test seams*). **Bug 1 must pin all four origin cases:** "Try Again" from `.error` (→ `.startingQuiz` → `.askingQuestion`), "Play Again" from `.finished` (→ `.startingQuiz` → `.askingQuestion`), a double-tap single-flight (two concurrent `startNewQuiz` → `createSessionCallCount == 1`), and a rejected-origin no-op (`startNewQuiz` from an active state, e.g. `.recording`, leaves `quizState` unchanged and `createSessionCallCount == 0`).

**Out** —
- The broader ~50-free-variables restructure and the god-object decomposition → **#113 — Decompose the QuizViewModel god object** (Top 10 item 2). This issue enforces the *existing* state machine on four paths; it does not fold clusters into associated values.
- Navigation ownership (NotificationCenter → route state) → **#111 — navigation-owned state**.
- Any new UX, copy, or behavior change — these are correctness fixes; the observable happy path is unchanged.

## Resolved design decisions

> Grounded in Research (Phase 1). No founder decision needed — all five are technical correctness choices with a deterministic right answer; the two "options" the review raised (bug-3 fix site, bug-2 supersede rule) are decided below.

1. **Bug 1 — mirror the #79 single-flight pattern, whitelisting every terminal origin.** The call-site audit (Research → *`startNewQuiz` call-site origin audit*) fixes the legal origin set at **{`.idle`, `.error`, `.finished`}**. `.idle` already lists `startingQuiz`; add `startingQuiz` to **both** `.error`'s **and** `.finished`'s successors so "Try Again" (`.error`) and "Play Again" (`.finished`, `CompletionView:177`) both pass the guard. The guard stays at **`startNewQuiz` function entry** — it is the single choke point all eight call sites funnel through, so one `guard transition(to: .startingQuiz) else { return }` there covers every caller — plus an `isStarting` flag reset in `defer`, cloning `resubmitAnswer`'s `isSubmittingAnswer` shape (`:950/:993`), unchanged. **Invariant:** *`startNewQuiz` is legal exactly from {`.idle`, `.error`, `.finished`}; from any other (active mid-quiz) origin the entry guard turns it into a logged no-op* — deliberately, e.g. an accidental "Start Quiz" tap on the minimized-background HomeView must not clobber a live session. *Rationale: keeping the guard at entry is right only once the table admits every legal origin — the cycle-1 plan whitelisted `.error` alone, which would have made "Play Again" a silently-dead CTA (guard rejects `.finished → startingQuiz`, returns). The audit closes that by promoting the whitelist to the full terminal-origin set; the rejected-transition-guard + re-entrancy-flag idiom is otherwise already proven live in `submitMCQAnswer`/`resubmitAnswer`, so reusing it keeps one single-flight convention instead of inventing a second.*
2. **Bug 2 — one invariant, two enforcement points.** Invariant: *a pending skip is only ever committed while the quiz is still asking the question, and starting an answer (voice or tap) supersedes any pending skip.* Enforce by (a) guarding the expiry closure on `quizState == .askingQuestion` before it calls `skipQuestion()`, and (b) cancelling the `.skipUndo` task + clearing `pendingSkipWindow` at the top of both answer-entry paths (`startRecording`, `submitMCQAnswer`). *Rationale: the closure-only recheck of `pendingSkipWindow` is the exact hole (`:1067`); pinning the commit to the phase that legitimately owns a skip closes it, and cancelling in both entry paths stops a stale skip racing an in-flight answer.*
3. **Bug 3 — reset `isMinimized` in the VM on entering `.finished` (primary).** The view-side `ContentView.swift:121` gate (`isMinimized && canMinimize`) is defense-in-depth to add *only if trivial*, not the fix. *Rationale: state truth lives in the VM, and `endQuiz`/`resetState` already own the `isMinimized` reset (54.6 precedent, `QuizViewModelTests.swift:1095`) — resetting on `.finished` matches that precedent and fixes the source, not the symptom; the view gate alone would leave `isMinimized` lying `true` for any other observer.*
4. **Bug 4 — the VM key is the single owner; tap writes it through a binding.** Drop `MCQOptionPicker`'s local `@State selectedKey`, make `externalSelectedKey` a `Binding`, and have the tap path set the *same* variable the voice path submits from (`mcqVoiceMatchedKey`) — so voice-match and tap converge on one value and the highlight can never disagree with what is submitted. **Cancel-semantics constraint:** once the tap writes the bound VM key, the existing 54.16 `onChange(of: externalSelectedKey) → pendingSubmit.cancel()` (`:70-72`) would fire on the tap's *own* echo and cancel its own pending submit. So the submission path — not only the highlight — must converge on the single owner: rework `onChange` to distinguish an *other-source supersede* (voice overriding a pending tap → cancel) from a *self echo* (the tap that just set the key → do not cancel), e.g. by cancelling only when the incoming key differs from the tap's own in-flight target. *Rationale: the bug is precisely two sources of truth with local-wins (`:44`); collapsing to one owner is the only fix that removes the divergence rather than re-ordering it — but the collapse must carry the cancel logic with it, or it just relocates the race.*
5. **`transition(to:)` is already `@discardableResult` (`:321`) — leave it in place; only the four edited sites branch on the returned `Bool`.** Removing the attribute now would force auditing every existing call site that legitimately drops the result and would raise unused-result warnings across dozens of them — that repo-wide sweep is the god-object decomposition and belongs to **#113 — Decompose the QuizViewModel god object**, not here. So this issue keeps the attribute and only makes the sites it actually edits (`startNewQuiz`, plus the skip/MCQ entry paths where relevant) branch on the `Bool`, per the target-arch rule *"every caller handles a rejected transition"*. Bug 1 compiles silently today *because* the attribute is present and `startNewQuiz` drops the result; adding the explicit `guard transition(...) else { return }` at the edited site is what closes it, independent of the attribute. *Rationale: correcting only the edited call sites is the minimal, independently-committable fix; the full "every caller handles a rejected transition" audit is the #113 sweep and must not be pulled forward here.*

**Second-order lens.** These four fixes harden the exact seams #113 will later extract (recording/skip single-flight, minimize lifecycle, MCQ selection ownership). They must therefore land as small, independently-committable, test-pinned diffs so #113 rebases cleanly on top — no opportunistic restructuring here that #113 would then have to re-untangle.

## Tasks (atomic)

> One bug = one independently-committable diff + its pinning tests (small-diffs-for-#113 rule, Second-order lens). T1–T4 land in any order; T5 last. **No task adds a `@Published`** — `isStarting` is a plain `var` mirroring `isSubmittingAnswer` (`:382`, not published), and `isMinimized` (`:154`) already exists — so no snapshot re-record (see Acceptance).
>
> **Single session — no execution-prompts file** (split-issue step 2): four small class-`a` bug fixes + one verification tail = one cohesive iOS layer, a handful of files, one build/test run — under a single context budget. Per the skill's criterion this does **not** warrant an `issue-110-execution-prompts.md`; the atomic list below is the unit an autonomous session consumes.

- [ ] **T1 — Bug 1: terminal-origin whitelist + entry guard + `isStarting` single-flight** (decision 1)
  - Table: add `"startingQuiz"` to `.finished`'s successors (`:92` → `["idle","startingQuiz"]`) **and** `.error`'s (`:93` → `["idle","askingQuestion","startingQuiz"]`).
  - Guard: at `startNewQuiz` entry (`:549`) replace the result-dropping `transition(to: .startingQuiz)` (`:555`) with `guard transition(to: .startingQuiz) else { return }`.
  - Single-flight: add plain `var isStarting`; `guard !isStarting else { return }` **before** the transition attempt (so a double-tap short-circuits without logging a spurious rejected-transition), then set true + reset in `defer` — cloning `isSubmittingAnswer` shape (`:950/:993`).
  - Mock: add `createSessionCallCount` to MockNetworkService, mirroring `submitTextInputCallCount`.
  - Tests → `QuizViewModelTests` (see Acceptance for the four origin cases).
  - *Accepted test thinness (Gate B note 1):* the double-tap test asserts `createSessionCallCount == 1` but does **not** also assert the second tap emits no rejected-transition log. A rejected transition is `Logger.quiz.error` (OSLog) only — there is **no** Sentry breadcrumb on the reject path (breadcrumb fires only after a *successful* transition, `:335`) — and HangsTests has no log-capture seam. Adding one would be a new observability hook (a goalpost move) for zero extra behavioral coverage: `createSessionCallCount == 1` already proves single-flight, and the `!isStarting`-before-`transition` ordering that avoids the spurious log is pinned by construction (decision 1). Accepted as-is.

- [ ] **T2 — Bug 2: pin skip-commit to `.askingQuestion` (primary) + cancel on answer entry (cleanup)** (decision 2)
  - Primary invariant: guard the undo-window expiry closure (`:1064-1070`; the recheck at `:1067`) on `quizState == .askingQuestion` before it calls `skipQuestion()`.
  - Cleanup: cancel the `.skipUndo` task + clear `pendingSkipWindow` at the top of **both** `startRecording` (+Recording `:33`) and `submitMCQAnswer`.
  - Tests → `SkipCancelWordTests` (expiry seam `:99`).

- [ ] **T3 — Bug 3: reset `isMinimized` on entering `.finished`** (decision 3)
  - Primary: set `isMinimized = false` at the `transition(to: .finished)` site (`:1379`), matching the `endQuiz`/`resetState` precedent (`:1463`).
  - Optional (only if trivial): also gate ContentView's floating overlay (`:121`) on `isMinimized && canMinimize` — defense-in-depth, not the fix.
  - Test → `QuizViewModelTests`, mirroring `endQuizResetsMinimized` (`:1095`).

- [ ] **T4 — Bug 4: single VM owner for MCQ selection + self-echo/supersede cancel rework** (decision 4)
  - Drop `MCQOptionPicker`'s `@State selectedKey` (`:44`); make `externalSelectedKey` a `Binding`; the tap path writes the VM key the voice path submits from (`mcqVoiceMatchedKey`, +Recording `:246/:253`; fed via QuestionView `:338`).
  - Cancel-semantics: rework `onChange(of: externalSelectedKey)` (`:70-72`) to cancel `pendingSubmit` only on an *other-source supersede* (incoming key ≠ the tap's own in-flight target), never on the tap's *self echo*.
  - Tests → `MCQOptionPickerRaceTests` + hosted-picker wiring.
  - *Kept despite partial redundancy (Gate B note 2):* the supersede-cancel path in `tapThenVoiceMatchSubmitsAndHighlightsSameKey` is partly backstopped by #79's `submitMCQAnswer` transition-guard (a superseded submit is also rejected at `guard transition(to: .processing)`). Keep the test anyway — it's cheap and pins the *view-layer* single-owner convergence (highlight == submitted key) that the #79 guard never observes.

- [ ] **T5 — Verification tail**
  - Run the five targeted suites, then full `HangsTests` once (cross-cutting; pre-#113 rebase safety). Exact idioms in Acceptance.

## Acceptance

> Machine-evaluable. Each bug's diff is done only when its named test(s) pass and the grep holds. `Hangs/ViewModels/QuizViewModel.swift` unless noted; tests in `apps/ios-app/Hangs/HangsTests/`.

**Bug 1 (T1)** — four new tests in `QuizViewModelTests.swift`, one per legal/illegal origin:

| Test | Origin `quizState` | Assert |
|------|--------------------|--------|
| `startNewQuizFromErrorReachesAskingQuestion` | `.error` (Try Again) | ends `quizState == .askingQuestion` · `mockNetwork.createSessionCallCount == 1` |
| `startNewQuizFromFinishedReachesAskingQuestion` | `.finished` (Play Again) | ends `quizState == .askingQuestion` · `createSessionCallCount == 1` |
| `startNewQuizDoubleTapCreatesOneSession` | `.error` or `.finished` | two concurrent `startNewQuiz` (`withMainSerialExecutor`) → `createSessionCallCount == 1` |
| `startNewQuizFromRecordingIsNoOp` | `.recording` | `quizState` unchanged (`== .recording`) · `createSessionCallCount == 0` |

- Grep (guard branches on the result): `grep -n 'guard transition(to: .startingQuiz) else' QuizViewModel.swift` returns the line inside `startNewQuiz` (before: `:555` dropped the `Bool`).
- Grep (table): `.finished`'s and `.error`'s `validTransitions` cases both contain `"startingQuiz"`.
- New mock member `createSessionCallCount` exists on MockNetworkService.

**Bug 2 (T2)** — new tests in `SkipCancelWordTests.swift`:
- `skipExpiryDuringRecordingDoesNotCommit`: arm undo window, set `quizState = .recording`, fire expiry → quiz does **not** enter `.skipping` (`quizState == .recording`), i.e. `skipQuestion` was blocked.
- `startRecordingCancelsPendingSkipWindow`: after `startRecording`, `pendingSkipWindow == nil`.
- `submitMCQCancelsPendingSkipWindow`: after `submitMCQAnswer`, `pendingSkipWindow == nil`.
- Grep: the expiry closure (`:1064-1070`) references `quizState` (guard added; absent before).

**Bug 3 (T3)** — new test in `QuizViewModelTests.swift`:
- `finishedResetsMinimized` (mirrors `endQuizResetsMinimized` `:1095`): set `isMinimized = true`, `transition(to: .finished)` → `isMinimized == false`.

**Bug 4 (T4)** — new tests in `MCQOptionPickerRaceTests.swift` (+ hosted-picker wiring):
- `tapThenVoiceMatchSubmitsAndHighlightsSameKey`: tap A, then voice-match B → submitted key == highlighted key == B (no divergence).
- `tapEchoDoesNotCancelOwnSubmit`: a tap does **not** cancel its own `pendingSubmit` via the self-echo `onChange`; A is submitted.
- Grep: `@State ... selectedKey` no longer in `MCQOptionPicker.swift`; `externalSelectedKey` is declared `@Binding`.

**Suite run (T5)** — from `apps/ios-app/Hangs`:
- Targeted: `xcodebuild test -scheme Hangs-Local -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:HangsTests/QuizViewModelTests -only-testing:HangsTests/QuizViewModelSubmissionRaceTests -only-testing:HangsTests/SkipCancelWordTests -only-testing:HangsTests/MCQOptionPickerRaceTests -only-testing:HangsTests/ScreenAwakeControllerTests | tail`
- Full once: `xcodebuild test -scheme Hangs-Local -destination 'platform=iOS Simulator,name=iPhone 17 Pro' | tail` → all green.

**Snapshot baselines:** no `.stableDump`/`.dump` re-record required — no task adds a `@Published` (`isStarting` is a plain `var`; `isMinimized` pre-exists). If a `@Published` were added the dumps would change and need human re-record (ios rules), but none is planned.

## Research (Phase 1, 2026-07-20)

**Anchor drift: none.** All four cited anchors are exact on this branch.

**State machine.** `QuizState` enum, `validTransitions` table, `transition(to:caller:) -> Bool` all in `QuizViewModel.swift:22 / :83 / :322`. `transition` guards on `validTransitions.contains(to)`, logs + returns `false` on reject, and only on success clears `mcqVoiceMatchedKey` when entering `.askingQuestion` (`:333`). It is already `@discardableResult` (`:321`), so most call sites drop the result silently (this is why bug 1 compiles) — see decision 5 for why the attribute stays. Single-flight precedent to adopt: #79 `submissionEpoch` (`:369-385`) + rejected-`.processing`-abort — `submitMCQAnswer` uses `guard transition(to: .processing) else { return }` (`:931`); `resubmitAnswer` adds `isSubmittingAnswer` flag (`:950`) + same guard (`:993`); skip/MCQ bump the epoch before their first await.

**Bug 1 (`:555`).** `startNewQuiz` calls `transition(to: .startingQuiz)` and ignores the result; `error→startingQuiz` is NOT in the table (`.error → ["idle","askingQuestion"]`, `:93`), so Try-Again runs the whole flow while `quizState` stays `.error`. No `isStarting` flag exists (re-entrancy guards `:361-385`). `createSession` overwrites `currentSession` at `:608/:617`. Fix = add `startingQuiz` to the successors of **every legal origin** (audit below) + `guard transition(...) else { return }` at function entry + `isStarting` flag mirroring `isSubmittingAnswer`.

**`startNewQuiz` call-site origin audit (cycle 2, first-hand on this branch).** Every invocation and the `quizState`(s) it can fire from — the guard sits at `startNewQuiz` entry, so it gates all of them:

| Call site | Origin `quizState` |
|-----------|--------------------|
| `HomeView.swift:64` — "Start Quiz" button | `.idle` (Home is the `.idle` root, `ContentView:80`). HomeView is *also* rendered as the minimized-background of an active state (`ContentView:89/:97`); an accidental tap there is the intended **rejected no-op**, not a legal start. |
| `CompletionView.swift:177` — "Play Again" | **`.finished`** (CompletionView renders only in `.finished`, `ContentView:103`) — the cycle-1 miss. |
| `ContentView.swift:298` — ErrorView "Try Again" | `.error` (ErrorView renders only in `.error`, `ContentView:106`; reached via `shouldRetryWithNewSession`, i.e. `context == .initialization`) |
| `QuizViewModel+CommandListener.swift:169` — voice "start" | `.idle` (`currentCommandScreen == .home` iff `quizState == .idle`, `+CommandListener:50`) |
| `QuizViewModel.swift:894` — `retryLastOperation()` | `.error` (`guard case .error`, `:886`; only the non-submission/recording `default` branch) |
| `QuizViewModel.swift:1124` — `resumeSession()` | **dead path** — no caller repo-wide; theoretical origin `.idle` |
| `QuizViewModel.swift:1195` — `confirmLanguageAndStartQuiz()` | **dead path** — no caller repo-wide; theoretical origin `.idle` |
| `SettingsView.swift:648` — `playPack()` | `.idle` (Settings/OrderPack is pushed over the `.idle` Home root; pack-play fires from at-rest home) |

**Legal origin set = {`.idle`, `.error`, `.finished`}.** `.idle` already lists `startingQuiz` (`:85`); `.error` (`:93`) and `.finished` (`:92`) do **not** — both must gain it. Every other origin is an active mid-quiz state where `startNewQuiz` must stay a logged no-op. (The two dead paths would fire from `.idle` if ever wired, already legal — no table change needed for them.)

**Bug 2 (`:1069`).** Expiry closure (`:1064-1070`) rechecks only `pendingSkipWindow != nil` (`:1067`), never `quizState`; `skipQuestion` (`:1016`) legally goes `.recording/.processing → .skipping` (`:88/:89`) and never tears down the streaming mic. `beginSkipUndoWindow(duration:)` is armed only from CommandListener (`:185`); neither `startRecording` (+Recording `:33`) nor `submitMCQAnswer` cancels the window. Fix = guard expiry on `quizState == .askingQuestion` + cancel `.skipUndo`/`pendingSkipWindow` in both entry paths.

**Bug 3 (`:1379`).** `transition(to: .finished)` never clears `isMinimized` (reset lives only in resetState `:1463` / endQuiz). `canMinimize` (`:292`) already excludes `.finished`, but ContentView's floating overlay (`ContentView.swift:121`) gates on `isMinimized` ALONE, not `canMinimize` → widget floats over CompletionView. Two fixes (planner picks one): reset `isMinimized` on `.finished`, or gate `:121` on `isMinimized && canMinimize`. Direct precedent: 54.6 `endQuiz` resets `isMinimized` (`QuizViewModelTests.swift:1095`).

**Bug 4 (`MCQOptionPicker.swift:44`).** `effectiveSelectedKey = selectedKey ?? externalSelectedKey` (local-wins). VM sets `mcqVoiceMatchedKey` (+Recording `:246`) then submits directly (`:253`); QuestionView (`:338`) feeds it as `externalSelectedKey`. Tap A sets `@State selectedKey = A`, then voice B submits + cancels the pending tap (`:72`) but highlight stays A. Fix = VM single owner: drop `@State selectedKey`, tap sets the VM key (make `externalSelectedKey` a binding). Tap path currently does NOT set `mcqVoiceMatchedKey`.

**Test seams** (HangsTests: Swift Testing + ViewInspector + ConcurrencyExtras `withMainSerialExecutor`). VM built via `Fixtures.makeViewModelWithNetwork()` or explicit init with `Mock{Network,Audio,Persistence,STT}`; `quizState` is directly settable, `beginSkipUndoWindow(duration:)` is injectable, mocks expose `*CallCount` (`submitTextInputCallCount` exists; add `createSessionCallCount` for the double-tap assert). Extend: `QuizViewModelTests` (startNewQuiz transition/error `:338/:351` → add Try-Again-from-`.error`, Play-Again-from-`.finished`, double-tap `createSessionCallCount == 1`, rejected-origin no-op from `.recording`; isMinimized `:1095`) · `QuizViewModelSubmissionRaceTests` (#79 single-flight) · `SkipCancelWordTests` (undo-window expiry `:99`) · `MCQOptionPickerRaceTests` + hosted picker wiring · `ScreenAwakeControllerTests` (`.finished`+minimized).

**Build-vs-adopt: adopt in-repo, no external library** — this is internal state-machine enforcement; precedent is the #79 `submissionEpoch` + rejected-transition-guard single-flight already live in `submitMCQAnswer`/`resubmitAnswer`.

**Web pass skipped:** purely internal SwiftUI/state-machine invariants; no genuine external unknown.

**Product question: none** — all four are deterministic correctness fixes; bug-3's two fix options and bug-2's "an answer supersedes a pending skip" are technical choices, not UX/scope.

## Prep progress

> *Maintained by `/prepare-issue` — durable record of where prep is; safe to resume from a fresh session.*

| Phase | State | Latest gate verdict |
|-------|-------|---------------------|
| 1 · Research          | ✅ done | — |
| 2 · Plan              | ✅ done | — |
| 3 · Plan review       | ✅ done | cycle 3: ready-check READY · design-soundness SOUND 0.90 |
| 4 · Impl-plan         | ✅ done | Tasks (atomic) T1–T5 + machine-evaluable Acceptance |
| 5 · Impl-plan review  | ✅ done | ready-check READY (0 blockers) · design-soundness SOUND 0.90 (0 flaws, 2 test-thinness notes) |
| 6 · Split             | ✅ done | single-session — no execution-prompts file; 2 Gate B notes folded into T1/T4 |

**Last updated:** 2026-07-20 · **Next:** — prep complete; `bug · ready-for-agent` (P1, top of the arch-review batch). · **Gate attempts:** P3 passed cycle 3 (2/3 history) · P5 passed cycle 1 (READY · SOUND 0.90)
