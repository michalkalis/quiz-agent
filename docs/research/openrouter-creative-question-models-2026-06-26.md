# OpenRouter Models for Creative Quiz-Question Generation — Cross-Provider Comparison

**Date:** 2026-06-26
**Scope:** Which OpenRouter model should generate quiz questions when the goal is *creativity* — humor, novelty, non-obviousness (the analogy is joke-writing, not fact-retrieval).
**Providers compared:** OpenAI · Google · Anthropic · Chinese/open-weight (Moonshot, Z.ai, MiniMax, DeepSeek, Qwen) · Meta · Mistral · xAI · community creative fine-tunes.
**Feeds:** #72 — question fun/engagement redesign, Phase 6 `GENERATION_MODEL` swap (Lever A, dormant). App is tested in **Slovak + English**.

> **Verification (first-hand, today).** Every slug and price below was read **live from `GET https://openrouter.ai/api/v1/models` on 2026-06-26**. Anthropic IDs/prices were additionally cross-checked against the authoritative `claude-api` catalog. **Fable 5 is confirmed served on OpenRouter** (`anthropic/claude-fable-5`, $10/$50, 1M ctx). The only corrections vs. the research pass were four hallucinated date-suffixes on slugs — fixed here to the real un-suffixed IDs (prices identical). The single dimension that is **not** verified anywhere is **Slovak creative quality** — no benchmark exists for it, for any model.

---

## Two caveats that reframe the whole task — read first

1. **Humor is a hard ceiling for *every* model.** On HumorBench-hard, no model exceeds ~60%. In human-preference tests, an explicit humor-tuned **prompt** beats a model swap. So #72's "make it fun" goal is at least half a **prompt** problem (Lever B — restore the dormant engagement-path machinery) and only half a **model** problem (Lever A — this report). Don't expect a model swap alone to fix boring questions.

2. **No Slovak creative eval exists — for any model.** Every "creativity" number below is English (EQ-Bench Creative Writing v3 Elo, and/or LMArena Creative). Slovak quality is unmeasured industry-wide. The real decision gate is a **native Slovak + English A/B you run yourself**; the documented fallback is generate-in-English → dedicated translate step (Claude/GPT).

---

## Cost basis — $ per 100 finished questions

From the pipeline-economics analysis of `apps/quiz-pack-api`: producing **100 final questions ≈ 52K input + 85K output tokens** on the live v3 prompt (`question_generation_v3_fact_first.md`), **with best-of-N 3× over-generation as currently configured** (300 raw → 10 kept, ×10 calls). **Output dominates**, so cost tracks the **output $/M** most.

> **Formula:** `$/100q ≈ 0.052 × ($/M in) + 0.085 × ($/M out)`
> Disabling 3× over-generation cuts this to ~⅓. Prompt caching on the large fixed prefix lowers it further. **Reasoning/thinking models** also bill hidden reasoning tokens at the output rate → real cost > sticker; creative work doesn't need heavy reasoning, so prefer non-thinking / low-effort modes.

---

## Cross-provider creative ranking — the lead view

Sorted by creative strength for *this* use case (humor / novelty / non-obviousness), not by general reasoning. The best creative model is routinely **not** the top reasoning model.

