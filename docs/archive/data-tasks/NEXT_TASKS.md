# Next Tasks — Post Quality Pipeline Implementation

## Context

All 4 phases of the "Improve Quiz Question Generation Quality" plan have been implemented. Backend tests pass (6/6). Gold standard examples need separate human review (see `data/examples/REVIEW_TASK.md`).

## Task 1: Commit All Changes

Stage and commit everything from the quality pipeline implementation.

```
Commit all the changes from the quality pipeline implementation. The changes span 4 phases:

Phase 1: Critique V2 with calibrated scoring, pattern diversity enforcement, brevity guidance, --critique-model flag
Phase 2: Gold standard (50 examples) and anti-pattern (20 examples) libraries, dynamic example sampling, feedback loop script
Phase 3: Fact sourcing layer (Wikipedia, OpenTriviaDB, news, Czech/Slovak sources), V3 fact-first prompt, question rewrite prompt, --fact-first flag
Phase 4: Question health monitor, /api/v1/admin/health endpoint, expires_at/freshness_tag fields, expired question filtering, generation worker, expire script

Use conventional commit format. This is a single large feature — use feat(questions) scope.
```

## Task 2: Verify Phase 1 — Critique Score Deflation

Test that the V2 critique actually produces spread scores instead of all 9+.

```
Generate 10 questions using the updated pipeline and verify score distribution.

Run: python scripts/generate_questions_claude.py --count 10 --best-of-n 2 --difficulty medium -o data/generated/phase1_test.json -v

Expected: Scores should spread across 5-9 range (not all 9+). Check that:
1. Pattern diversity rule is working (at least 4 different patterns in 10 questions)
2. Score normalization is applying the -0.5 penalty when all dimensions >8
3. The V2 critique prompt is being loaded (check verbose output)

If scores are still inflated, the critique prompt may need stronger anchoring.
```

## Task 3: Verify Phase 2 — Dynamic Example Sampling

```
Verify that dynamic example sampling works by checking that different runs get different examples.

1. Start a Python REPL and run:
   from apps.question-generator.app.generation.examples import load_gold_standard, load_anti_patterns
   # Run twice and verify different samples
   print(load_gold_standard(n=5))
   print("---")
   print(load_gold_standard(n=5))
   # Verify anti-patterns load
   print(load_anti_patterns(n=3))

2. Check that prompt_builder injects them:
   from apps.question-generator.app.generation.prompt_builder import PromptBuilder
   pb = PromptBuilder(template_path="apps/question-generator/prompts/question_generation_v2_cot.md")
   prompt = pb.build_prompt(count=5, difficulty="medium")
   # Verify prompt contains dynamically sampled examples (not the old hardcoded 5)
   print(prompt[:3000])
```

## Task 4: Verify Phase 3 — Fact-First Generation

```
Test fact-first generation mode end-to-end.

1. First test fact sourcing alone:
   cd apps/question-generator
   python -c "
   import asyncio
   from app.sourcing import FactSourcer
   sourcer = FactSourcer(enable_web_search=False)
   batch = asyncio.run(sourcer.gather_facts(count=15))
   for f in batch.facts[:10]:
       print(f'{f.topic}: {f.text[:100]}...')
       print(f'  Source: {f.source_name}')
       print()
   "

2. Then test full fact-first pipeline:
   python scripts/generate_questions_claude.py --count 5 --fact-first --best-of-n 2 -o data/generated/fact_first_test.json -v

Expected:
- Stage 0 (FACT SOURCING) should collect 15-30 facts from Wikipedia + OpenTriviaDB + news
- Generated questions should have source_url populated
- Questions should feel more grounded/specific than parametric generation

3. Compare quality: generate 5 questions WITHOUT fact-first and compare subjectively:
   python scripts/generate_questions_claude.py --count 5 --best-of-n 2 -o data/generated/parametric_test.json -v
```

## Task 5: Verify Phase 4 — Health Monitor

```
Test the health monitor and admin endpoint.

1. Start the backend:
   cd apps/quiz-agent && uvicorn app.main:app --reload --port 8002

2. Check startup output — should show QUESTION DATABASE HEALTH CHECK with any alerts

3. Hit the health endpoint:
   curl http://localhost:8002/api/v1/admin/health | python -m json.tool

Expected response includes: level, total_approved, total_pending, by_difficulty, by_topic, alerts

4. Test the expire script (dry run):
   python scripts/expire_questions.py --dry-run

5. Test the generation worker (dry run):
   mkdir -p data/generation_queue
   echo '[{"count": 5, "difficulty": "medium", "reason": "test"}]' > data/generation_queue/pending.json
   python scripts/generation_worker.py --dry-run
```

## Task 6: Test Cross-Provider Critique

```
Test the --critique-model flag for cross-provider critique (generate with Claude, critique with GPT).

python scripts/generate_questions_claude.py --count 5 --best-of-n 2 --critique-model gpt-4o -o data/generated/cross_critique_test.json -v

Expected: Generation uses Claude, critique uses GPT-4o via OpenAI API. Check verbose output shows "Using gpt-4o (openai) for critique".

Note: Requires OPENAI_API_KEY in .env alongside ANTHROPIC_API_KEY.
```

## Task 7: Gold Standard Human Review (Separate Session)

See `data/examples/REVIEW_TASK.md` for full instructions. This should be done in a dedicated session focused on curation.

## Task 8: Run Full Quality Comparison

After all verifications pass, do a proper A/B comparison:

```
Generate 3 batches of 10 questions each to compare quality:

1. Old pipeline (V1 critique, hardcoded examples):
   # Temporarily use old critique by renaming v2
   mv apps/question-generator/prompts/question_critique_v2.md apps/question-generator/prompts/question_critique_v2.md.bak
   python scripts/generate_questions_claude.py --count 10 --best-of-n 3 -o data/generated/comparison_old.json -v
   mv apps/question-generator/prompts/question_critique_v2.md.bak apps/question-generator/prompts/question_critique_v2.md

2. New pipeline (V2 critique, dynamic examples):
   python scripts/generate_questions_claude.py --count 10 --best-of-n 3 -o data/generated/comparison_new.json -v

3. Fact-first pipeline:
   python scripts/generate_questions_claude.py --count 10 --best-of-n 3 --fact-first -o data/generated/comparison_factfirst.json -v

Then compare the three JSON files side by side. Look for:
- Score spread (old should be narrow/high, new should be wider)
- Pattern diversity (new should use 4+ patterns)
- Question length (new should be punchier)
- Source attribution (fact-first should have source_urls)
- Subjective quality (which batch has more "great pub quiz" questions?)
```

## Priority Order

1. **Commit** (Task 1) — preserve the work
2. **Phase 1 verify** (Task 2) — most impactful change, verify it works
3. **Phase 4 verify** (Task 5) — quick to check, independent
4. **Phase 3 verify** (Task 4) — most complex, needs API calls
5. **Gold standard review** (Task 7) — separate session
6. **Cross-provider** (Task 6) — nice-to-have, needs both API keys
7. **Full comparison** (Task 8) — final validation after everything else checks out
