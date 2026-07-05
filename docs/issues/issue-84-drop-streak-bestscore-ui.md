# Issue #84 — Drop streak + best-score gamification from user-facing screens (keep the logic)

**Triage:** enhancement · needs-triage (founder-approved 2026-07-03 from UI/UX review)

**Created:** 2026-07-03 · **Founder:** Michal · **Source:** UI/UX review 2026-07-03 (P1 product decision, founder-approved)

**Severity:** low — product/clarity change. No bug.

## Decision (founder-approved)

Founder: streak + best score are **unnecessary info for the user right now** — remove them from the UI. Per-question result keeps only **correctness + score (points)**. Do **not** relocate best score to the COMPLETE screen (founder explicitly declined — it's still unnecessary info). **Keep the underlying calculation logic** so nothing is torn out and it's reversible ("logika môže ostať a počítať sa"). Fully deleting the logic is acceptable later, but not now.

## Factual correction vs the review report

The review card said "streak + best score" both live on the per-question result screen. Code-verified reality:

- **Per-question result screen** shows **streak** + **running score** (points so far) — not "best score".
- **"Best"** (`bestStreak`) lives on the **Home** screen stats row.
- The COMPLETE screen already shows **neither** (`bestStreak` is computed into its summary model but never rendered — `QuizCompleteSummary.swift:20,63`, dead-for-display).

So "remove streak/best score from the user" spans **two** surfaces: the result-screen streak box and the Home best-streak stat.

## Scope (code-verified anchors)

Remove from UI, keep logic:

1. **Result screen — streak box + streak echo** (keep the score/points box + correctness):
   - Correct branch streak box `ResultView.swift:157-165`; incorrect branch streak box (shows "0 / was N") `:176-184`.
   - Streak echo in subheadline "… streak now N" `ResultView.swift:346-353`.
   - **Keep** the score box (`:166-174` / `:185-193`) and the correct/incorrect banner.
2. **Home screen — best-streak stat:** `HomeView.swift:80-85` (the "best" stat box).
3. **Keep intact (do NOT remove):** `QuizStats.recordAnswer(isCorrect:)` + `bestStreak` update (`QuizStats.swift:11-39`), the capture/persist path (`QuizViewModel.swift:158,163,887-889`). Streak keeps computing silently; only the display is removed.

Out of scope: in-round "3 correct in a row" streak (Kahoot-style) — founder did not ask for it; not a replacement.

## Acceptance

- [ ] Per-question result screen no longer shows a streak box or "streak now N" text; **still shows correctness + score (points)**
- [ ] Home screen no longer shows the best-streak stat
- [ ] `QuizStats` streak/bestStreak computation + persistence unchanged (unit test still green)
- [ ] Snapshot/ViewInspector baselines for ResultView + HomeView updated to the reduced layout
- [ ] Screenshot-verify: correct result, incorrect result, Home

## Founder decisions 2026-07-05 (pre-implementation UI approval)

Binding record: `docs/design/ui-proposals-2026-07-decisions.md` (decision 5 + globals G1–G4). Pencil frames update first via #86 — Pencil sync of approved UI; implement only after frame review.
- Variant B confirmed: remove the whole Home stats row (scope extension founder-confirmed). Motivational sub-texts at most short phrases (copy freeze G3). Keep the current strong correct/wrong visual distinction — the mockup weakened it.