| # | Model | OpenRouter slug | Creative evidence | $/100q | Ctx | JSON |
|--:|-------|-----------------|-------------------|------:|----:|:----:|
| 1 | Claude **Fable 5** | `anthropic/claude-fable-5` | EQ **#1 (2189)**, LMArena Creative **#1 (1498)** | **$4.77** | 1M | ★★★★★ |
| 2 | Claude **Opus 4.7** | `anthropic/claude-opus-4.7` | EQ **#2 (2184)**, LMArena ~1485 | **$2.39** | 1M | ★★★★★ |
| 3 | Claude **Opus 4.8** | `anthropic/claude-opus-4.8` | top-tier (newest Opus; pre-wired in #72) | **$2.39** | 1M | ★★★★★ |
| 4 | **Gemini 3.1 Pro** | `google/gemini-3.1-pro-preview` | **#1 "LOL Arena" humor**, LMArena ~1485 | **$1.12** | 1M | ★★★★★ |
| 5 | **GPT-5.5** | `openai/gpt-5.5` | EQ **#3 (2028)** — analytical, less playful | **$2.81** | 1M | ★★★★★ |
| 6 | **GPT-5.4** | `openai/gpt-5.4` | EQ ~1965; "dry humor" but "emotionally flat" | **$1.41** | 1M | ★★★★★ |
| 7 | **Gemini 3.5 Flash** | `google/gemini-3.5-flash` | near-Pro creative, much cheaper | **$0.84** | 1M | ★★★★★ |
| 8 | Claude **Sonnet 4.6** | `anthropic/claude-sonnet-4.6` | strong, consistent | **$1.43** | 1M | ★★★★★ |
| 9 | **Kimi K2.6** | `moonshotai/kimi-k2.6` | EQ **1753** — best Chinese, ≈80% of frontier | **$0.32** | 262K | ★★★★☆ |
| 10 | **GLM-5** | `z-ai/glm-5` | EQ **1657** — strong value | **$0.19** | 203K | ★★★★☆ |
| 11 | GPT-5.1 / GPT-5 | `openai/gpt-5.1` · `openai/gpt-5` | strong but unremarkable creative | **$0.92** | 400K | ★★★★☆ |
| 12 | Gemini 2.5 Pro | `google/gemini-2.5-pro` | mid-pack now | **$0.92** | 1M | ★★★★☆ |
| 13 | DeepSeek V3.2 | `deepseek/deepseek-v3.2` | EQ **1511**; #1 OpenRouter roleplay usage (price-driven) | **$0.04** | 131K | ★★★☆☆ |
| 14 | Qwen3.7 Plus | `qwen/qwen3.7-plus` | base ~EQ 1459 — **119 languages** | **$0.13** | 1M | ★★★★☆ |
| 15 | Grok 4.3 | `x-ai/grok-4.3` | "competent but rarely surprising" | **$0.28** | 1M | ★★★★☆ |
| 16 | Claude Haiku 4.5 | `anthropic/claude-haiku-4.5` | mid creative, reliable | **$0.48** | 200K | ★★★★★ |
| 17 | Mistral Large 3 | `mistralai/mistral-large-2512` | no creative bench; EU-language proxy | **$0.15** | 262K | ★★★★☆ |
| 18 | Gemini 2.5 Flash | `google/gemini-2.5-flash` | volume, not a standout | **$0.23** | 1M | ★★★★☆ |
| 19 | MiniMax M3 | `minimax/minimax-m3` | unscored; "creative/conversational"; 512K output | **$0.12** | 1M | ★★★★☆ |
| 20 | Llama 4 Maverick | `meta-llama/llama-4-maverick` | conflicting reviews; SK not tuned | **$0.06** | 1M | ★★★☆☆ |
| 21 | DeepSeek V4 Flash | `deepseek/deepseek-v4-flash` | creative trails — draft layer only | **$0.02** | 1M | ★★★☆☆ |

> Two scales, do not cross-compare: **EQ-Bench Creative v3 Elo** ≈1300–2220; **LMArena Creative** ≈1450–1530. "JSON" = structured-output reliability for batch generation (the pipeline needs valid JSON on every call).

**Not available via the gateway:** **Grok 4.1** — reported the single strongest creative model found (LMArena #1, EQ #3 1708.6) but it is **Discord-only, not on OpenRouter** (confirmed: only `grok-4.20` and `grok-4.3` are served). It cannot be used through the single-gateway design.

---

## Per-provider detail

### Anthropic — the quality ceiling (catalog-verified)
Fable 5 is the creative #1 but at $4.77/100q is 2× Opus and carries always-on extended thinking (latency) + a 30-day data-retention requirement. **Opus 4.8** ($2.39) is the value pick within Claude and is **already pre-wired** as the #72 swap target. Sonnet 4.6 ($1.43) is the cheaper A/B. Haiku 4.5 ($0.48) is mid-creative but a reliable cheap critique/rewrite model.

### Google — best creative-per-dollar
**Gemini 3.1 Pro** is the only non-Claude model in the set with **direct humor evidence** (#1 "LOL Arena", "surprisingly funny") *and* excellent JSON *and* frontier multilingual — at **$1.12/100q**, roughly half the frontier-Claude cost. **Gemini 3.5 Flash** ($0.84) is the high-volume version at near-Pro quality. Its creative *voice* still trails Claude on LMArena, but for witty trivia the humor signal is the relevant one.

### OpenAI — solid, less playful
**GPT-5.4** ($1.41) is the sweet spot (decent dry humor, top-tier JSON). **GPT-5.5** ($2.81) is creative #3 overall but reads analytical rather than playful — strong if you want clean, clever-but-correct phrasing over jokes. o3-/o4-mini are over-structured — skip for humor.

### Chinese / open-weight — the budget standouts
**Kimi K2.6** ($0.32, EQ 1753) delivers ~80% of frontier creativity at ~1/15th of Fable's cost — the budget creative standout. **GLM-5** ($0.19, EQ 1657) is close behind. **DeepSeek V4 Flash** ($0.02) and **MiniMax M3** ($0.12, huge 512K output window) are draft/volume layers. **Qwen3.7 Plus** is the best multilingual bet (119 languages) and the most plausible direct-Slovak candidate — but, like all of these, unproven on Slovak and weaker on creative voice. DeepSeek carries censorship risk on edge topics.

### Meta / Mistral / xAI / community fine-tunes
**Llama 4 Maverick** ($0.06) is cheap but Slovak-untuned (high risk). **Grok 4.3** ($0.28) is competent, rarely surprising. **Mistral Large 3** ($0.15) officially covers Czech/Polish (Slovak **not** listed) — the closest EU proxy. **Community creative fine-tunes** (Magnum, EVA, Euryale, Cydonia, Hermes 4) are **ruled out**: zero leaderboard presence (reputation only), poor JSON/instruction-following by design, English-only, and Magnum's ~2K output cap can't emit batch JSON. Do not use in production.

---

## Recommendation (tiered, cross-provider)

| Tier | Pick | $/100q | Why |
|------|------|------:|-----|
| **Value front-runner** | **Gemini 3.1 Pro** | $1.12 | Only non-Claude with direct humor evidence + excellent JSON + frontier multilingual, at half the frontier-Claude cost |
| Quality ceiling | Claude Fable 5 / Opus 4.7–4.8 | $4.77 / $2.39 | Creative #1–#3; Opus 4.8 already pre-wired |
| OpenAI equivalent | GPT-5.4 | $1.41 | Decent dry humor + top JSON |
| High-volume value | Gemini 3.5 Flash | $0.84 | Near-Pro at lower cost |
| Budget standouts | Kimi K2.6 / GLM-5 | $0.32 / $0.19 | ~80% of frontier creativity, 10–25× cheaper than Opus |
| Ultra-cheap draft | DeepSeek V4 Flash | $0.02 | Volume draft layer + reranker only |
| Multilingual/SK bet | Qwen3.7 Plus / Mistral Large 3 | $0.13 / $0.15 | Test Slovak directly before trusting |

---

## How this lands in #72

- **Lever A (this report):** `GENERATION_MODEL` is config-driven; `LLM_GATEWAY=openrouter` routes the swap. Default lives in `packages/shared/quiz_shared/llm/factory.py`; `claude-opus-4-8` is already in `_REMAP_OPENROUTER`. Adding the chosen slug is the only code change. Current production generation is `gpt-4o` (temp 0.8); both Claude and Gemini 3.1 Pro beat it on creativity.
- **Lever B (out of scope here, but decisive):** restore the engagement-path machinery bypassed since 2026-05-20. Per caveat #1, the prompt fix likely matters more than the model swap.
- **The A/B is a product decision (CLAUDE.md Rule #13 — decide *with* the founder).** Recommended head-to-head: **Gemini 3.1 Pro** (value front-runner) vs **Kimi K2.6** (budget standout) vs **Opus 4.8** (pre-wired ceiling), judged by ear on the same ~10 questions in **Slovak + English** from the live v3 prompt. The founder's hands-free listen (Phase 6b) is the real arbiter — no LLM-judge proxy.

---

## Verification status

- **Verified live today:** all 21 slugs + prices against the OpenRouter models API; Anthropic also against the `claude-api` catalog. Fable 5 confirmed served on OpenRouter.
- **Corrected:** four slugs had hallucinated date-suffixes; real IDs are `moonshotai/kimi-k2.6`, `minimax/minimax-m3`, `deepseek/deepseek-v4-flash`, `qwen/qwen3.7-plus` (prices unchanged).
- **Cross-checked:** EQ-Bench Creative v3 + LMArena Creative top ranks across two passes (live tables are JS-rendered; ranks 4+ less certain).
- **Unverified (the real gate):** Slovak creative quality for every model — run a native SK+EN A/B. No model has been run on the actual v3 production prompt yet.
- **Dead ends (don't re-investigate):** community fine-tunes (no leaderboard presence, poor JSON, English-only, Magnum 2K output cap); the corrupted "Grok-4.1 = EQ 1721.9" llm-stats scrape (mixed metric columns); the "Fable 5 export-suspended" claim (contradicted by the authoritative catalog — Fable 5 is Active).

## Sources
- [OpenRouter Models API](https://openrouter.ai/api/v1/models) — live slugs/prices/context, read 2026-06-26 (authoritative for availability).
- Anthropic model catalog via the `claude-api` skill — Claude IDs/prices/context (authoritative for Claude).
- [EQ-Bench Creative Writing v3](https://eqbench.com/creative_writing.html) — Elo creative ranking (JS-rendered; top ranks via search/WebFetch).
- [LMArena Creative / Hard-Prompts leaderboards](https://lmarena.ai/leaderboard) — separate Elo scale.
