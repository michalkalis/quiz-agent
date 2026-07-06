# Issue #81 — Quiz dialogs & timing fairness: End-Quiz has no Cancel; countdown ticks while typing and behind dialogs; 7s auto-advance escape hatch too small

**Triage:** bug · approved 2026-07-05 · blocked-on-#86

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

- [ ] End Quiz dialog shows Cancel + End Quiz; Cancel returns to the quiz with state intact
- [ ] Answer countdown is paused while the End Quiz dialog (or any sheet) is up
- [ ] ~~Answer countdown pauses (or extends) while the typed-answer input is focused~~ **Superseded 2026-07-05** — no countdown pause while typing; partial-quit stats are recorded but not displayed. See `docs/design/ui-proposals-2026-07-decisions.md` decision 2.
- [ ] "Stay here" hit target ≥ 44pt; touching the result screen pauses auto-advance
- [ ] Existing RS regression scenarios pass (timer-related RS updated if semantics change)

## Founder decisions 2026-07-05 (pre-implementation UI approval)

Binding record: `docs/design/ui-proposals-2026-07-decisions.md` (decision 2 + globals G1–G4). Pencil frames update first via #86 — Pencil sync of approved UI; implement only after frame review.
- APPROVED with changes: NO countdown pause while typing (would grant extra thinking time). Early-quit partial stats: record everything, display nothing extra for now.
