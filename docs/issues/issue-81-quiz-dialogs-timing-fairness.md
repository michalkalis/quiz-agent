# Issue #81 — Quiz dialogs & timing fairness: End-Quiz has no Cancel; countdown ticks while typing and behind dialogs; 7s auto-advance escape hatch too small

**Triage:** bug · approved 2026-07-05 · implemented 2026-07-06 (#86 design gate lifted same day) · **follow-up open** (founder feedback 2026-07-06: remove modal countdown freeze + ResultView X confirmation — see section below)

**Created:** 2026-07-03 · **Founder:** Michal · **Source:** UI/UX review 2026-07-03 (sim-observed) + HIG research

**Severity:** medium — a destructive dialog without Cancel is a direct HIG violation; the timer issues are fairness bugs that cost users answers.

## Problem

Three related timing/dialog defects on the quiz flow (all observed on sim, `11/15/21-*.png` shots):

1. **End Quiz dialog has no Cancel** — a single red destructive "End Quiz" button in a custom card;
   the only way out is tap-outside. HIG: a destructive alert must offer an explicit Cancel
   (leading side). Ending also goes straight Home with no partial summary (secondary).
2. **Answer countdown keeps running while the user types** a typed answer (observed at 3s remaining
   mid-typing) **and keeps running behind the End Quiz dialog** — the user is timed while the app
   itself has taken over the screen.
3. **Result auto-advance (7s) escape hatch is a tiny "Stay here" text link** — hard to hit even for
   UI automation; while driving it's the only way to linger on a result. Auto-advance itself is the
   right call for hands-free driving; the problem is the control size and that interaction doesn't
   pause it. (WCAG 2.2.1 "enough time" + HIG "prefer explicit dismiss" — see research doc §5.)

## Evidence

- Screenshots: `docs/research/uiux-review-2026-07-03-shots/21-quiz-end-dialog.png` (single-button dialog), `15-quiz-result-correct.png` (7s auto-advance + tiny link).
- HIG/WCAG citations: `docs/research/uiux-hig-research-2026-07-03.md` §5.

## Recommendation

1. End Quiz dialog: add Cancel (leading), keep End Quiz as the destructive action; pause the answer
   countdown while any dialog/sheet is presented.
2. ~~Pause (or generously extend) the countdown while the typed-answer field is focused — typing is
   already a deliberate act; racing the clock adds nothing.~~ **Superseded 2026-07-05** — founder decided NO countdown pause while typing (would grant extra thinking time); see `docs/design/ui-proposals-2026-07-decisions.md` decision 2.
3. Result screen: make "Stay here" a full-size secondary button (≥44pt target) and pause the
   auto-advance timer on any touch interaction with the result screen. Keep 7s auto-advance as the
   hands-free default.

Cross-refs: #77 (voice commands — spoken control of the same moments), #68 (driving defaults).

## Acceptance

- [x] End Quiz dialog shows Cancel + End Quiz; Cancel returns to the quiz with state intact — was already a Cancel+destructive `confirmationDialog` on main (landed alongside #83/#84/#85); 2026-07-06 converted to the founder-approved native **alert** (frame `w9tOoU`): "Continue" (cancel) + destructive "End Quiz", title only, in both QuestionView and MinimizedQuizView
- [x] Answer countdown is paused while the End Quiz dialog (or any sheet) is up — new `isQuizModalPresented` flag on QuizViewModel (set by End-Quiz alert + in-quiz settings sheet); thinking + answer countdown loops freeze while set, resume where they left off; unit-tested
- [x] ~~Answer countdown pauses (or extends) while the typed-answer input is focused~~ **Superseded 2026-07-05** — no countdown pause while typing; partial-quit stats are recorded but not displayed (verified: `recordAnswer` already persists per-question regardless of early quit). Intent now encoded in a regression test (`typedAnswerDoesNotPauseCountdown`).
- [x] "Stay here" hit target ≥ 44pt (now a full-width `HangsSecondaryButton`, height 44, below the countdown strip); touching the result screen pauses auto-advance (already shipped pre-#81 via tap/drag `simultaneousGesture` → `pauseQuiz()`)
- [x] Existing RS regression scenarios pass (timer-related RS updated if semantics change) — no RS semantics changed; `result.stayHere` accessibility id preserved

## Founder feedback 2026-07-06 (post-implementation — REOPENS two items, not yet fixed)

1. **Remove the countdown freeze behind dialogs/settings.** The `isQuizModalPresented` pause
   (acceptance item 2 above) is exploitable: a user can open the End-Quiz dialog or the settings
   sheet to gain free thinking time. Founder: the countdown must keep running behind any
   modal/sheet — same rationale as the no-pause-while-typing decision (2a). Users can adjust
   settings from the Result screen; bad settings mid-quiz are their own problem.
2. **ResultView top-bar X must show the same End-Quiz confirmation alert** as QuestionView /
   MinimizedQuizView (frame `w9tOoU`: Continue + destructive End Quiz). Immediate quit without
   confirmation is not acceptable. (Was flagged below as a future-pass observation — now a
   confirmed requirement.)

Status: ✅ FIXED 2026-07-06 (`9bb91eb`). Freeze mechanism removed entirely (flag + view sync +
timer hold loop); freeze tests inverted to keep-ticking tests. ResultView X shows the w9tOoU
alert; its End Quiz action now calls `endQuiz()` (backend session properly ended — the old X
only reset locally). Full HangsTests green; live sim check: countdown ran behind the settings
sheet (auto-record fired underneath it), Result X → alert → End Quiz → Home.

## Implementation notes (2026-07-06)

- Observation for a future pass: ResultView's top-bar X ends the quiz immediately with **no confirmation dialog** — only the question screen + minimized widget confirm. Not in this issue's acceptance; flag if it bites.
- `recordQuizCompleted()` (totalQuizzes) still only increments on natural completion — consistent with "display nothing extra" for early quits.

## Founder decisions 2026-07-05 (pre-implementation UI approval)

Binding record: `docs/design/ui-proposals-2026-07-decisions.md` (decision 2 + globals G1–G4). Pencil frames update first via #86 — Pencil sync of approved UI; implement only after frame review.
- APPROVED with changes: NO countdown pause while typing (would grant extra thinking time). Early-quit partial stats: record everything, display nothing extra for now.
