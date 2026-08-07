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

## Round 1 results (founder rated 2026-08-07, PDF export; 28/30 rated, mean 4.6)

Per-arm means (raw → dedup-corrected, dropping "already saw this fact" repeats):

| arm | raw | corrected | n |
|-----|-----|-----------|---|
| free (v5) | **6.3** | **6.1** | 10 → 9 |
| old (v3) | 4.1 | 4.5 | 9 → 8 |
| craft (v4) | 3.3 | 4.8 | 9 → 5 |

Correction needed because the 3 arms share facts by design → the same fact
appeared up to 3× in one shuffled page; founder scored repeats 1–3
("uz bola"). Shuffle order made craft absorb most repeat penalties (q12,
q21, q22, q24 all late duplicates). **free (v5) wins on both raw and
corrected** — the constraint-density hypothesis holds. craft (v4, MORE
constraints) ≈ old on corrected; adding constraints didn't help.

**Cross-arm founder themes (prompt-independent, hit every arm):**
1. **Answerability/deducibility** — dominant complaint ("kto to má vedieť
   a prečo"): facts too niche to know OR deduce; a good question must be
   guessable, not a random-fact lookup (q04, q06, q08, q10/18/24, q11, q23).
2. **Two-option comparison gimmick is transparent** — the surprising option
   is always correct, so the answer is predictable (q01, q02, q17, q27=2/10
   "úplne jasná odpoveď aj bez znalosti").
3. **Repeats within a sitting** rated 1–3 — production packs need
   fact-level dedupe (known residual in dedup.py now founder-confirmed).
4. **Open answers hard to produce/verify by voice** (q25); non-native
   impossible (q14 'eunoia' = 2/10).
5. **Questionable sources** (pingdom blog, q19).

**Pipeline bugs surfaced (independent of prompt arm):**
- **q26 (logic puzzle, free arm): WRONG answer shipped.** "Thursday" fails
  the puzzle's own logic (statement is consistently false on any lying day
  Mon–Wed; Thursday is a contradiction). Explanation field contains ~2 pages
  of raw model rambling that never converges — verify stage passed it, and
  the rating page rendered the full loop. Founder still gave 6 (!) but
  flagged "vysvetlenie je mega dlhé".
- **Puzzle-type topics get nonsense sources**: q26 and q29 (lateral
  thinking) both cite the Mariana Trench Wikipedia page. Fact-sourcing
  pipeline doesn't fit non-factual topics; exclude "logic puzzles"/"lateral
  thinking" style topics from the fact pipeline until they get dedicated
  handling.
- Note: actual round topics differ from the seed-153 list above (8/10
  forced topics yielded 0 facts → resample; see TODO follow-up).

**Verdict:** v5-free is the best arm but absolute level (~6) is below bar
and the top complaints are fact-selection + format-predictability, not
prompt wording. Plan allows one in-phase iteration before Phase B.

## State

- [x] Phase 0 hygiene landed (commit `e5e2ec01`)
- [x] v4 + v5 prompts drafted; CLI levers --no-judges / --gen-prompt-file / --direct / --topics / --dump-facts / --facts-file
- [x] Arms generated 2026-08-07 (old 12q · craft 11q · free 11q; shared facts.json, 88 facts; *.usage.json per arm — NOTE: generation-stage tokens missing in this round's usage files, proxy fix `a41ef38f` landed after; verification-only numbers are valid)
- [x] rating.html + mapping.json built (3×10, seed 153) → founder rates (~30)
- [x] Founder ratings in (2026-08-07, mean 4.6; free 6.3 / old 4.1 / craft 3.3) → analysis above
- [ ] Founder call: iterate v6 in-phase vs lock v5-free → Phase B
- [ ] Follow-up before Phase B: per-topic sourcing yield (8/10 forced topics → 0 facts, resample covered; see TODO)
