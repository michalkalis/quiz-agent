# Issue 127: Result screen redesign: clipped header, missing correct answer and source on a wrong answer

**Triage:** enhancement · needs-triage
**Status:** Filed 2026-07-28 from the founder's TestFlight field test (three screenshots). Two sub-findings CONFIRMED in code; the header-clipping mechanism is UNPROVEN without the screenshots. The dominant ask is a design pass, not a patch. Needs `/prepare-issue` before an agent run. **2026-07-28: design gate PASSED — founder picked Variant C "Zero-Scroll Deck" with one modification (long content scrolls *inside* the answer/explanation card; the screen chrome itself never scrolls); see [ui-variants-2026-07-28-decisions.md](../design/ui-variants-2026-07-28-decisions.md). Next: Pencil sync, then code.**
**IMPLEMENTED 2026-07-28 (evening):** ResultView rewritten as three fixed zones (no screen-level ScrollView — the header-clip mechanism is structurally impossible): tinted verdict field (chip + inline score/delta + Anton 30 verdict), answer panel (answer at 46pt dominant, "why" explanation inline on BOTH outcomes with internal scroll when long, "hear it" replays the retained feedback audio, source line gated on `sourceUrl` only — the old `if isCorrect` gate is dead), consolidated footer (GlowSweepLine + CmdListenBar + one STAY/RESUME-pill+CTA row; auto-advance semantics unchanged). Nil-evaluation AND empty-answer render one coherent neutral recap state (question stem dominant) — never a blank screen. "Try this question again" formally dropped (closes issue-96:137). New `--ui-test-result-*` seeds; 90 targeted tests green + sim checks (dark/light, internal-scroll-only verified). Open: Slovak strings for the new labels default to English until translated in the catalog.
**Created:** 2026-07-28

## Symptom

Founder, TestFlight, 2026-07-28, three screenshots:

> The result screen does not have a good design. The texts at the top are cut off, and the correct answer is missing when the user answered wrong? On a wrong answer the source is missing too. This screen needs to be rethought — what should be the dominant UI, what can be made less prominent, whether the layout is OK, etc. A design tool will be needed.

Three complaints, one framing: the screen's hierarchy is wrong, not just its pixels.

## Root cause

**1. Source/explanation affordance on a wrong answer — CONFIRMED.**
`ResultView.swift:225` reads `if isCorrect, viewModel.resultQuestion?.sourceUrl != nil` — the "Why is this correct?" ghost button is hard-gated on the user having been right. `sourceUrl` is a `Question` property populated at generation time (`Question.swift:21`), entirely independent of correctness, so the data is there on the wrong-answer path and the UI suppresses it. Introduced verbatim in `ee48ad30` (the Pencil-spec redesign port); the original frames carry the same asymmetry, so this is a design-carried gap, not implementation drift.

**Broader than the gate (missed by the prior investigation).** `Question.explanation` (`Question.swift:25`), `Question.sourceExcerpt` (`Question.swift:22`) and `Evaluation.explanation` (`Evaluation.swift:16`) are rendered by **no view in the app** — a grep across `Views/` returns only `sourceUrl` at `ResultView.swift:65,66,225`. So even on a correct answer there is no in-screen explanation; the only affordance is a full-screen `SourceWebView` sheet, which is unusable while driving. "The source is missing" is a whole-screen gap, not just an `isCorrect &&`.

**2. "The correct answer is missing on a wrong answer" — PARTLY REFUTED, one live path remains.**
The wrong-answer card does render the canonical answer: `ResultView.swift:148-159` passes `secondaryLabel: "THE ANSWER"` / `secondaryValue: revealedAnswer` (`:271-274`, `headlineAnswer ?? correctAnswer`) at 30pt bold ink — more prominent than the user's own answer (26pt, `mutedFaint`). `HangsAnswerComparisonCard` (`HangsQuestionCard.swift:54-88`) renders both rows unconditionally. So the literal claim does not match the normal path.

But the **entire** answer card and stats row sit behind `if showEvaluation, viewModel.resultEvaluation != nil` (`ResultView.swift:37`), and `isCorrect` defaults to `false` when the evaluation is nil (`:262`). A nil `resultEvaluation` therefore renders "MISSED IT." with **no answer card at all** — exactly what the founder describes. `resultEvaluation` is derived from the `.showingResult(question, evaluation)` state payload (`QuizViewModel.swift:330`), so this needs the screenshots (or a log) to confirm or rule out. Do not close the complaint as founder conflation until that is checked. A second candidate: `revealedAnswer` returns an empty string if the backend sends an empty `correct_answer`, which would render a blank row under a "THE ANSWER" label.

**3. "Texts at the top are cut off" — UNPROVEN.**
`HangsQuizNav` + `HangsProgressBar` sit outside the `ScrollView` in a plain `VStack` with no shared overlay, no background and no separator (`ResultView.swift:26-33`); the hero block (verdict chip + "read aloud" + the 52pt headline) is the first scrollable item directly beneath (`:35, 81-105`). Any scroll clips that row flush against the bar, which reads as "cut off under the bar". Contributing candidates, none verified: the 52pt Anton headline uses `lineLimit(1)` + `minimumScaleFactor(0.5)` + `tracking(-2)` (`:91-96`), a known clipping shape for tall custom display fonts; and `CmdListenBar` (`:196-199`) appears and disappears with the command window, resizing the ScrollView viewport mid-screen.

