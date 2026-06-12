# Issue #54 — Design-refresh sweep regressions (#52 fallout)

**Triage:** bug · ready-for-agent (umbrella)
**Opened:** 2026-06-12
**Branch under review:** `ralph/overnight-20260611-2226`
**Caused by:** #52 — iOS design-refresh sweep (Ralph overnight, commits `1997325..78d7742`)

## Summary

The overnight #52 design sweep redesigned 8 iOS screens (Home, Settings, Question,
Result, Completion, Onboarding ×4, Error) plus the token/font/primitive layer. The
redesign broke several previously-working flows and shipped with a **red test suite**.
This is an umbrella catalog of every regression found in a review + test pass on
2026-06-12. Each sub-task (54.N) is self-contained: a subagent / fresh session can
pick one up, reproduce it in the simulator, confirm against the cited code, plan a
fix, and implement it.

**Merge recommendation:** do **not** merge as-is. The breakage is real and broad, but
**every item below is fixable** — most are shallow view-layer wiring/colour bugs, not
architectural. Root causes are identified with file:line. Suggested path: fix on this
branch (or cherry-pick the good token/font work), re-record snapshots, make RS + a few
new behavioural tests green, then merge.

## Child plan files (fresh-session entry points)

Each is self-contained for a fresh-context session (scope, file:lines, fix, verification recipe,
Pencil-sync, done-criteria). Pick one per session.

| Plan | Covers | Priority | Status |
|---|---|---|---|
| _(landed)_ | 54.3, 54.8 (RS), 54.9, 54.10, 54.12, 54.14-lineSpacing | P0/P2 | ✅ commits `3eb48d1`, `40b9ff0` |
| [`issue-54-02-voice-overflow.md`](issue-54-02-voice-overflow.md) | 54.2 voice layout overflow | P0 | ready |
| [`issue-54-05-resubmit-cancel.md`](issue-54-05-resubmit-cancel.md) | 54.5 + 54.15 cancelled-resubmit + ErrorView factory | P0 | ready |
| [`issue-54-01-dark-mode.md`](issue-54-01-dark-mode.md) | 54.1 dark mode (Phase 1 token swap; Phase 2 asset-catalog) | P0 | ready |
| [`issue-54-sim-repro.md`](issue-54-sim-repro.md) | 54.4, 54.6, 54.7 (need live-sim repro first) | P0 | ready |
| [`issue-54-recovery-paths.md`](issue-54-recovery-paths.md) | 54.17, 54.18 broken recovery paths (new, 2nd review pass) | P1 | ready (54.18 needs a founder product decision) |
| [`issue-54-data-cleanups.md`](issue-54-data-cleanups.md) | 54.11, 54.13, 54.16 + hygiene 54.19–54.21 | P2 | ready (54.13 needs a founder display decision) |
| [`issue-54-pencil-snapshot-sync.md`](issue-54-pencil-snapshot-sync.md) | Pencil 1:1 sync + snapshot re-record + CI gate + TSan triage | P1 | run last |

## Ground-truth test state (2026-06-12)

> **CORRECTED 2026-06-12 (fix session, iPhone 17 Pro / iOS 26.5):** the original
> table below over-counted. A clean `xcodebuild test` run shows **6 failures, not 13**.
> The `SilenceDetectionService` suite **passes** here (5.38s) — its claimed 10 failures
> did **not** reproduce, which de-risks 54.4 (the silence state machine is fine). A
> separate **ThreadSanitizer BUS crash** (`objc_release`, libobjc) appeared during the
> UI-test phase — likely teardown noise; tracked under 54.8.

| Suite | Result (corrected) | Notes |
|---|---|---|
| Backend `pytest` | ✅ 100 passed | `apps/quiz-agent` — unaffected by this branch |
| iOS unit/inspector/model (Swift Testing) | ✅ pass | 359 tests, only the 3 snapshot issues below fail |
| iOS snapshot | ❌ 3 failed | HomeView idle, QuestionView recording, QuestionView asking — **diff cause known (2nd pass): pure model drift**, 4 new fields (`headlineAnswer`, `_mcqVoiceMatchedKey`, `micPermissionResult`, `onReplayOnboarding`); re-record **after** UI is final |
| iOS `SilenceDetectionService` | ✅ **passed** | suite green here — original "10 failed" not reproduced |
| iOS Regression (RS-Start/Correct/Incorrect/Paywall) | ✅ **green — verified 2nd run** | `Executed 4 tests, 0 failures` (2026-06-12 verification pass) — 54.3/54.8 fix confirmed |
| ThreadSanitizer | ⚠️ sporadic | BUS crash did **not** reproduce in the 2nd-pass TSan-compiled run — likely teardown noise; watch item only (54.8) |

