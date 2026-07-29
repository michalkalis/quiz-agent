# Issue 132: TF feedback 2026-07-29 round 2 — MCQ reveal reversal + full-payload translation + deferred answers

**Triage:** wip (tracks A/C/D in-session; B/E design-gated on founder picks)
**Source:** founder TestFlight test 2026-07-29 ~15:47 (build with #131 A–D + D/F picks), 5 findings.

## Tracks

### A — MCQ options must be visible while thinking (P0) — reverses #125 Track A
Founder report: MCQ shows no options for the whole think phase; they flash only after Skip, then the result screen appears. Root cause: NOT a bug — the #125 Track A reveal gate (founder decision 2026-07-28, `b9aa5019`) hides `MCQOptionPicker` while `quizState == .askingQuestion`; the "flash" is the `.skipping` transition latching the reveal one frame before navigation. The "MCQ reveal moment" was an explicitly open founder decision — **decided 2026-07-29: options visible from the first frame** (you can't think about choices you can't see). Fix: remove the reveal-gate machinery in `QuestionView.swift`; ListenBar answer mode still appears only when listening starts; tap-to-answer must work during think. Rewrite the #125 Track C pinning tests to the new intent.

### B — Think-countdown display on MCQ (design-gated)
Replace the `THINK 45s` pill. Variants: [issue-132B-mcq-countdown.html](../design/variants/issue-132B-mcq-countdown.html) — A odpočet v lište (ListenBar pre-listen state, flips to listening) · B prstenec so sekundami · C tenká linka (seconds only in last 10 s). Founder picks → Pencil → code.

### C — Result screen: remove replay-question button + score/streak (decided)
The verdict-band top-right speaker (`readAloudControl`) replays the **question** TTS (distinct from "hear it" = explanation TTS); founder finds it dead/redundant on the result screen → remove. Score + streak in the meta row: founder — noise, remove (supersedes the #131 D one-row-meta compromise; source link stays).

### D — Serve the whole payload in the quiz language (P1) — subsumes #126's decision
Backend translates only the question stem (`serializers.py question_to_dict_translated`); options and `evaluation.explanation` ship raw English (`flow.py`). Fix: one LLM call translates stem+options+explanation at serve time; evaluation matches the user's spoken answer against the same translated options (deterministic pravda/nepravda) — this IS the fix for #126 (founder decision "translate options" taken implicitly by this feedback). iOS: answer card composes "B — Pyramída" from `possibleAnswers` instead of the bare key.

### E — Answers revealed only after the set (design-gated, new feature)
Founder: with a 10-question set, reveal/speak all answers on one screen after the last question; keep per-question reveal as a Settings option. **Supersedes launch decision D4 (2026-06-11, per-question immediate reveal).** Variants: [issue-132E-deferred-answers.html](../design/variants/issue-132E-deferred-answers.html) — ① during set: A silent ack / B verdict-only · ② end recap: C expandable list / D narrated cards (driving) · ③ setting "Odhalenie odpovedí" in the session group (default TBD by founder). Existing `CompletionView` (aggregate score) is the natural base. After picks: /prepare-issue (own scope — quiz flow state machine, voice narration, settings, backend recap payload).

## Open founder decisions
1. Track B pick (A/B/C countdown display).
2. Track E picks: ①A/①B × ②C/②D + default position of the new setting.

## Execution log
- 2026-07-29: variant pages + issue filed `38805813`.
- 2026-07-29: **A+C iOS shipped `72fb7cfc`** — reveal gate deleted (grid from first frame; think-phase tap submits AND stops the think countdown — latent bug the gate had masked), ListenBar gated on `.recording`, verdict-band replay-question speaker removed, meta row = you-said + source only, `mcqLabelled()` composes "B — Pyramída" both directions (key→text, text→key). 57/57 targeted tests green (10 suites), 2 `.dump` baselines re-recorded (diff = removed elements only), sim visual pass incl. long-stem MCQ.
- 2026-07-29: **D backend shipped `d16620d8`** — `translate_question_payload()` one structured call (stem+options+explanation+answer), record persisted on the session (`current_question_translation`), evaluation/result/`GET /question` all read it; MCQ correct→key resolved at serve time so the evaluator is unchanged; drops per-answer `translate_feedback` (2→1 LLM calls/question). 484 backend tests green (+12). **Deployed prod AND staging** (the #131 staging-token blocker doesn't bind this machine's fly auth; staging healthy, 592 approved, runway ok). TF staging build run 30461629086 triggered.
- Residuals: `voice.py` still feeds the ENGLISH stem to Whisper context + the TTS-leakage guard (dead for non-EN sessions — follow-up candidate) · sessions started before the deploy degrade to stem-only translation · `translate_question` now unused by app code (deletion candidate).
