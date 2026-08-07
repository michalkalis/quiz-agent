# #153 Phase A round 2 — free v6 vs guarded v6 (post-fix iteration)

Founder call 2026-08-07 after round 1 (see `../153-phase-a/README.md`):
iterate in-phase — FIRST fix fact sourcing, THEN re-run free-style prompts
in both flavors, both updated with two new rules.

**What changed vs round 1 (all landed in the same commit series):**

1. **Fact sourcing fixed** — topic-fair budgets + interleaved truncation
   (was: 8/10 topics → 0 facts), Wikipedia covers all topics (was: first 5),
   no opentdb General-bucket filler for topic-scoped orders (was: 48/88
   off-topic generic facts).
2. **Ungrounded questions dropped, not decorated** — no more sibling-fact
   URL stamping (round-1 q26 wrong-answer puzzle / q29 fake Mariana source);
   attribution needs ≥2 shared content words.
3. **Both prompts get the founder's two new rules:** *Winnable answer*
   (knowable OR deducible — "kto to má vedieť a prečo") and *No
   self-answering comparisons* (the transparent which-of-two ban).
4. **Rating page dedupes by fact** (`--dedupe-by-fact`): each source fact
   appears once, arm chosen seeded+balanced — round-1 repeat penalties
   landed asymmetrically on whichever arm shuffled later.

**Arms** (same frozen model config as round 1: gen Kimi K2.5, critique
DeepSeek v3.2, normalize GLM-5, answerability OpenRouter v4-flash,
verification ON, judges OFF, OVERGEN 3):

- `free` = `question_generation_v6_free.md` — v5-free (round-1 winner) +
  the two new contract rules.
- `guarded` = `question_generation_v6_guarded.md` — v6-free + a compact
  RECOMMENDATIONS section (advice, not rules: reveal-first, dead shapes,
  anchoring, T/F cap, batch variety). Tests whether light guidance beats
  pure freedom now that the two biggest complaints are contract rules.

## Topics (seed 154, sampled from the 40 pool topics the founder has NOT
already rated on)

how glass is made · the invention of the piano · the origins of the
alphabet · the science of fermentation · the first computers · the ancient
Olympic games · deep-sea bioluminescence · the history of vaccines · the
Silk Road trade routes · Renaissance fresco painting

## Reproduction

```
cd apps/quiz-pack-api
ENV: LLM_GATEWAY=openrouter, LLM_ROLE_GEN=bedrock:moonshotai.kimi-k2.5,
     LLM_ROLE_CRITIQUE=bedrock:deepseek.v3.2, LLM_ROLE_NORMALIZE=bedrock:zai.glm-5,
     VERIFY_MODEL=bedrock:deepseek.v3.2, OVERGEN_MULTIPLIER=3,
     STAGE_TIMEOUT_SECONDS=2400
arm free:    generate_pack.py --dry-run --no-judges --target-count 12 \
             --topics "<the 10 topics>" --gen-prompt-file question_generation_v6_free.md \
             --dump-facts <run>/facts.json --out <run>/free_raw.json
arm guarded: same + --gen-prompt-file question_generation_v6_guarded.md \
             --facts-file <run>/facts.json --out <run>/guarded_raw.json
page:        scripts/rating_page/build_page.py --arm free=free_raw.json \
             --arm guarded=guarded_raw.json --dedupe-by-fact \
             --out-dir <run> --batch-id 153-phase-a-r2 --seed 154 \
             --title "Hodnotenie otázok — kolo 2"
```

## State

- [x] Sourcing + grounding fixes landed, full quiz-pack-api suite green (872)
- [x] v6 prompts written (free + guarded)
- [ ] Arms generated → rating page built → founder rates
- [ ] Analysis → prompt locked → Phase B