**Corrected total: 6 iOS failures** (3 snapshot + 3 RS), not 13. The branch was committed
despite this — the overnight loop / CI did not gate on the full `xcodebuild test` action.
This is itself a process bug (54.8). The original (pre-correction) table is preserved in
git history.

> ⚠️ Two of the logic files implicated below (`QuizViewModel*.swift`, `QuizViewModel+Recording/Timers`)
> were **NOT modified by this branch** (diff touched only Views, Models/AppErrorModel,
> Models/QuizCompleteSummary, ViewModels/OnboardingViewModel, Theme+Hangs, Mocks). So
> #4/#5/#6 are caused by the **redesigned Views calling the unchanged ViewModel differently**,
> or are pre-existing VM bugs newly *exposed* by the new flow. Fix sessions should confirm
> the trigger in the simulator before changing VM code.

---

## P0 — Founder-reported (blocking)

### 54.1 — Dark mode broken: white cards + invisible text (founder #3)
**Symptom (Image #1):** Home renders a dark page background but the STREAK/BEST/session
cards are bright white with near-invisible labels and "0" values.
**Root cause (high confidence):** the adaptive token system is half-applied.
- `Theme.Hangs.Colors.bg` / `ink` / `muted` *are* adaptive (`Color(light:dark:)` via a
  correct `UIColor` dynamic provider — `Color+Theme.swift:44`). In dark mode `bg`→`#161616`,
  `ink`→`#F4F4F4` (near-white).
- But card **surfaces hardcode `Color.white`** instead of the adaptive `bgCard` token:
  - `HangsBlocks.swift:72` — `HangsCard` `.fill(Color.white)` (used by every stat box, config card, settings group, result/completion card)
  - `HangsBlocks.swift:332` — `HangsAnswerRow` `.background(Color.white)`
  - `HangsChrome.swift:48` — `HangsNavChip` white fill
  - `HangsChrome.swift:94` — `HangsQuizNav` close-button white circle
  - `HomeView.swift:186` — `navChipVisual` white fill
- Net effect in dark mode: white card (didn't adapt) + near-white `ink` text (adapted) = illegible.

**Also systemic:** 18 view files still use the **old non-adaptive** `Theme.Colors.* / Theme.Spacing.* / Theme.Radius.* / Theme.Components.*` system (not `Theme.Hangs.*`): MinimizedQuizView, PaywallView, LiveTranscriptView, ImageQuestionView, AudioDevicePickerView, and components (ScoreCard, StatsCard, SettingRow, badges, PrimaryButton, SecondaryButton, MicButton, …). These will look inconsistent / non-adaptive.

**Founder ask (enhancement framing):** design dark mode in Pencil first, then implement
via **Xcode asset-catalog colour sets with light+dark variants**, so toggling the colour
scheme changes everything with no per-call logic. Current approach (`Color(light:dark:)`
in Swift) works for the tokens that use it, but the hardcoded `Color.white` and the legacy
`Theme.Colors` islands defeat it.
**Fix approach:** (a) replace hardcoded `Color.white` card fills with adaptive `bgCard`;
(b) migrate legacy `Theme.Colors.*` callers to `Theme.Hangs.*` (or back the tokens with
asset-catalog colour sets); (c) re-test both appearances. Confirm contrast for `ink`/`muted`
on the adapted card.
**Confidence:** high (mechanism reproduced in code; matches screenshot exactly).

### 54.2 — Voice question text too big, pushes Record/Skip off-screen (founder #2)
**Symptom:** the question text on the quiz screen is oversized and shoves the buttons /
other text off the screen. Layout was correct before #52.
**Root cause (high confidence):** in `QuestionView.swift` the **voice body is not scrollable**
and lets the headline grow unbounded:
- `voiceBody` (`QuestionView.swift:257`) is a `VStack` with `Spacer()`s, no `ScrollView`.
- The question renders in `.hangsDisplaySM` = **Anton 40pt** (`Theme+Hangs.swift:159`) with
  `.minimumScaleFactor(0.55)` + `.fixedSize(horizontal:false, vertical:true)` (`QuestionView.swift:271-279`).
  `fixedSize(vertical:true)` forces the text to take whatever vertical space it needs →
  a long question expands the VStack and pushes `voiceActionRow` (Record/Skip) below the screen.
- Contrast: the **MCQ body wraps its prompt in a `ScrollView`** (`QuestionView.swift:197`), so
  MCQ doesn't overflow — only the voice body regressed.
**Fix approach:** cap the headline (smaller font / `lineLimit` / scrollable region) and/or wrap
the voice body content above the action row in a `ScrollView`, keeping Record/Skip pinned.
**Confidence:** high.

### 54.3 — "Record" button does nothing but reset the countdown (founder #4)
**Symptom:** tapping Record on the quiz screen flickers the screen and resets the countdown
timer, but recording never starts.
**Root cause (high confidence):** the redesign **added a manual Record button** (the old
QuestionView on `main` had no `startRecording`/`toggleRecording` call — it was pure auto-record).
The new button is mis-wired:
- `QuestionView.swift:367` Record button → `viewModel.startRecordingOrTimer()`.
- `startRecordingOrTimer()` (`QuizViewModel.swift:782`) when `autoRecordEnabled` (default **true**)
  + `silenceDetectionService != nil` → calls `startThinkingTimeCountdown()`, which only **starts a
  countdown** (THINK chip) and records *after* it elapses. It never starts recording on tap.
- So a button labelled "Record" restarts the thinking countdown — exactly the reported behaviour.
**Fix approach:** wire the manual Record button to `toggleRecording()` / `startRecording()` so it
records immediately (skipping/short-circuiting the thinking countdown), or remove the manual button
in auto-record mode. Decide the intended UX (manual record vs pure auto-record) first.
**Confidence:** high. **Note:** this is the same identifier rename that breaks RS tests (54.8):
new ids are `question.record`/`question.stop` (`QuestionView.swift:383`), tests look for `question.micButton`.

> **STATUS 2026-06-12 — FIXED, verified** (2nd-pass RS run green 4/4; `toggleRecording()`
> confirmed safe from every reachable state). Founder decision: **auto by default + manual
> override**. Auto-record already fires on its own (`startRecordingOrTimer()` auto-called at
> `QuizViewModel:440/945` on question presentation), so the button's call to it was redundant
> *and* the bug (re-armed the think countdown). Rewired the Record button to
> `Task { await viewModel.toggleRecording() }` (`QuestionView.swift:363`) — starts recording
> immediately from `.askingQuestion` (cancelling timers) and stops+submits from `.recording`
> (also cancels the auto-stop timer the old branch forgot). Verified behaviourally by the RS
> suite (tap Record → `.recording` → STT → confirm → result).

### 54.4 — Recording doesn't auto-stop when the user says nothing (founder #5)
**Symptom:** after the answer timer expired, recording auto-started, but with no speech it never
stopped on its own.
**Root cause (medium confidence — needs simulator confirm):**
- Silence-based auto-stop (`startSilenceDetection`, `QuizViewModel+Recording.swift:203`) only fires
  on `.silenceAfterSpeech` — i.e. it **requires speech first**. No speech → no silence event → no stop.
- The only safety net for a silent recording is the hard cap `startAutoStopRecordingTimer()`
  (`QuizViewModel+Timers.swift:119`) = `Config.autoRecordingDuration` = **15 s**. Two concerns:
  (a) 15 s of dead air feels like "never stops"; (b) the cap is gated `guard !isRerecording`
  (`Timers.swift:120`) so it's skipped on re-record attempts.
- Cross-signal: the entire `SilenceDetectionService` unit suite (10 tests) is **red/timing out**
  on this branch — the silence state machine itself may be broken, which would also defeat the
  normal speech→silence auto-stop.
**Fix approach:** (a) verify `SilenceDetectionService` tests (real regression vs flaky async);
(b) ensure the 15 s hard cap actually fires on the streaming-STT no-speech path; (c) consider a
shorter no-speech cap + a visible countdown so the cap is legible.
**Confidence:** medium. Founder's ask (a max recording limit that ends even with no speech) mostly
exists (15 s cap) but needs to be proven to fire and likely shortened.

### 54.5 — "Failed to resubmit answer: cancelled" instead of the result screen (founder #6)
**Symptom (Image #2):** after recording a voice answer, an OOPS error screen appears
("Failed to resubmit answer: cancelled") instead of the result screen.
**Root cause (high confidence — self-cancellation bug):**
- Streaming-STT path: `handleCommittedTranscript` (`+Recording.swift:162`) shows the confirmation
  modal and calls `startAutoConfirmIfEnabled()`.
- The auto-confirm Task (`+Timers.swift:202`) runs the 10 s countdown then `await self.confirmAnswer()`.
- `confirmAnswer()` (`+Recording.swift:414`) **first calls `cancelAutoConfirm()`** →
  `taskBag.cancel(.autoConfirm)` → cancels the very Task it is running inside.
- It then proceeds (streaming path: `pendingResponse == nil`) to
  `await resubmitAnswer(...)` → `await networkService.submitTextInput(...)`. URLSession sees the
  enclosing Task is cancelled → throws `URLError.cancelled` → caught as
  "Failed to resubmit answer: cancelled" (`QuizViewModel.swift:652`) → error screen.
- The Whisper/batch path is immune (it returns via `pendingResponse` before any cancellation-aware await).
- This is closely related to the previously-"done" **#19** (auto-confirm routing through `resubmitAnswer`).
**Fix approach:** don't do cancellation-aware async work in a Task that cancels itself. Either run the
actual submission outside the auto-confirm Task, or have the streaming path reuse a cached response /
a dedicated non-self-cancelling submit. Also: the error copy is raw English in a SK-first app and the
retry action is wrong for a cancellation — see 54.15.
**Confidence:** high on mechanism; verify it's the live trigger (VM file unchanged by this branch — the
new modal/sheet flow may also contribute).

### 54.6 — Can't end quiz from the minimized view; minimized view not redesigned (founder #1)
**Symptom:** no usable way to end the quiz from the minimized quiz widget; and this screen still
needs the redesigned look.
**Root cause (medium confidence):**
- `MinimizedQuizView.swift` was **not touched by #52** — it still uses the **old `Theme.Colors.*`**
  tokens (non-adaptive) and the old visual language.
- An end-quiz control *does* exist: a 22×22 "✕" chip in the top-trailing corner with `.offset(x:6,y:-6)`
  pushing it partly off the card edge (`MinimizedQuizView.swift:98-114`) → tiny + hard/again to hit;
  it opens an End-Quiz confirmation dialog that calls `viewModel.endQuiz()`.
**Fix approach:** redesign MinimizedQuizView to the new design system + make the end-quiz action an
obvious, comfortably-tappable control. Verify the confirmation dialog presents from the floating overlay.
**Confidence:** medium (end action exists; "can't end" is likely the tiny offset target — confirm in sim).

### 54.7 — Onboarding "Continue" button reportedly doesn't advance (founder #7)
**Symptom:** the button to move to the next onboarding page didn't work.
**Root cause (LOW confidence — needs simulator repro):** the wiring *looks* correct —
`OnboardingView.swift:238` "Continue" → `viewModel.advance()`; `OnboardingViewModel.advance()`
(`OnboardingViewModel.swift:46`) correctly steps welcome→features→permission and is unit-tested.
Candidates to check in the sim: (a) `HangsPrimaryButton` tap target / an overlay swallowing taps;
(b) the secondary "Skip" button (`continueWithoutMic()` → finishes onboarding entirely) being mistaken
for "next"; (c) the root `.animation(value: viewModel.page)` interfering. No code defect proven.
**Confidence:** low — reproduce first, then locate.

---

## P1/P2 — Found during review (not founder-reported)

### 54.8 — iOS test suite is red and ungated (process + tests)
13 failures (see table above). Two distinct problems:
1. **Tests didn't gate the merge.** The overnight loop/CI ran (at most) a subset; the full
   `xcodebuild test` action is red. Add a gate so design-scale changes can't land red.
2. **RS tests use a stale identifier.** RegressionTests tap `question.micButton`
   (`HangsUITests/Regression/RegressionTests.swift:88/132/50`) but the redesign renamed it to
   `question.record`/`question.stop`. Update the page objects/identifiers **and** add genuinely
   *behavioural* coverage: record→records, no-speech→auto-stops, confirm→result (not error). The
   current inspector/snapshot tests assert structure only, which is why #4/#5/#6 passed unit CI.
   > **STATUS 2026-06-12 — FIXED, verified** (2nd-pass run: `Executed 4 tests, 0 failures`).
   > Conflict resolved per CLAUDE.md rule #4: the
   > newer/more-tested redesign convention (`question.record`/`question.stop`, also asserted by
   > `QuestionViewInspectorTests`) wins over the older RS `question.micButton`. Updated
   > `QuestionPage` (`recordButton`/`stopButton`) + the 3 RS call-sites. The RS suite now doubles
   > as the behavioural record→confirm→result coverage asked for (it taps Record, drives STT,
   > asserts the result screen — not the error screen, which also exercises 54.5's path).
3. Re-record the 3 stale snapshots after the UI is finalized.
   > **NOTE:** deferred until 54.2 (voice layout) + 54.1 (dark-mode token swap) land, since both
   > change the QuestionView/HomeView pixels the snapshots capture.
4. **ThreadSanitizer BUS crash** (`objc_release`, libobjc) observed in the full-suite UI-test
   phase — not yet root-caused; may be teardown noise. Re-check after the RS suite is green.
**Note:** also caught a footgun this session — naively running `pytest`/`xcodebuild` with a wrong
cwd or a stale `-resultBundlePath` exits "success-ish"; always assert a real "Executed N tests" line.

### 54.9 — ResultView "Try this question again" advances instead of retrying
`ResultView.swift:259-267` — ghost button labelled "Try this question again" calls
`viewModel.continueToNext()`, which goes to the **next** question. No retry/re-queue exists. Either
mislabel or removed feature left behind. **Confidence: high (review-flagged, verify).**

### 54.10 — ResultView hardcodes `?? 10` for total questions
`ResultView.swift:308-309` uses `currentSession?.maxQuestions ?? 10`; `CompletionView.swift:153`
uses the setting-aware `?? settings.numberOfQuestions`. Inconsistent — Result can show a wrong
total/progress when the session was configured to a non-10 length. **Confidence: high.**

### 54.11 — ResultView "streak was X" uses all-time best, not prior streak
`ResultView.swift:347` uses `quizStats.bestStreak` as the "was" value on an incorrect answer.
Best-ever ≠ the streak just before this answer. Code comment admits it's a "proxy". **Confidence: high.**

### 54.12 — ResultView subheadline sign bug on negative point delta
`ResultView.swift:352-353` hardcodes a `"+ "` prefix then trims a leading `+` from
`pointsDeltaSuffix`; a negative delta ("-2") renders as "+ -2 points". Only manifests if scoring
can go negative. **Confidence: medium.**

### 54.13 — Fractional scores truncated by `Int(score)`
`QuizCompleteSummary.swift:35` (`correct = Int(score)`) and `CompletionView.swift:56`
(`Int(summary.finalScore)`) floor a `Double` score. With partial credit, the final score displays
low and `incorrectCount = answered - correct` becomes wrong (counts can exceed total). **Confidence: medium**
(depends on whether partial scoring is active).

### 54.14 — HangsQuestionCard: invalid `lineSpacing(-2)` + dead `secondaryValueColor`
`HangsQuestionCard.swift:31` — `.lineSpacing(-2)`: SwiftUI ignores negative line spacing (silent no-op;
likely meant `tracking`). `HangsQuestionCard.swift:78` — the `secondaryValue` `.foregroundColor` ternary
returns `ink` in **both** branches, so the `secondaryValueColor` parameter callers pass (e.g. ResultView
passes `.muted`/`.ink`) is silently dropped. **Confidence: high (review-flagged, verify).**

### 54.15 — ErrorView model built inline, bypassing `AppErrorModel.from()`
`ContentView.swift:71-79` constructs `AppErrorModel` inline for the `.error` case with a hardcoded
Slovak description and **always** `retryAction: .retryOperation`, ignoring the `ErrorContext` carried by
the state. Consequences: (a) raw English error text (e.g. "cancelled") shown in a SK-first app;
(b) wrong retry action for a `CancellationError` (which `AppErrorModel` has no dedicated case for).
The factory `AppErrorModel.from(context:)` already produces correct SK copy. **Confidence: high.**
Pairs with 54.5 (the cancelled-resubmit case is exactly what surfaces here).

### 54.16 — MCQOptionPicker: tap/voice race + missing animation on voice match
`MCQOptionPicker.swift` — `submitAfterDelay` spawns a detached `Task` with no handle; if a voice match
(`externalSelectedKey`) lands concurrently with a tap, `onSelect` can be called twice (no cancellation).
Also the row animation keys on local `selectedKey` only, so a voice-driven selection snaps without
animation. **Confidence: medium.**

### 54.17 — Settings "Reset question history" removed; VM error still directs users there (2nd pass)
`QuizViewModel.swift:370–374` surfaces *"…reset your history in Settings…"* at the 500-question cap,
but the 52.9 Settings redesign removed that row → permanent lockout with no actionable path. VM
plumbing (`resetQuestionHistory()`) intact; only the UI entry point is gone. **P1, confidence high.**
→ plan: [`issue-54-recovery-paths.md`](issue-54-recovery-paths.md)

### 54.18 — Onboarding promises typed answers; TextField removed from QuestionView (2nd pass)
`OnboardingView.swift:99/:119` promise a keyboard fallback and the "Type answers instead" CTA
(`:275`) finishes onboarding mic-less — but 52.10 removed the TextField from QuestionView, so a
mic-denied user can't answer voice/open questions (MCQ tap still works). `submitTextInput` exists,
nothing calls it. **P1, confidence high; needs founder decision (restore typed input vs drop no-mic
mode).** → plan: [`issue-54-recovery-paths.md`](issue-54-recovery-paths.md)

### 54.19 — `HangsMic.swift` dead code (2nd pass)
`HangsMicBlock` has zero production callers (replaced by the inline capsule Record button). Delete.
**P2.** → plan: [`issue-54-data-cleanups.md`](issue-54-data-cleanups.md)

### 54.20 — stale `QuestionPage.statusPill` page-object member (2nd pass)
`HangsUITests/Pages/QuestionPage.swift:28–30` references the removed `question.statusPill`
identifier; snapshot-test comments too. **P2.** → plan: [`issue-54-data-cleanups.md`](issue-54-data-cleanups.md)

### 54.21 — negative `.lineSpacing` no-op sweep (2nd pass; same class as 54.14)
Three more silent no-ops remain after 54.14: `ResultView.swift:83` (`-6`),
`AnswerConfirmationView.swift:147` (`-2`), `ScoreCard.swift:25` (`-4`). **P2.**
→ plan: [`issue-54-data-cleanups.md`](issue-54-data-cleanups.md)

---

## Fix-session log — 2026-06-12 (interactive, primary Mac, iPhone 17 Pro / iOS 26.5)

**Founder decisions taken this session:** (1) record UX = **auto by default + manual override**;
(2) dark mode = **quick legibility fix now, deliberate Pencil + asset-catalog redesign later**;
(3) the "Try again" button = **remove it, and keep Pencil 1:1 with the app** (Pencil becomes the
source of truth later — every UI change here must be mirrored in Pencil).

**Done + verified:**
- **54.3 / 54.8 (RS)** — Record button → `toggleRecording()`; RS identifiers renamed. RS suite green
  (`Executed 4 tests, 0 failures`). Commit `3eb48d1`.
- **54.9** — removed the mislabeled "Try this question again" CTA; updated the inspector test to
  assert neither variant renders it (passes). ⚠️ **Pencil-sync owed** (remove the button from the
  Result frame so design matches app).
- **54.10** — `totalQuestions` fallback `?? 10` → `?? settings.numberOfQuestions` (data-only).
- **54.12** — subHeadline sign bug fixed (use `pointsDeltaSuffix` directly; no more "+ -2 points").
- **54.14 (part)** — removed the no-op `.lineSpacing(-2)`. **Deferred:** wiring `secondaryValueColor`
  (a visual change — verify the recap colour against Pencil + re-record the dump deliberately).
- Unit suite: **356 pass**; only the **3 pre-existing stale snapshots** fail (HomeView idle,
  QuestionView asking/recording) — left red on purpose: re-record **after** 54.1 (dark) + 54.2
  (voice layout) change those pixels.

**Deferred with reason (next sessions):**
- **54.2** voice overflow (ScrollView) — P0, small; do next + Pencil-sync + re-record QuestionView snaps.
- **54.5** self-cancelling resubmit + **54.15** ErrorView factory — do together (same cancelled path).
- **54.11** streak "was" — needs a VM field capturing the streak *before* reset (not a view-only fix).
- **54.13** fractional-score truncation — real (partial scoring exists) but needs a **display decision**
  (how should a 3.5-point score render as a count?).
- **54.16** MCQ tap/voice race — medium; needs the detached-Task handle + animation key change.
- **54.4 / 54.6 / 54.7** — need live simulator repro (auto-stop cap; minimized end-quiz; onboarding).
- **54.1** dark mode — quick token swap (`Color.white` → `bgCard` + legacy `Theme.Colors` islands),
  then the deliberate Pencil redesign as its own task.

## Second review pass — 2026-06-12 (verification + gap-hunt, delegated to sonnet agents)

**What was checked:** (a) every file:line claim in the 6 child plans re-verified against HEAD;
(b) the two fix commits (`3eb48d1`, `40b9ff0`) reviewed for correctness; (c) a gap-hunt sweep of
the #52 diff for uncatalogued regressions; (d) a fresh full iOS test run.

**Results:**
- **Plans are accurate.** All mechanism claims confirmed; only trivial line drifts corrected
  (ResultView 347→338, QuestionView bgCard 397→398). Fix recipes reference valid symbols;
  `--ui-test-long` (54.2 recipe) correctly does not exist yet.
- **Fix commits are correct.** `toggleRecording()` is safe from every reachable state (button
  disabled during processing); the 54.9 test inversion is semantically right. Two follow-ups
  filed: stale `statusPill` page-object member (54.20) and a missing test for the 54.10
  fallback (noted in the cleanups plan).
- **Test ground truth re-confirmed:** 359 executed / 356 pass / exactly the 3 known snapshot
  fails (cause isolated: model drift, 4 new fields — see snapshot plan); RS suite green 4/4;
  TSan crash did not reproduce (downgraded to watch item).
- **5 new findings filed:** 54.17 + 54.18 (P1 broken recovery paths →
  `issue-54-recovery-paths.md`), 54.19–54.21 (P2 hygiene → cleanups plan).

## Suggested execution order (for the fix phase)

1. **54.8** first — get the suite green-able (fix RS identifiers, re-record snapshots, add a behavioural
   harness) so every subsequent fix is verifiable. Investigate the `SilenceDetectionService` red suite.
2. **54.3 → 54.5 → 54.4** — the core voice quiz loop (record → auto-stop → confirm → result). These
   chain together and produced Image #2.
3. **54.2** — voice layout overflow (small, high-value).
4. **54.1** — dark mode (largest; do the Pencil dark design + asset-catalog migration deliberately).
5. **54.6 / 54.7** — minimized view redesign + onboarding repro.
6. **54.17 / 54.18** — recovery paths (54.18 after the founder decision; 54.18-restore pairs
   naturally with 54.2's QuestionView pass).
7. **54.9–54.16 + 54.19–54.21** — data + component + hygiene cleanups (batchable).

## Verification checklist per sub-task (for the picking session)
- [ ] Reproduce in the simulator (light **and** dark) before changing code.
- [ ] Confirm the cited file:line is the actual cause (the VM logic files were not changed by this branch).
- [ ] Write/extend a test that fails on the bug and passes after the fix (behavioural, not just structural).
- [ ] Screenshot-verify per `docs/testing/screenshot-verify-procedure.md` (CLAUDE.md rule #2).
- [ ] Update this file's sub-task status.
