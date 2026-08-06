# Issue 147: Total judge-panel failure fabricates a word-count score that the pack ship gate treats as a real judgment

**Triage:** bug · needs-triage
**Priority:** serious
**Source:** architectural audit 2026-08-06
**Reversibility:** a
**Created:** 2026-08-06

## Context

The scoring stage is the pipeline's single blocking quality gate: it is the only step that drops a generated question before a paid pack is delivered. Its documented contract is that an *unscored* question is kept — absence of a judgment is deliberately not treated as a failed judgment. But when the whole judge panel fails (provider outage, exhausted credits, throttling past the one retry), the scorer never returns "unscored": it substitutes a deterministic answer-length heuristic and hands it to the gate as if a judge had spoken. Under exactly the provider incidents this project hits repeatedly, the gate silently becomes "is the answer short?", and nothing in the stage's structured output says the judges were down.

## Confirmed findings

### 1. `score_question` fabricates a synthetic judge entry when every judge fails (serious, verified)

`apps/quiz-pack-api/app/scoring/multi_model_scorer.py:827-833` — when no judge returned parsed dimensions, the result list is not left empty:

```
if not results:
    results.append({
        "model_name": _DETERMINISTIC_DIMS_KEY,   # "deterministic"
        "scores": _attach_dims({}),
        "overall_score": float(brevity),
        "reasoning": "deterministic-only (no LLM result available)",
    })
```

`brevity` (`multi_model_scorer.py:722`) is `compute_answer_brevity` (`multi_model_scorer.py:86-110`), a pure word-count/tail heuristic returning 10 (≤5 words, no explanation tail), 7 (≤ word cap, no tail), 3, or 1 (over the cap *and* a tail). It says nothing about factual accuracy, ambiguity, or interest.

This branch is genuinely reachable: `_score_dimension` / `_score_panel` (`multi_model_scorer.py:641-698`) swallow all exceptions and return `None` after a single retry, so a panel-wide outage produces zero parsed results rather than a raised error.

### 2. The ship gate averages that synthetic entry as a real verdict (serious, verified)

`apps/quiz-pack-api/app/orchestrator/stages/scoring.py:275-288` — `_gate_reason` documents the invariant it cannot actually enforce:

```
"""Unscored questions (empty ``model_scores``) return None — absence of
a judgment is not a failed judgment, so they are kept."""
...
if overalls and (sum(overalls) / len(overalls)) < MIN_OVERALL_SCORE:
    return f"overall_below_{MIN_OVERALL_SCORE}"
```

`overalls` collects every entry carrying an `overall_score`, including the synthetic one, and nothing downstream filters on `model_name == "deterministic"` (the constant is referenced only at its definition and at the append site, `multi_model_scorer.py:189` and `:829`). So the "empty `model_scores`" path the docstring describes is in practice unreachable, and the gate silently switches criteria.

**Impact.** With `MIN_OVERALL_SCORE = 3.0` (`scoring.py:52`), the dominant real failure is fail-open: brevity 7 or 10 clears the floor, so during a judge outage every question ships and the customer receives an ungated paid pack. Brevity 3 also clears it; only the brevity-1 case (over the word cap *and* an explanation tail) drops, which would mass-drop and push the order under its top-up floor for a reason nothing in the step log explains. Either way the two files document mutually inconsistent invariants, so reading one without the other yields a wrong model of the gate.

### 3. No judge-failure signal in the stage's structured output (serious, verified)

`apps/quiz-pack-api/app/orchestrator/stages/scoring.py:262-272` — `StageResult.info` carries `scored`, `dropped_low_score`, the veto/craft/undated counters, and nothing about judges failing. A panel outage is therefore invisible in the step log that #139 (pack generation hang observability) exists to make trustworthy.

Calibration: individual judge failures *are* `logger.warning`-ed inside `score_question`, so the incident is recoverable from raw worker logs. It is the structured, per-order stage record — the thing the sweep, Sentry contexts and any post-hoc order audit read — that is silent.

Not tracked elsewhere: #143 (judge-panel cost) and #142 (non-JSON provider response) are different seams, and no decided constraint covers this behaviour.

## Proposed approach

Confined to the scoring seam — `multi_model_scorer.score_question` plus `ScoringStage._gate_reason` / `StageResult.info`. Independent of the concurrency and cost workstreams.

1. **Make a panel outage read as "unscored, kept".** Either stop emitting the deterministic entry as a scored verdict (return an empty judge list) or emit it under a shape the gate provably ignores. Whichever is chosen, the deterministic answer-length heuristic must never contribute to the gate average. Keep the entry available to advisory review tooling if useful — `ScoringStage` already copies per-model overalls into `ctx.scores` for audit (`scoring.py:175-181`) and that map is not a gate input.
2. **Make the invariant true at the point that states it.** `_gate_reason` should be the single place that decides what counts as a judgment, and its docstring must describe what the code actually does under a judge outage.
3. **Surface the outage.** Add a judge-failure count (questions that reached the gate with no real judgment) to `StageResult.info`, so an ungated pack is legible in the order's step log rather than only in raw worker logs.
4. **Decide the policy explicitly, with the founder.** "Ship unjudged questions during an outage" is a product call, not an implementation detail. This plan's default — keep, and record loudly — matches the existing documented invariant; the alternative (fail the stage when the whole panel is down) is a founder decision and should be asked interactively, not buried here.

## Done criteria

- [ ] A test drives `score_question` with every judge failing and asserts the gate does **not** drop or keep questions on the basis of answer length: two questions differing only in answer word count (one brevity 10, one brevity 1) get identical gate outcomes.
- [ ] A test asserts `_gate_reason` returns `None` for a question whose only score entry originates from the judge-failure path — the docstring's invariant now exercised by a reachable case.
- [ ] `StageResult.info` from a run with a fully failed panel reports a non-zero judge-failure count; a run with healthy judges reports zero.
- [ ] Grep confirms no remaining consumer treats the deterministic entry as a judge verdict in any gating decision (advisory/telemetry uses are fine and explicitly noted).
- [ ] Existing scoring tests still pass with real judge scores unchanged — normal-path gate behaviour is untouched.
- [ ] quiz-pack-api suite green (`LLM_GATEWAY=direct` pinned, per the test-gate hermeticity constraint).
- [ ] Founder answered the policy question in item 4 and the chosen behaviour is recorded in this file.
