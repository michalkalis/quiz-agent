# #153 — Generation pipeline mega review (models × judges × facts, blind-rated)

**Triage:** quality · planned
**Status:** Plan approved in-chat 2026-08-07 (founder answered the 3 design questions). Execution = fresh session(s), driver **Fable 5, effort `high`** (not `max` — the design is fixed here; the open craft work is prompt engineering in Phase A, which `high` covers).

## Why

Founder rated the 2026-08-07 Bedrock dry-run batch **6.8/10** (23/27; data: this file's sibling analysis + memory `project_bedrock_batch_ratings_2026_08_07`). Complaints were mostly **batch-level** (13+13 topic monotony, 4 duplicate pairs, 6/8 T-F, ambiguous open answers, listicle sources). Judge panel showed **no correlation with founder taste for the second time** (Spearman −0.31 now; +0.107 on 2026-08-06 pilot). But every prior conclusion is confounded: models, providers, and prompts changed together. Founder directive: **stop drawing conclusions from confounded runs** — isolate one factor at a time, blind-rate, compare. Question quality is the single most important aspect of the app.

## Success criteria

Founder-blind-rated evidence answering, with per-arm means and costs:
1. Which generator model (Bedrock vs OpenRouter frontier set) produces the best-rated questions?
2. Do judges add value — does judge-selection beat random selection from the same pool? Does the judge *panel provider* matter? (Random arm = no range restriction → clean judge-validity correlation.)
3. Fact-sourced vs direct (fact-free) generation: which rates better, and what does end-of-pipe fact verification catch in each?
4. Locked, per-model-validated generation prompt (Phase A) BEFORE the big matrix, so prompt changes don't contaminate the factor comparisons.
5. Cost per delivered question per arm (feeds #143 — pack COGS reduction).

## Constraints

- Founder rating capacity: **150–200 questions total**, split into 2–3 sittings. Blind: no provenance visible; mapping file kept out of the rating page.
- **OpenRouter credit is scarce** — check balance at session start; hard cap ~$10 for the whole experiment; Bedrock is covered by AWS credit, so volume skews to Bedrock. Answerability stays on OpenRouter v4-flash everywhere (locked decision, ~$0.008/pack).
- Model swaps in prod still need founder approval — this experiment IS the eval data for that decision (`feedback_no_model_swaps_without_approval`).
- Generation = English only. All runs `--dry-run` (no Postgres writes), durable JSON per arm in `docs/testing/runs/153-<arm>/`.
- Composition rules from Phase 0 apply to every arm identically.

## Phase 0 — pipeline hygiene (must land before any generation)

Founder-approved fixes from the 2026-08-07 analysis. Without these, batch-level noise drowns the per-arm signal.

1. **Batch composition rules** (deterministic, no LLM): max 2 questions per topic per 30-pack (⇒ sample ≥12–15 topics); T-F cap (~2 per 30); a fact may be used **once** per pack — dedup across topup rounds AND across formats (open vs MCQ of the same fact currently slips through; 4 dup pairs in the rated batch).
2. **Fail-loud sourcing**: a topic yielding no facts triggers topic resampling (and alternate source lookup — facts exist for nearly everything, per founder), never silent absorption by the surviving topics.
3. **Source credibility**: allowlist/score reputable domains for fact sourcing; listicle-grade sources (sdbif.org-class) demoted or dropped.
4. **Direct-generation flag**: the fact-free path already exists implicitly (`generation.py` accepts `source_facts=None`); add an explicit order/CLI switch that skips fact gathering while keeping end-of-pipe verification. This is the founder's "reverse flow" — LLM unconstrained by web-found facts, verified afterwards.
5. **Per-stage cost logging**: per-call token counting by stage and provider (existing TODO item; #143 needs it too). Required for success criterion 5.
6. **Rating-page builder into the repo** (currently only in a dead session scratchpad: `build_page.py` + `template.html`): port to `apps/quiz-pack-api/scripts/rating_page/`, **fix the broken JSON export** (founder had to export PDF; PDF truncates long comments), keep localStorage persistence. Input = shuffled multi-arm JSON with hidden arm ids.

Existing tests stay green; new rules pinned by unit tests (composition caps, cross-format dedup, resample-on-empty-topic).

## Phase A — generation-prompt review (small blind round, ~30 ratings)

Scope: the generation step ONLY. Everything else frozen (Bedrock Kimi K2.5, facts ON, judges OFF — random selection — so the prompt is the only variable).

1. Audit `apps/quiz-pack-api/prompts/question_generation_v3_fact_first.md` against: the four #99 craft defects (stem leaks answer; missing context/referent; units/localization; ambiguous phrasing), the 2026-08-07 findings (unique-answer contract for open questions — one guessable, unambiguously scoped answer; no vague "where"/"which two things"; no artificial bending of simple questions), and T-F/format guidance.
2. Produce revised prompt(s) with **per-model-class variants**: goal+constraints style for strong reasoning models, more prescriptive for models that need explicit instructions. Validate each arm's prompt renders sensibly for its model before spending tokens.
3. Blind round: ~15 old-prompt + ~15 new-prompt questions (same topics, same model, interleaved, shuffled) → founder rates → lock the winner. If the new prompt loses, iterate once within this phase before Phase B — never mid-matrix.

Closes the prompt half of #99 (rubric half of #99 folds into the judge verdict after Phase B).

## Phase B — the matrix (~120–130 unique questions)

All arms: Phase-A locked prompt, Phase-0 composition rules, verification ON, per-arm cost recorded. Overgen ×3 on Bedrock arms, ×2 on OpenRouter arms (credit).

**B1 — generator models** (fixed: facts ON, judge selection ON with Bedrock panel), ~10 delivered q/arm:
- Bedrock: Kimi K2.5 · GLM-5 (both available and credit-covered)
- OpenRouter: 2–3 best available frontier models — candidates from prior evals: GLM-5.1, Gemini (current Pro), Kimi K3; resolve exact catalog IDs + prices at session start, pick per founder's "2–3 most suitable" with the credit cap in mind.
- ≈ 50 ratings.

**B2 — judge value** (fixed generator: Bedrock Kimi K2.5; ONE overgenerated pool ×3, generation cost shared), 3 selection arms × 12:
- top-12 by Bedrock panel (DeepSeek V3.2 + GLM-5) · top-12 by OpenRouter panel (pick 2 strong judges) · random-12.
- Arms may overlap (same question selected by two arms) — dedupe in the rating page, reuse the score; expect ~30 unique ratings.
- Analysis: per-arm mean (does judge selection beat random?) + judge-vs-founder Spearman **on the random arm** (unrestricted range — the clean validity number).

**B3 — facts vs direct** (fixed judges: Bedrock panel), 2 generators × {fact-sourced, direct} × 10:
- Generators: Bedrock Kimi K2.5 + the best OpenRouter model from B1 (run B3 after B1 generation, before rating if needed — or pick by prior eval if scheduling forces it).
- Verification runs on all four cells; record verification failure rates (direct-mode hallucination rate is a first-class result).
- ≈ 40 ratings.

Total ≈ 120 unique + Phase A 30 = **~150**, ceiling 200 leaves slack for a Phase-A iteration.

**Blinding mechanics:** each sitting = one shuffled rating page mixing arms; `mapping.json` (question-id → arm) lives only in `docs/testing/runs/153-…/`, never in the page. Question topics drawn from the same enlarged topic pool for all arms so topic taste doesn't proxy for arm.

## Analysis & decisions it feeds

- Per-arm founder mean ± sd, top/bottom examples; incident counts (duplicates, ambiguity complaints) per arm.
- Judge validity (B2 random-arm correlation) → keep judges as fact-check-only gate, keep full panel, swap panel, or build a founder-calibrated judge (36+23+~150 ratings as few-shot corpus).
- Generator model choice per provider + whether Bedrock-hosted quality holds up.
- Facts vs direct default (or hybrid: direct-generate, fact-verify, source-attribute).
- Cost per delivered question per arm → #143 decisions.
- Report: tight markdown in chat; artifact only if founder asks.

## Session plan (fresh sessions, Fable 5 @ high)

- **S1:** Phase 0 + Phase A prompt work + Phase A generation + rating page → founder rates sitting 1 (~30).
- **S2:** lock prompt, Phase B generation (B1+B2+B3) + pages → founder rates sittings 2–3 (~120).
- **S3:** analysis + recommendations + founder decision round (interactive), then prod config changes only after founder approval.

Durable state after every step (`docs/testing/runs/153-*/` + this file's checklist), so any session can resume cold.

## Checklist

- [ ] Phase 0.1 composition rules + tests
- [ ] Phase 0.2 fail-loud sourcing + resample
- [ ] Phase 0.3 source credibility allowlist
- [ ] Phase 0.4 direct-generation flag
- [ ] Phase 0.5 per-stage cost logging
- [ ] Phase 0.6 rating-page builder in repo, JSON export fixed
- [ ] Phase A prompt audit + variants
- [ ] Phase A blind round generated → founder rated → prompt locked
- [ ] B1 generated · B2 generated · B3 generated
- [ ] Sittings 2–3 rated
- [ ] Analysis + recommendations delivered
- [ ] Founder decisions recorded; prod changes gated on them
