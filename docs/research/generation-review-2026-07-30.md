# Question-Generation Deep Review — 2026-07-30

Founder-requested comprehensive review: prompt engineering, pipeline information flow,
model choices, serve-time translation. Method: two Opus agents (code-level prompt
critique with measured token counts; web research of 2025–26 best practice, cited) +
first-hand verification of env/config claims. Companion actions shipped same day:
staging corpus cull to prod's 31 approved rows; translation layer moved to
claude-opus-5 (see git log 2026-07-30).

> **Addendum (same day):** the full fix order below SHIPPED 2026-07-30 — see
> [issue #134 — gen pipeline frontier fix run](../issues/issue-134-gen-pipeline-frontier-fix-run.md).
> Founder model policy: always frontier models; Bedrock channel added (awaits AWS keys).

## Verdict in one paragraph

The pipeline architecture (source facts → generate → verify → score → dedup → top-up)
is sound and matches state of practice. The two things that made the founder see
"divné otázky" were **inventory** (beta served the pre-redesign corpus, now fixed) and
**serve-time translation** (gpt-4o-mini produced calques/agreement errors, now
claude-opus-5). The generation stack itself has accumulated **rule soup** across
#42→#72→#99→#128 (~8k assembled tokens, ~132 imperative lines, duplicated guidance,
live contradictions) and several **wiring defects** where quality machinery silently
doesn't run. Fixing the wiring beats adding any new rules.

## A. Wiring defects (quality machinery that doesn't fire) — highest impact

| # | Finding | Evidence | Fix |
|---|---------|----------|-----|
| A1 | **Quality flags are OFF in both deployed envs.** `GENERATION_MODEL`, `V3_ESCAPE_HATCH`, `GEN_CRAFT_GUARDS`, `VETO_ENFORCE`, `CRAFT_GUARDS_ENFORCE` are env-driven (`app/feature_flags.py`) and **no Fly secret sets them** (verified `fly secrets list`, prod+staging, 2026-07-30). A paid custom pack today generates with gpt-4o and zero #72/#99 guards. Docs claiming the flags were "flipped to standard" refer to local CLI runs only. | `fly secrets list -a quiz-pack-api{,-staging}` | Set the five env vars as Fly secrets on both quiz-pack-api envs (pending #99 Phase 4 model decision for `GENERATION_MODEL`). |
| A2 | **Craft guards never reach the entertainment prompt.** `question_generation_entertainment.md` lacks the `{craft_guards_section}` placeholder, so #99 rules 9–12 are a no-op for every entertainment order even with the flag on. | dispatch `advanced_generator.py:823` | Add the placeholder to entertainment (and kids/themed when registered); assert at load time that fact-first templates contain all injection placeholders. |
| A3 | **Judges score MCQs against a bare key letter.** Scoring and critique interpolate `correct_answer` = "b" without options — surprise/factual-confidence scores are noise, and with `VETO_ENFORCE` on, noise drops questions. | `stages/scoring.py:~129`, `multi_model_scorer.py:122-150`, `advanced_generator.py:1355` | Render options + resolved answer text into both judge prompts. |
| A4 | **MCQ call carries two conflicting output contracts.** Structured output (`MCQBatchOutput`) is bound while the prompt still ships the prose-JSON Response Format + `self_critique` block the schema can't express; craft guard 3 (`why_interesting`) is unsatisfiable on the MCQ path. | `advanced_generator.py:995`, v3 prompt :248/:258 | Strip Response Format + self-critique sections when structured output is bound; add `why_interesting` to `MCQQuestionItem`. |
| A5 | **Veto reads the wrong dimension.** `_ANSWERABILITY_KEYS = ("answerability", "clever_framing")` but `SCORING_PROMPT` emits no `answerability`; `clever_framing` is capped by nine unrelated craft defects → enforced veto ≈ "any craft defect + low surprise → drop", not the documented dead-end-recall veto. | `stages/scoring.py:~76` | Add a real `answerability` dimension (exists in critique_v2) or rename the veto. |
| A6 | **Judge `overall_score` defaults silently.** Missing field → neutral 5.0; unparseable judge dropped with a bare `print` → single-judge gating. | `multi_model_scorer.py:278,292` | Compute overall deterministically from dimensions; fail loud/retry on judge parse failure. |

## B. Rule soup & prompt structure — the founder's "moc informácií" concern, confirmed

Measured (tiktoken, real assembly): common generation call = **~8.0k tokens / 21
sections / ~132 directive lines** (v3 fact-first + facts + guards + MCQ section +
5 gold + 5 anti + 10 avoid + 10 flagged). v2_cot assembles to ~10k.

- Same guidance restated 3–4× ("don't be boring" in 4 places; structural diversity 2×;
  Language Portability copy-pasted into 4 files). Research: instruction overload and
  **contradictions** degrade output on modern models (Anthropic Fable-5 guidance:
  "too prescriptive… can degrade output quality"; OpenAI GPT-5 guide: contradictions
  are the biggest cost). Target: one deduplicated constraint block, ~2.5–3k assembled.
- **Live contradictions:** "exactly ONE clue" vs "anchor every referent"; `year_guess`
  recipe vs year-precision ban; `true_false` quota vs T/F→MCQ rule. Fix by stating
  precedence, not adding text.
