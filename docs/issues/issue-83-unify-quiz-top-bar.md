# Issue #83 — Unify the quiz top bar (MCQ vs open/voice divergence)

**Triage:** enhancement · needs-triage (founder-approved 2026-07-03 from UI/UX review)

**Created:** 2026-07-03 · **Founder:** Michal · **Source:** UI/UX review 2026-07-03 (P1 design decision, founder-approved)

**Severity:** low-medium — visual/consistency, no functional bug. Driving-first: a predictable, minimal quiz HUD matters for at-a-glance use.

## Decision (founder-approved)

One unified top bar for **both** MCQ and open/voice questions: **progress bar + question counter + answer timer + exit** — nothing else. Category is de-emphasised (muted, or moved into the question intro moment), not a loud header element. Matches the competitor standard (Duolingo/Kahoot/Sporcle keep the in-quiz chrome minimal).

## Current state (code-verified)

Good news: the outer chrome is already **mostly shared**, so scope is smaller than the review implied.

- **Shared top chrome, used by both variants** (`QuestionView.swift:81-94` `topChrome`): `HangsQuizNav` close + `NN / NN` counter (`HangsChrome.swift:80-112`) → `HangsProgressBar` pink capsule (`HangsChrome.swift:117-134`) → error banner → `supportRow` timer pills.
- **Timer pill** — `supportRow` (`QuestionView.swift:139-160`) + `timerChip(...)` (`:162-175`); renders "THINK"/"ANSWER Ns", fades in during `.askingQuestion`.
- **The actual divergence is only the category/question-number label under the chrome:**
  - MCQ: `mcqQuestionHeader(question:)` — loud pink `HangsSectionLabel` "CATEGORY · QUESTION N" (`QuestionView.swift:246-259`, called `:196-198`).
  - Open/voice: lowercase pink category inline in `voiceBody` (`QuestionView.swift:263-318`, category `:271-280`) — no question number.

> Note: the review's screenshots (shots 11 vs 16) read as "MCQ has no timer/progress bar". The chrome code is shared, so any missing timer/progress in MCQ is a phase/visibility difference (e.g. MCQ not entering `.askingQuestion` the same way), not two separate bars. Confirm on-sim during work and make timer + progress behave identically in both modes.

## Recommendation

1. Collapse the two per-mode headers into one treatment: a single muted category label (+ the shared `NN / NN` counter already in `HangsQuizNav`) — drop the loud MCQ "CATEGORY · QUESTION N" section label.
2. Ensure progress bar + answer-timer pill render consistently in both MCQ and open modes.
3. Keep exit (close) where it is. No streak/score in the top bar (never was — good).

Cross-refs: **#85** (replay button + mute control — also edits `QuestionView` chrome; **sequence these two, don't run in parallel**), #68 (driving defaults), #82 item 6 (light-mode timer-pill contrast — fold if touching the pill).

## Acceptance

- [ ] MCQ and open/voice questions render the **same** top bar: progress bar + `NN / NN` counter + answer timer + exit
- [ ] Category is a single muted treatment (no loud per-mode section label divergence)
- [ ] Answer-timer pill + progress bar behave identically in both modes (verified on-sim in both)
- [ ] Screenshot-verify: MCQ header vs open header now visually consistent (re-shoot 11 & 16)
- [ ] Existing ViewInspector/snapshot tests updated for the unified header; RS scenarios still green