**Refuted contributor:** the prior investigation blamed footer height on the incorrect branch stacking "Stay here" *and* "Resume auto-advance". They are mutually exclusive by construction — `autoAdvanceActive` requires `!currentQuestionPaused` (`:187-190`) and gates "Stay here" (`:216`), while "Resume auto-advance" is gated on `currentQuestionPaused` (`:236`). The wrong-answer footer is in fact strictly **shorter** than the correct one (no "Why is this correct?" row), so footer height cannot explain the clip being worse there.

**What would settle it:** the three founder screenshots, plus a device-sized screenshot of both Result variants driven through `ios-ui-driver` at the smallest supported screen. That upgrades or kills mechanism 3 and decides mechanism 2 in one pass.

## Scope of a fix

**Track A — design pass (GATE: blocks all implementation).**
The founder explicitly asked for a design tool and a rethink of hierarchy. No Result-screen code lands before an approved frame.

- Attach/inspect the three founder screenshots; reproduce both Result variants on-device and diff against `docs/design/frames/X4o4l.png` (correct) / `31AzE.png` (incorrect) — those are from #52.11 (Jun 16) and predate later footer additions, so treat them as stale.
- **Process — founder decision 2026-07-28, applies to every UI issue: HTML variants first, Pencil second, code third.** Generate several *HTML* variants of both Result states (correct / incorrect) answering the visual-hierarchy questions below; the founder reviews them and picks one. Only the chosen variant is redrawn in `design/quiz-agent.pen`, and only then implemented. Never Pencil-first, never code-first.
- **Founder sign-off on the picked variant**, then `⌘S` on the `.pen` (the founder's step) and re-export the two PNGs.

Questions the design session must answer:
- What is dominant — the verdict banner ("NAILED IT." / "MISSED IT."), the answer-comparison card, or the score box? Right now the 52pt headline dominates while the information a wrong answer actually needs (the right answer + why) is second.
- Does the correct/incorrect pair share one layout with swapped emphasis, or genuinely diverge?
- How does the explanation surface: inline text on the card, a collapsible row, or the current full-screen web sheet? Driving-safety and glanceability decide this.
- Where does the pinned nav/progress bar end and scrollable content begin — scroll-aware background, a hairline, or a layout that never scrolls at all?
- Footer chrome inventory: `CmdListenBar`, "Next question", "Stay here" / "Resume auto-advance", "Why is this correct?" — none of these existed in the original frames. What stays, what is demoted, what is cut?
- Is "Try this question again" (drawn on `31AzE`, never built, already logged in `issue-96-ios-mvp-completion.md:137`) still wanted, or formally dropped?

**Track B — implementation, after sign-off.**
- Decide and implement the wrong-answer explanation/source affordance (`ResultView.swift:225`).
- Surface `explanation` / `sourceExcerpt` if the design calls for inline text — currently plumbed through the models but rendered nowhere.
- Fix the header/scroll boundary per the approved layout.
- Rule in or out the nil-`resultEvaluation` path (`ResultView.swift:37`) — if reachable, it needs a defined rendering, not a silently empty screen.
- Re-sync frames into `design/quiz-agent.pen` and re-export `docs/design/frames/X4o4l.png` / `31AzE.png`.

## Founder decisions needed

> **2026-07-28:** resolved by the HTML variant pick — **Variant C "Zero-Scroll Deck", modified**: answer dominates over the verdict; explanation inline within the answer card (scrolling internally when long) and shown on wrong answers too; footer consolidates to one row; "Try this question again" formally dropped. Detail in `docs/design/ui-variants-2026-07-28-decisions.md`.

- **Explanation on wrong answers?** Show the source/explanation on wrong answers too (it is arguably most useful exactly there), or keep the asymmetry as an intentional "bonus trivia for getting it right" reward. Tradeoff: symmetry serves learning; asymmetry preserves the reward feel and keeps the wrong-answer screen shorter.
- **What is dominant?** Verdict banner vs answer card vs score. Founder asked for this to be decided in a design pass, not defaulted by the agent.
- **Inline explanation vs web sheet?** Inline text is glanceable and driving-safe but adds height to an already-tall screen; the current `SourceWebView` sheet is safe to ignore but unusable in motion.
- **Footer consolidation?** `CmdListenBar` / "Stay here" / "Resume auto-advance" / "Why is this correct?" were all added post-frame. Keep as stacked separate controls, or consolidate/demote? Tradeoff: fewer controls fit the viewport, but each was added for a real driving need.
- **"Try this question again"** — build it or formally drop it from the design.

## Related

- [#96 — iOS MVP completion](issue-96-ios-mvp-completion.md) — already logs three of these as isolated pen-parity nits (`:130` CmdListenBar absent from the frames, `:153` auto-advance controls absent, `:137` "Try this question again" never implemented). Not a duplicate: it never framed them as a hierarchy problem.
- [#108 — driving UX papercuts](issue-108-driving-ux-papercuts.md) — item B put the auto-advance countdown inside the CTA (`ResultView.swift:182-206`). Precedent for the design-first gate used here; its footer treatment is settled and is **not** reopened by this issue except as part of the inventory decision.
- [#84 — drop streak/best-score from UI](issue-84-drop-streak-bestscore-ui.md) — removed the streak box from this screen; precedent for "what recedes".
- [#07 — result screen UI/UX review](issue-07-result-screen-ux.md) — DONE, predates the Anton/Pencil redesign entirely (old CarQuiz paths). Historical only.

**Out of scope:** the question screen, the completion screen, and evaluation/scoring correctness. `QuestionView` uses the same pinned-nav-above-ScrollView structure, so if mechanism 3 confirms, check it there — but fix it here first and file separately if it is systemic.