- **Negative:positive example ratio is 28:5.** Research: anti-examples mostly teach the
  failure mode ("pink elephant"); Anthropic recommends 3–5 diverse positive examples.
  Cap anti-patterns at 3, drop the hardcoded BAD trio and the OK-tier examples (which
  literally demonstrate the banned "What year did WWII end?" form).
- **Gold standard isn't gold:** 21/53 entries carry founder ratings 5–7 yet are shown
  as "9-10/10 Gold Standard". Filter `human_rating >= 8` (32 remain) — cheapest
  quality lever in the stack.
- **CoT scaffolding (5-step procedure + self-score gate) is counterproductive on
  frontier models** (both vendors now say reasoning models need goal+constraints, not
  steps). Keep a checklist form only if glm wins the model decision.
- **Cost note:** dynamic content (facts, avoid-list) sits at the *top* of the template,
  making the ~8k prefix uncacheable across the five MCQ sub-batch calls. Static-first
  ordering + a cache breakpoint ≈ 5× cheaper generation input on Anthropic models.

## C. Model choices

- Generation default is still **gpt-4o** (2024-era) unless `GENERATION_MODEL` is set
  (see A1). Judges: gpt-4.1-mini + claude-sonnet-4-6; critique: gpt-4o-mini; verify:
  gemini-2.5-flash. The whole stack is one to two generations old; refresh belongs
  with the #99 Phase 4 decision (glm-5.2 vs Opus-class — blind test pending).
- **Self-preference risk:** if generation lands on a Claude model, swap the Claude
  judge for a disjoint family (documented LLM-judge bias).
- Best-of-N ranking uses the weakest model (gpt-4o-mini) against the richest rubric
  (3.9k-token critique_v2). Either shrink the ranking rubric to ~3 dimensions or move
  to pairwise comparison (small judges rank pairs far better than absolute scores).
- Research consensus for the shape: cheap-model N-sampling + **stronger external
  judge** beats both frontier single-shot (on cost) and self-critique (on quality) —
  the current architecture is right; the *assignments* are inverted (weak critic,
  strong generator candidate).
- Judge design: score **one dimension per call** (anchoring bleeds across dimensions
  in single-pass multi-dimension rubrics); port critique_v2's per-band anchors +
  distribution paragraph into `SCORING_PROMPT`. Note: current Claude models reject
  `temperature`, so "judge at 0.3" is not portable to a refreshed judge.
- Per-model prompts: do **not** fork whole prompts. One shared constraint contract +
  ~20-line model-specific process header keyed off `GENERATION_MODEL` (evidence:
  cross-model prompt transfer loses double-digit accuracy; full forks drift — the 4
  Language-Portability copies already did).

## D. Serve-time translation (shipped 2026-07-30)

- Root cause of "divná formulácia" in Slovak play: gpt-4o-mini calques ("zázvorové
  mačky", "farba zrakovej vnímania", "všetky ostatné siedme planéty") served and
  **cached durably** — bad translations persisted forever.
- Fix shipped: whole-payload translation on **claude-opus-5** via OpenRouter
  (`LLM_GATEWAY=openrouter` now set on quiz-agent staging), prompt rewritten for
  idiomatic target-language + related-language-interference guard,
  `TRANSLATION_PROMPT_VERSION` 1→2 orphans all old cached rows. Cost: one-off cents
  per question per language (translate-once-cache-forever).
- Research backing: frontier LLMs lead machine translation (WMT24: Claude first in
  9/11 pairs); small models fall off hardest on mid-resource languages like Slovak;
  serve-time small-model translation of answer-bearing text turns drift into scoring
  bugs. Wordplay/anagram content can't be translated at all — the `language_dependent`
  filter (#128) is the right mechanism; its custom-pack bypass remains open.
- Residual risks (accepted): silent English fallback on repeated failure (Sentry-flagged);
  no code-level cross-check of free-text `correct_answer` vs `explanation` wording.

## E. Keep as-is (verified good practice — don't churn)

Fact-first grounding with per-question sources; reasoning-before-answer JSON field
order; critique_v2's anchor design; deterministic guards in code not prompts;
per-question salvage on structured output; MCQ sub-batching pinned one pattern per
call; dedup as a deterministic post-pass (not prompt context).

## Recommended order of work

1. **P0 – A1**: set quality flags on Fly (paid-pack quality); `GENERATION_MODEL`
   waits for the blind test.
2. **P0 – #99 Phase 4**: founder blind rating → un-parks generation and settles the
   model (and judge-family swap, C).
3. **P1 – wiring fixes A2–A6** (small, surgical, no prompt rewrites).
4. **P1 – example hygiene**: gold filter ≥8, anti-patterns ≤3, delete OK-tier.
5. **P2 – prompt consolidation**: dedupe to one constraint block + precedence rules;
   static-first ordering + cache breakpoints (5× input-cost cut).
6. **P2 – judge redesign**: one-dimension-per-call scoring, options visible (A3),
   pairwise ranking for best-of-N.

Sources: Anthropic prompting guides (Fable 5 / Opus / best-practices pages),
OpenAI GPT-5 prompting guide + reasoning best practices, WMT24 results, SELF-[IN]CORRECT
(AAAI), contrastive-ICL and ICL-retrieval surveys, LLM-judge bias literature
(self-preference, EMNLP 2025 meta-judge), JSONSchemaBench. Full citations in the
research agent transcript (session 2026-07-30).
