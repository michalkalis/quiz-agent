# #196 track 196.4 — offline quiz-pack-api helper roles: current model vs Claude

Run 2026-10-10. Decision input: move the offline helper roles off OpenAI onto Claude (direct Anthropic API, Max credit) **only where the output is at least as good** (founder rule: question quality must not drop). Quality-check roles, embeddings, STT/TTS and image generation are out of scope (that's 196.5 or stays on OpenAI).

`eval.py` runs the **production call sites** (same prompts, parsers and guards) with only the model swapped; `results_<role>.json` hold every output. Inputs: `expiry_set.jsonl` (labelled), `otdb_raw.json` (25 live OpenTriviaDB items, first 20 used), hint seeds from `apps/quiz-pack-api/data/hint_image_seeds.json` + 5 added, 10 real silhouettes, 20 real images.

## Result

| Role (env override) | Current | Tested | Decision | Key metric |
|---|---|---|---|---|
| Fact sourcing with web search (`LLM_ROLE_SOURCING`) | gpt-5-mini (Responses `web_search`) | Sonnet 5.5 + Anthropic `web_search` | **switch** | 25 facts / 5 topics vs 21 (gpt dropped 4 it couldn't cite); all 25 stand alone vs ~16/21 (gpt copies Wikipedia sentences verbatim: "It was printed in 1377…", "Its sheer cliffs…"); 0 excerpts contradicted by their page on either (Claude: 21 verified + 4 pages a plain HTTP client can't read); ~34 s vs ~60 s per topic; **19 ¢ vs 13 ¢ per topic** |
| Expiry classifier (`LLM_ROLE_EXPIRY`) | CRITIQUE role (code default gpt-5.6-sol; prod override `bedrock:deepseek.v3.2` per `153-phase-a` notes) | Sonnet 5.5 (+ Haiku 5.5 for reference) | **switch** to Sonnet 5.5 | 27-item labelled set, 2 runs: Sonnet **27/27, 27/27**; gpt-5.6-sol 26, 27; deepseek 26, 26; Haiku 25, 26 (calls standing records "evergreen", so they would never expire). No model ever stamped a "current" question evergreen |
| OpenTriviaDB fact rewriter (`LLM_ROLE_OTDB_REWRITE`) | gpt-4o-mini | Haiku 5.5 | **switch** (tie) | 20/20 faithful on both, 0 echoes the question. gpt-4o-mini: 6/20 leave a broken quote (`…play "Hamlet.`). Haiku: adds correct context (dates, names), 1/20 over the 25-word limit. Role is dormant (not wired in prod) |
| Hint-image validation, vision (`LLM_ROLE_HINT_VALIDATE`) | gpt-4o-mini | Haiku 5.5 | **switch** | "Has text" 20/20 on both (5 paintings + the same 5 with a caption burned in, 5 plain + 5 name-labelled silhouettes). "Too obvious": Haiku flags 5/5 name-labelled silhouettes vs 4/5; it is also stricter on 2 easy paintings (DNA double helix, Moon flag + bootprint), which can mean an extra image retry on easy seeds |
| Topic planner (`LLM_ROLE_TOPIC_PLAN`, still follows CRITIQUE) | gpt-5.6-sol | Sonnet 5.5, Opus 5.5 | **kept** | All three: valid, concrete, no military. But the planner exists to vary the pool across refresh runs, and Claude repeats itself: Sonnet put "Octopus intelligence" in 5/5 runs, Opus "tardigrade survival" in 4/5 and "Saturn" in 4/5. gpt-5.6-sol: 23 unique of 25, broader spread |
| Hint-image question text (`LLM_ROLE_HINT_QUESTION`) | gpt-4o | Sonnet 5.5, Opus 5.5 | **kept** (mixed) | Claude's question text works by voice alone far more often (my count: 8/10 Sonnet, 10/10 Opus vs 4/10 gpt-4o, e.g. "a famous piece of art. What is it?"). But both Claude tiers break the prompt's "2–3 visual clues" rule (4–6 clues, e.g. Titanic: bow pose + iceberg + heart necklace), and Opus names Leonardo/Louvre or James Cameron in the question. Not "at least as good" on the image rule |
| Silhouette question text (`LLM_ROLE_SILHOUETTE_QUESTION`) | gpt-4o | Sonnet 5.5 | **kept** (mixed) | Claude's shapes are more accurate (gpt-4o: Greece came back as no question at all, UK "shields three smaller isles"), but Claude's questions run **63–87 words vs 26–48**. Spoken while driving, that is too long, and it ignores the "1–2 geographic hints" rule |

Tier choice: Sonnet 5.5 for the jobs where reasoning or web research matters (sourcing, expiry, the creative text roles). The founder policy is frontier-class only inside the generation pipeline, which is why expiry is not on Haiku, and the Haiku numbers back that up. Haiku 5.5 for simple jobs that were already on a mini model (the OTDB rewrite, a yes/no vision check). Opus 5.5 was tried only where Sonnet lost, to rule out "wrong tier".

## Caveats

- I judged the free-text items (voice answerability, clue counts, standalone facts, accuracy) myself, without hiding which model wrote what. Being a Claude model, I could be biased toward Claude. Where it mattered, I used deterministic checks: labelled-set accuracy, the `has_text` label, the excerpt-on-page check, word counts, the 25-word limit, and the echo guard.
- Expiry: 2 items ("reigning Premier League / NBA champions") were dropped after the run as ambiguous. A title that changes once a year fits both the "current" and the "semi-stable" definitions. The raw per-run predictions, including those 2, are in `results_expiry.json`. Seven of the nine "current" items are written by hand (marked `synthetic` in the set), because the corpus has almost no current-tense questions. Their answers are placeholders and are not part of grading.
- Sourcing grounding is a word-trigram check (≥ 60 %) of the excerpt against the fetched page. Three pages (history.com, iceland.org, springer) don't serve article text to a plain HTTP client, so they count as "unverifiable", not as "contradicted". The script printed them as `no`.
- Sourcing is the CLI pilot path (`scripts/source_facts.py`), not the order pipeline. The extra ~6 ¢ per topic comes out of the Max credit.

## Spend

≈ **$2.28** total (cap $3). Sourcing $1.61, Opus hint check $0.16, expiry $0.18, topics $0.10, hint/silhouette/vision $0.22, OTDB $0.002. gpt-5.6-sol is priced at an **assumed** $5/$40 per MTok, because it is missing from the price table.

## Rollback

Each switched role has its own secret: `LLM_ROLE_SOURCING=gpt-5-mini`, `LLM_ROLE_EXPIRY=bedrock:deepseek.v3.2` (or `gpt-5.6-sol`), `LLM_ROLE_OTDB_REWRITE=gpt-4o-mini`, `LLM_ROLE_HINT_VALIDATE=gpt-4o-mini`. A Claude role with no `ANTHROPIC_API_KEY` falls back to the gateway route.
