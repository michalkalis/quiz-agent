# #153 Phase A — generation-prompt A/B/C (v3 old · v4 craft · v5 free)

**Design:** everything frozen except the prompt file. Generator
`bedrock:moonshotai.kimi-k2.5`, critique `bedrock:deepseek.v3.2`, normalize
`bedrock:zai.glm-5`, answerability OpenRouter v4-flash, verification ON,
judges OFF (`--no-judges`, ship-gate omitted), Phase-0 composition rules ON.
All arms use the SAME topics (`--topics`, seed 153 sample below) and the
SAME source facts (first arm dumps facts via `--dump-facts`, the others
re-use them via `--facts-file`) — fact variance must not confound the prompt
comparison.

**Arms** (~10 rated each after offline seeded trim, seed 153; total ~30 =
sitting-1 budget):
- `old` = `question_generation_v3_fact_first.md` — prod prompt.
- `craft` = `question_generation_v4_fact_first.md` — targeted fixes for the
  rated defects (see audit below); ADDS constraints.
- `free` = `question_generation_v5_free.md` — founder's 2026-08-07 note
  ("prompty dávajú moc mantinely, otázky pôsobia podobne, generácia má málu
  voľnosť"): only the operational contracts survive (grounding, fair play,
  one defensible answer, spoken delivery, translatability, output format);
  pattern library, craft-guards litany, and gold examples are all removed
  and the model is explicitly told to invent its own shapes. Tests whether
  constraint density itself is what homogenizes the batch.

Rating page built by `scripts/rating_page/build_page.py`; `mapping.json`
stays here, never sent with the page.

## v4 prompt changes (audit of v3 vs founder ratings 2026-08-07 + #99)

1. **New hard rule 3 — one defensible answer** (open questions): stem names
   the answer's exact type and narrows scope until one answer survives;
   vague "where…?"/"which two things…?" banned; self-test = list every
   defensible answer. Evidence: complaints on Q3/Q5/Q15/Q22/Q23 (5 of 23
   rated), e.g. Armstrong "where" (city vs boys' home both true).
2. **"A plain fact stays plain"** (Fun): never dress a lookup in mysterious
   phrasing to fake a reveal — founder called out "jednoduché otázky umelo
   poohýbané" (Q23, 3/10).
3. **"The answer must land"** (Fun): revealed answer must be recognisable to
   a broad player; unknown-person answers killed jazz-hard questions
   (Q2 3/10, Q19 5/10, Q24 5/10) while famous-but-hard answers survived
   (Coltrane 8/10).
4. **T/F last resort, max 1–2 per batch** (Batch variety): baseline had 6 T/F
   of 8 MCQs; founder wants them rare (Q13/Q14 6/10 "menej true/false").
   Deterministic backstop = Phase 0.1 composition cap.

Model-class note: single goal+constraints variant only — every model in the
#153 matrix (Kimi K2.5, GLM-5, GLM-5.1, Gemini Pro, Kimi K3) is
frontier-reasoning class; a prescriptive variant would be speculative work
for models we don't plan to run (founder can request one if a weaker model
ever enters the matrix).

Known residual (documented in `dedup.py`): the same fact arriving from two
different sources with disjoint wording (baseline pair 15/17) is not
separable by any threshold — embedding cosine puts it at 0.735 vs a 0.738
non-dup pair. Watch for it in the rated rounds.

## Topics (seed 153, 10 of 50-topic pool)

the history of coffee · bird migration and navigation · ancient Roman
concrete · monarch butterfly migration · underground fungal networks · the
first computers · the lifecycle of cicadas · the invention of the piano ·
the origins of the alphabet · the human immune system

## Reproduction

```
cd apps/quiz-pack-api
ENV: LLM_GATEWAY=openrouter, LLM_ROLE_GEN=bedrock:moonshotai.kimi-k2.5,
     LLM_ROLE_CRITIQUE=bedrock:deepseek.v3.2, LLM_ROLE_NORMALIZE=bedrock:zai.glm-5,
     VERIFY_MODEL=bedrock:deepseek.v3.2, OVERGEN_MULTIPLIER=3
arm old:   generate_pack.py --dry-run --no-judges --target-count 12 \
           --topics "<the 10 topics>" --dump-facts <run>/facts.json --out <run>/old_raw.json
arm craft: same + --gen-prompt-file question_generation_v4_fact_first.md \
           --facts-file <run>/facts.json --out <run>/craft_raw.json
arm free:  same + --gen-prompt-file question_generation_v5_free.md \
           --facts-file <run>/facts.json --out <run>/free_raw.json
page:      scripts/rating_page/build_page.py --arm old=old_10.json \
           --arm craft=craft_10.json --arm free=free_10.json \
           --out-dir <run> --batch-id 153-phase-a --seed 153
```

## State

- [x] Phase 0 hygiene landed (commit `e5e2ec01`)
- [x] v4 prompt drafted; CLI levers --no-judges / --gen-prompt-file / --direct
- [ ] --topics / --dump-facts / --facts-file wired (CLI part pending cost-logging merge)
- [ ] Arms generated (old_raw.json, new_raw.json, facts.json, *.usage.json)
- [ ] rating.html + mapping.json built → founder rates (~30)
- [ ] Winner locked → Phase B
