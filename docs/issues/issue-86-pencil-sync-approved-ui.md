# Issue #86 — Pencil sync of approved UI proposals (2026-07)

**Triage:** enhancement · done
**Status:** **DONE 2026-07-06 — founder confirmed the frame review; design gate lifted.** All 8 Pencil items applied (`54c8f44`); implementation now unblocked in source issues #80/#81/#82/#83/#84/#85/#68/#58 (sequence #83+#85 — shared QuestionView chrome). Created 2026-07-05 from founder approval of `docs/artifacts/planned-ui-proposals-2026-07.html`.

## Why

Founder reversed the workflow 2026-07-05: decisions happen on visuals **before** implementation, not on finished code. The binding decision record is `docs/design/ui-proposals-2026-07-decisions.md` — read it first; it overrides the mockups where they conflict.

## Scope

Update `design/quiz-agent.pen` (Pencil MCP, editor must be open — local session) for every **approved** item:

- [x] 86.1 Unified quiz screen layout per **G1** (binding): top bar = close + settings; timer bottom near action row; scrollable question text; modest record/skip/type buttons. Resolves the #83/#85 top-right conflicts. Covers decisions 3 + 4 (mute in bottom audio strip, minimal replay, Variant A category treatment).
- [x] 86.2 Settings navigation per decision 1 (#80): pinned leading back chip, large-title collapse, mono micro-caps bar title.
- [x] 86.3 End-Quiz dialog + countdown behavior states per decision 2 (#81) — no typing pause, no partial-stats UI.
- [x] 86.4 Home + Result without streak/best-score per decision 5 (#84), Variant B (whole stats row gone) — keep the strong correct/wrong distinction of the current app.
- [x] 86.5 Settings "Session" group + recording-sounds toggle per decision 6 (#68); Home option "image questions" (default OFF).
- [x] 86.6 Paper-cut visual deltas per decision 7 (#82): Home pickers with checkmarks + **multi-select categories**, Call Mode footnote. No skip feedback element.
- [x] 86.7 Contextual sign-in sheet per decision 10 (#58 §9).

Carry-over from #54.1: dark-mode Phase 2 — deliberate dark design via asset catalog (was deferred in issue-54-01-dark-mode.md) — fold into this Pencil pass (2026-07-06).
- [x] 86.8 Home free-plan counter frame(s) per **G2** — coordinate with #87 (free state: remaining questions + time to reset; paid state: TBD from #87).
- [x] 86.9 `[HUMAN]` Founder reviews the updated frames (screenshots in-session); ⌘S save + commit `design/quiz-agent.pen`. ✓ confirmed 2026-07-06.

Out of scope: item 8 (rejected), item 9 (quiz-from-prompt — future feature), item 11 paywall details (deferred to its own pass), any Swift/backend code.

## Constraints

- **G3 copy freeze**: reuse existing app texts; English primary. No new copywriting in frames.
- **G4**: whole-screen perspective — don't port a mockup element onto a screen where it doesn't belong; don't regress parts that work well today.
- One consistent component set across all frames (the mockups drifted — do not copy them 1:1).

## Acceptance

- Every checked item has an updated frame in `design/quiz-agent.pen`, founder-reviewed in-session.
- `.pen` saved + committed.
- Each source issue (#80/#81/#82/#83/#84/#85/#68/#58) can start implementation from its frame + the decisions doc without re-asking the founder.

## After this issue

Implementation proceeds in the existing source issues, in sequence for shared-file conflicts (#83 + #85 both edit QuestionView chrome — sequence, not parallel).
