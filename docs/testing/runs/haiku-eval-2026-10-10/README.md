# #196 track 196.3 — answer grader + input parser: gpt-4o-mini vs Claude Haiku 5.5

Run 2026-10-10. Decision input for the founder: should the two live-gameplay AI roles move from OpenAI (`gpt-4o-mini` via OpenRouter, prod today) to Claude Haiku 5.5 (`claude-haiku-5-5`, direct Anthropic API, Max credit)?

## Result

| | gpt-4o-mini (prod) | Haiku 5.5 (default effort = medium) | Haiku 5.5, effort low |
|---|---|---|---|
| **Grader** accuracy (190 cases) | 92.6 % | **98.4 %** | 96.8 % |
| wrong "incorrect" (player cheated) | **9** | 1 | 1 |
| wrong "correct" | 1 | 0 | 0 |
| other misses (partial credit where a full verdict was due) | 4 | 2 | 5 |
| median / p90 latency | 0.80 / 1.46 s | 0.93 / 1.63 s | 0.89 / **1.18 s** |
| cost per 1000 grader calls | $0.128 | $0.158 | $0.139 |
| **Parser** accuracy (39 cases) | 94.9 % | **100 %** | 97.4 % |
| median / p90 latency | 1.67 / 2.30 s | 1.70 / 2.57 s | **1.20 / 1.83 s** |
| cost per 1000 parser calls | $0.145 | $0.237 | $0.187 |

Cost is per model call, from real token usage (gpt-4o-mini $0.15/$0.60, Haiku 5.5 $0.10/$0.50 per MTok; OpenRouter's credit fee not included). Haiku sends ~1.5× the input tokens for the same prompt and spends output tokens on thinking (avg 60 at medium, 22 at low on the grader), so it ends up slightly dearer per call despite the lower list price. Answers that the deterministic layers decide cost nothing on either model.

**Recommendation:** move both roles to Haiku 5.5 at effort `low`. It removes 8 of the 9 "you were wrong" mistakes on correct voice answers, never gave a wrong "correct", and is as fast or faster at p90. The extra cost is pennies per thousand answers and comes from the Max credit.

## Where they disagreed (examples)

| Heard (voice transcript) | Correct answer | gpt-4o-mini | Haiku 5.5 |
|---|---|---|---|
| `Venecuela` (sk) | Venezuela | incorrect | correct |
| `Bratislavy` (sk, genitive) | Bratislava | incorrect | correct |
| `sedum` (cs) | Sedm | incorrect | correct |
| `shakes beer` (en) | William Shakespeare | incorrect | correct |
| `Mendeleev` (en, the person not the element) | Mendelevium | **correct** | incorrect (low: partially_correct) |
| `Paraguaj, super otázka mimochodom` (parser) | answer + rating | rating missed | answer + rating |

The one case all three got wrong: `plávanie na chrbte` for "Znak" (backstroke). Full per-case output in `results.json`.

## What a switch needs (not done here)

- The answer path (`app/hot_path_llm.py`) calls the **OpenAI SDK** client. A `claude-*` id there does **not** reach Anthropic directly: the direct route from PR #323 only covers the LangChain `chat_openai()` path. A switch needs a small Anthropic adapter on the hot path (this eval's `AnthropicAdapter` is the shape), and `JudgeUnavailable` must also catch Anthropic SDK errors.
- Haiku 5.5 rejects `temperature` (400 "`temperature` is deprecated for this model", verified). The adapter drops it; no prompt was changed.
- Prod parser model is `gpt-4o-mini` (`InputParser()` default in `main.py`). The factory's `PARSE = "gpt-5.6-sol"` is not used by quiz-agent.

## Method

- `cases.jsonl` (244 cases, built by `build_cases.py`): questions are real corpus rows (sk/cs from the 2026-09-10 translation review, en from `apps/quiz-agent/questions_export.json`) plus a few from the evaluator prompt and unit tests (source on every case). Player answers are written to mimic voice transcripts: recogniser respellings, sk/cs inflection, paraphrase, numbers in words, sound-alikes that name a different answer, misconceptions, MCQ "druhá možnosť" / "béčko", skip / quit / repeat commands. Only answers with a clear verdict were kept.
- 15 cases never reach a model (sound-alike matcher, MCQ option matcher, parser fast paths) and are excluded from scoring for both sides. Scored: 190 grader (sk 89, cs 60, en 41) and 39 parser (sk 16, cs 11, en 12). Grader accuracy by language: gpt-4o-mini sk 83/89, cs 57/60, en 36/41; Haiku sk 87/89, cs 59/60, en 41/41; Haiku low sk 87/89, cs 58/60, en 39/41.
- Both models run through the real `AnswerEvaluator.evaluate` / `InputParser.parse` code, same prompts; only the client and model id differ. gpt-4o-mini ran under `LLM_GATEWAY=openrouter` (prod parity); Haiku ran direct. One pass per case, concurrency 3, so run-to-run variance is not measured.
- Parser scoring: required intents present, forbidden intents absent, and the extracted answer contains the expected answer (MCQ: resolves to the right option). Observation not counted: gpt-4o-mini classified "can you repeat the question please" as **skip**, which would skip the question; both Haiku arms returned explanation_request.

Reproduce (from `apps/quiz-agent`):

```
LLM_GATEWAY=openrouter python scripts/eval_hot_path_models.py \
  ../../docs/testing/runs/haiku-eval-2026-10-10/cases.jsonl \
  ../../docs/testing/runs/haiku-eval-2026-10-10 \
  --arms gpt-4o-mini,claude-haiku-5-5,claude-haiku-5-5@low --env-file ../../.env
```

Spend: $0.103 total (gpt-4o-mini $0.030, Haiku $0.039, Haiku low $0.034), cap was $1.
