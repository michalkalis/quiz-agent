# Issue #83 — Unify the quiz top bar (MCQ vs open/voice divergence)

**Triage:** enhancement · **done 2026-07-06** — implemented per G1 binding layout; 507 HangsTests green; on-sim screenshot verify PASS (MCQ + voice vs frames b8zObz/f9csl). Settings chip opens the full Settings sheet as an interim target — #68 repoints it to the session-settings menu (decision 6, Variant A). ResultView still uses the old `HangsQuizNav` (close + brand + counter) — reconcile in #84's Result rework. Replay/mute join the bottom timer strip in #85.

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

⚠️ Superseded 2026-07-05 by binding decision G1 (docs/design/ui-proposals-2026-07-decisions.md): top bar = close + settings, timer at BOTTOM — the prose below is historical context only.

1. Collapse the two per-mode headers into one treatment: a single muted category label (+ the shared `NN / NN` counter already in `HangsQuizNav`) — drop the loud MCQ "CATEGORY · QUESTION N" section label.
2. Ensure progress bar + answer-timer pill render consistently in both MCQ and open modes.
3. Keep exit (close) where it is. No streak/score in the top bar (never was — good).

Cross-refs: **#85** (replay button + mute control — also edits `QuestionView` chrome; **sequence these two, don't run in parallel**), #68 (driving defaults), #82 item 6 (light-mode timer-pill contrast — fold if touching the pill).

## Acceptance

- [x] MCQ and open/voice questions render the **same** top bar — per G1: close + settings + progress bar; `NN / NN` counter in the shared meta row; timer at the bottom strip (both modes, `HangsQuizTopBar` + `metaRow` + `timerStrip` in QuestionView)
- [x] Category is a single muted treatment (muted mono meta row in both modes; loud pink MCQ section label removed)
- [x] Answer-timer pill + progress bar behave identically in both modes (shared `timerStrip`/`HangsProgressBar`; verified on-sim in both + ViewInspector suite "unified chrome in both modes")
- [x] Screenshot-verify: MCQ vs open header visually consistent (on-sim 2026-07-06, VISUAL: PASS vs frames b8zObz/f9csl)
- [x] ViewInspector tests extended (settings/counter/timer-strip present in both modes); `.stableDump` snapshot baselines re-recorded (⚠️ re-record surfaced for founder sign-off — diff = new `showQuizSettings` view state only); RS unit-level guards green (507 tests)

## Founder decisions 2026-07-05 (pre-implementation UI approval)

Binding record: `docs/design/ui-proposals-2026-07-decisions.md` (decision 4 + globals G1–G4). Pencil frames update first via #86 — Pencil sync of approved UI; implement only after frame review.
- Variant A (muted category above question). G1 binding layout OVERRIDES the mockup: top bar = close + settings; timer at the BOTTOM near the action row; scrollable question text; modest record/skip/type buttons.
