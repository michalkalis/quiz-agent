# Issue 142: pack_30 generation call dies on non-JSON provider response (OpenRouter)

**Triage:** bug · fixed (agent-side)
**Reversibility:** a
**Status:** Fix shipped 2026-08-05 — both generation `ainvoke` call sites (free-text batch + structured MCQ sub-batch) now retry exactly once on `json.JSONDecodeError` and log the raw body head + slice around the error position (open question 1: raw-body capture; open question 2: bounded retry). A second failure propagates as before; the 20-min stage belt still caps the stage. Sub-batching for pack_30 (open question 3) NOT done — needs eval data + founder approval. Confirm the Cloudflare/proxy theory from the logged body on next occurrence.
**Filed:** 2026-08-04 from the first fully-observable pack_30 run (#139 — pack generation hang observability made it visible).
**Created:** 2026-08-04

## What happened

With #139's observability deployed, the founder's pack_30 order `7dbef479…` (language sk) ran a clean attempt and failed loud in the `generating` stage after ~6 min of real model work:

- `JSONDecodeError('Expecting value: line 1527 column 1 (char 8393)')` — full stack in Sentry (issue 138791627): `GenerationStage.run` → `generate_questions` → `_generate_batch` line 870 = **inside `generation_llm.ainvoke(...)`**, i.e. the OpenAI/LangChain client failed to decode the provider's **HTTP response body**. This is NOT the app's own `_parse_response` (that one catches `JSONDecodeError` and returns `[]`).
- Reading: OpenRouter returned a 200-ish response whose body wasn't JSON — typically a Cloudflare/HTML error page or a truncated body on a very long request (this call runs 6+ min). The SDK's `max_retries=2` retries status errors, but a garbage 200 body is raised, not retried.
- Generation model: `GEN = claude-fable-5` via OpenRouter (#134 frontier stack); single 30-question batch → very long request, which raises the odds of hitting a proxy timeout page.

## Open questions (root-cause first, per repo rule)

1. Capture the raw non-JSON body on next occurrence (wrap the generation `ainvoke` to log `response` text on `JSONDecodeError`, or enable httpx debug for the worker) — confirm the Cloudflare/proxy-page theory before changing anything.
2. If confirmed transient: is one app-level retry of the generation call (single re-invoke on `JSONDecodeError`) the right minimal fix? Keep it bounded — the stage belt (20 min) still caps the stage.
3. Longer term: should pack_30 generate in sub-batches (like `_generate_mcq_sub_batches` does for MCQ)? Shorter calls are less likely to hit proxy limits, and one bad response loses 10 questions, not 30. Needs eval data + founder approval per `feedback_no_model_swaps_without_approval`.

## Context

- pack_10 orders have delivered fine; this is the first pack_30 through the pipeline. The founder's order carries 2 remaining manual retries (admin path, no charge).
- The 2026-08-03 original silent hang and this failure are DIFFERENT failure modes at the same call site — the hang was the missing client timeout (#139, fixed), this is response-body decoding.
