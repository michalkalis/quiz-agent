# Independent LLM reviewer for Trubbo UI copy (EN/CS/SK) — model research, 2026-11-04

Read-only web research. Items marked **[unverified]** were not confirmed from a primary source.

## TL;DR ranking (non-Anthropic reviewers)

| # | Model | Evidence (SK/CS) | Access | Cost |
|---|-------|------------------|--------|------|
| 1 | **Gemini 3.1 Pro** (Google) | sk-bench: #1 of 55 on Slovak (72.6 vs GPT-5.5 71.0, Opus 4.6 68.1). WMT26 en-cs human eval: rank 5-6 (75.5), top cluster of off-the-shelf models; WMT26 overall: best off-the-shelf (top cluster in 15/23 pairs) | Google AI Studio key (paid tier only; no free tier for 3.1 Pro) | $2/$12 per 1M (batch $1/$6) |
| 2 | **GPT-5.5 / GPT-6.x Terra** (OpenAI) | WMT26 en-cs: rank 4 (77.1), above Gemini 3.1 Pro; sk-bench Slovak: #2 (71.0). GPT-6.1 Terra (launched 2026-10-26) not benchmarked on cs/sk **[unverified]** | OpenAI API key; also on Bedrock (Marketplace-listed, see Q2) | GPT-6.1 Terra $1/$5 (Bedrock Global); OpenAI direct list price not fetched |
| 3 | **Gemini 3.6/3.8 Flash** | Same family as #1, cheaper; no cs/sk-specific score found **[unverified]** | AI Studio **free tier** | Free (data used for training) or $0.75/$3.75 |
| 4 | Mistral Large 3 / Medium 3.5 (second opinion only) | WMT26 en-cs: Mistral Medium 3.5 rank 12-14 (67.8). Slovak thesis benchmark: Mistral Large 3 = 64/100 (below Gemma 4 26B 70, GLM-5 67) | Bedrock (Large 3); Mistral free Experiment tier | $0.50/$1.50 on Bedrock |
| 5 | Cohere Command A+ / CAT+ | WMT26 en-cs: Cohere CAT+ (fine-tuned) rank 1-4 (79.0), but base Command A+ only 15-18 (61.3) | Cohere API; Command R/R+ only on Bedrock, not A+ **[unverified]** | n/a |

Open-weight models are clearly weaker for cs/sk (sk-bench: best open = gpt-oss 120B at 60.0, 12.6 pts below best closed; WMT26 en-cs: DeepSeek V4 Pro 56.6, Gemma 4 31B 60.1, Qwen 3.6 27B 61.9, gpt-oss 120B 52.1). Do not use Kimi/GLM/DeepSeek/Qwen/Llama as the primary reviewer; at most a cheap extra pass.

**Recommendation:** primary reviewer = Gemini 3.1 Pro (paid, ~$10 for the whole job); second judge = GPT-5.5 or GPT-6.x Terra (different vendor, different errors). Use Gemini Flash free tier only for non-sensitive pre-screening. Bedrock credit is best spent on Mistral Large 3 / gpt-oss as a cheap third voice, not as the main reviewer.

## Q1. Quality evidence for Slovak and Czech

**WMT26 General MT (findings, Oct 2026), human eval, English→Czech** — primary: https://www2.statmt.org/wmt26/pdf/2026.wmt-1.48.pdf (table extracted from the PDF; scores 0-100, rank ranges = statistical clusters):
- 1-4 Cohere CAT+ 79.0 · 1-4 MakotoAI 78.2 (ensemble: Opus 4.6, GPT-5.4/5.5, Gemini 2.5 Flash, Qwen3.7-Max, Gemma 4 31B) · 1-3 Wayfinder 78.2 (Gemini 3.1 Pro + 3.5 Flash + GPT-5.5 + Qwen 3.7 Max)
- 4-4 **GPT 5.5 77.1** · 5-6 **Gemini 3.1 Pro 75.5** · 4-6 TRIVE 75.0
- Human post-editing reference 71.0 (rank 7-11): top LLMs beat the human reference.
- 12-14 Mistral Medium 3.5 67.8 · 15-18 Command A+ 61.3 · 18-21 Google Translate 60.2 · 19-23 Gemma 4 31B 60.1 · 18-23 DeepSeek V4 Pro 56.6 · 20-23 gpt-oss 120B 52.1
- Claude Opus 4.8 / Sonnet 4.6 appear only inside the Dubformer pipeline (en-cs rank 7-10, 69.5); no standalone Claude baseline was listed **[unverified whether one exists]**.
- Overall: Wayfinder top cluster in 17/23 pairs; Gemini 3.1 Pro 15; GPT-5.5 behind it (avg rank 4.8 vs 8.6 per secondary write-up https://localizejs.com/articles/the-3-best-llms-for-translation). Slovak was NOT among the 23 WMT26 pairs.
- WMT26 also notes LLM-as-judge correlation with human rank on en-cs is only moderate (rho 0.40) — i.e. automatic judging for Czech is weaker than for Russian (0.59). Supports keeping a human spot-check.
- WMT25 (earlier): Gemini 2.5 Pro best overall (14 pairs) — https://aclanthology.org/2025.wmt-1.22 (details of en-cs cluster not retrieved).

**Slovak: sk-bench** (EMNLP 2026 main; 30 native-first tasks, 55 models) — https://arxiv.org/abs/2610.09152v1, https://aclanthology.org/2026.emnlp-main.2639/, leaderboard https://github.com/slovak-nlp/sk-bench:
- Gemini 3.1 Pro 72.6 > GPT-5.5 71.0 > Claude Opus 4.6 68.1. Best open: gpt-oss 120B 60.0; GLM-5.1 57.6; Qwen3.5-397B 57.4; Gemma 4 31B 54.3; Kimi K2.6 below gpt-oss 120B.
- Caveat: tasks are understanding/knowledge/grammar/summarisation; it does not directly measure copywriting fluency. Only the first 100k chars of the paper were read. Kimi K3, GPT-6.x, Gemini 3.5-3.8 not in the numbers I saw **[unverified]**.
- Practitioner report (Slovak dev blog, Aug 2025): Gemini 2.5 Pro writes the most fluent Slovak; Claude Sonnet 4 "terrible" at it — https://blog.machinezoo.com/Gemini_Pro_is_now_good_at_Slovak. Dated, anecdotal, but matches our Sept blind test. Relevant for the bias concern: Claude on Slovak is exactly why an outside reviewer is wanted.
- Small Slovak thesis benchmark (via search snippet only, original page not loadable): Gemma 4 26B-A4B 70, GLM-5 67, Mistral Large 3 64 /100 **[unverified]**.
- Other Slovak resources not yet scored for current models: SKR1 (Slovak realia), skLEP, SkMTEB.

**Not found:** EuroEval Czech/Slovak leaderboard (page is JS-rendered, not readable), BenCzechMark current top (only Gemma-2-era blog), LMArena language breakdown, any CZ/SK localization-community comparison of 2026 models. Treat these as gaps; if wanted, open https://euroeval.com and the sk-bench Space in a browser.

**Translation vs copy-review:** All hard evidence above is translation/understanding. No benchmark found for judging or rewriting short UX copy in cs/sk. Our own Sept 2026 test (Gemini 2.5 Pro 9.34 SK/9.33 CS) is the closest; recommend a small re-run (below).

## Q2. Amazon Bedrock availability (catalog fetched 2026-11-04)

Source: https://docs.aws.amazon.com/bedrock/latest/userguide/model-cards.html and https://aws.amazon.com/bedrock/pricing/
- **OpenAI:** GPT-6 Astra/Sol/Luna, GPT-6.1 Sol/Terra, GPT-5.6 Sol/Terra/Luna, GPT-5.5, GPT-5.4, gpt-oss-120b/20b (+ Safeguard). GPT-6.1 Terra card lists a **"Marketplace product ID"**, $1.00/$5.00 per 1M (Global CRIS, in-region +10%), 1.05M context. Model IDs `openai.gpt-6.1-terra` (bedrock-mantle) / `global.openai.gpt-6.1-terra` (runtime). https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-6-1-terra.html
- **Mistral:** Mistral Large 3 ($0.50/$1.50), Ministral 14B, Magistral Small, Pixtral Large, Mistral Large/Small. (Mistral Medium 3.5 NOT listed.)
- **Moonshot:** Kimi K3 ($3/$15), K2.5 ($0.60/$3), K2 Thinking. **Z.ai:** GLM 5.3 ($1.68/$5.28), GLM 5, 4.7. **DeepSeek:** V3.2 ($0.62/$1.85), V3.1, R1. **Qwen:** Qwen3 235B-2507 ($0.23/$0.91), Qwen3 Next 80B, 32B. **Google Gemma 4** 31B ($0.14/$0.40), 26B-A4B. **MiniMax** M2.5. **Amazon** Nova 2 Lite, Nova Pro/Lite/Micro (Nova Premier not in list). **xAI** Grok 4.7/4.6/4.3. **Writer** Palmyra X5. **Cohere** Command R/R+ (no Command A+). **Meta** Llama 3.x/4. **Nvidia** Nemotron 3 Super 120B.
- **Gemini is not on Bedrock** (Google models there = Gemma only).
- **Credit coverage — contradicts the premise partly, unverified:** AWS says Activate credits are redeemable for third-party Bedrock models, and the Activate FAQ excludes Marketplace "with the exception of charges incurred through third-party foundation models available on Amazon Bedrock" (https://aws.amazon.com/blogs/startups/aws-activate-credits-now-accepted-for-third-party-models-on-amazon-bedrock/ — 2024 post, "may not reflect current offerings"). Our own Aug 2026 finding was that Anthropic/Marketplace-sold models were not payable by the credit. The OpenAI GPT-5.x/6.x and Grok entries are new and carry Marketplace product IDs, so **whether credits pay for them is unverified**. Cheapest check: one tiny invocation (~$0.01) and look at Billing > Credits next day; or ask AWS account team.
- Practical: on Bedrock the credit surely covers Mistral Large 3, Gemma 4, gpt-oss, Qwen, DeepSeek, GLM, Kimi (confirmed pattern for Kimi K2.5/DeepSeek/GLM-5/gpt-oss in Aug). Those are the weaker cs/sk models though.

## Q3. Free / promo routes

- **Google AI Studio free tier** (https://aistudio.google.com/docs/pricing, fetched today): free for Gemini 3.8 Flash, 3.6 Flash, 3.5 Flash-Lite, 3.1 Flash-Lite, 3 Flash Preview. **Gemini 3.1 Pro Preview: no free tier.** Free-tier content **is used to improve Google products**; paid tier is not. Free-tier rate limits not on the fetched page (third-party blogs conflict: ~10-15 RPM, 250-1500 RPD) **[unverified]**. Your key has prepay billing, so requests are on the paid tier and not used for training (verify the key's project is billed, not a separate free project). UI strings are not secret but pre-release App Store copy and unreleased features could leak; paid tier is the safe default and costs ~$10.
- **Flash price note:** 3.6/3.8 Flash $0.75/$3.75 through 2026-12-31, doubling from 2027-01-01.
- **Google Cloud $300 trial** (https://cloud.google.com/free-trial/): new customers only, ~90 days, covers Vertex AI Gemini (third-party summary). Not needed at this volume. Google for Startups Cloud Program (up to $200k / $350k AI) — amounts from mirror pages **[unverified]**; overkill.
- **OpenAI complimentary daily tokens for shared traffic** (https://help.openai.com/en/articles/10306912, via search snippet; page itself returned 403): eligible orgs see an opt-in in data-sharing settings; gpt-5.6-terra/luna in the 10M/day group (2.5M for tiers 1-2); needs positive balance; no ZDR; 30 days notice to end. Opt-in means prompts are shared with OpenAI. Eligibility of GPT-6.x models **[unverified]**. Check Settings > Data controls > Sharing in the OpenAI dashboard.
- **Mistral Experiment tier** (https://help.mistral.ai/en/articles/450104-how-can-i-try-the-api-for-free-with-the-experiment-plan): free, but requests may be used for training; limits not officially published **[unverified]**.
- OpenRouter: founder cap $5 is enough for the whole job on Gemini 3.1 Pro via OpenRouter only if routed at list price (~$10 does not fit); use Google directly.

## Q4. Cost, ~2M input + 0.5M output tokens (list prices; reasoning/thinking tokens bill as output, so budget 1.5-2x output)

| Model | Price (in/out per 1M) | Base | If output doubles (thinking) |
|-------|-----------------------|------|------------------------------|
| Gemini 3.1 Pro | $2 / $12 | $10.00 (batch $5.00) | ~$16 |
| GPT-6.1 Terra (Bedrock Global; OpenAI direct price unverified) | $1 / $5 | $4.50 | ~$7 |
| Gemini 3.6 Flash | $0.75 / $3.75 | $3.38 (free tier $0) | ~$5 |
| Mistral Large 3 (Bedrock) | $0.50 / $1.50 | $1.75 | ~$2.5 |
| GLM 5.3 (Bedrock) | $1.68 / $5.28 | $6.00 | |
| Kimi K3 (Bedrock) | $3 / $15 | $13.50 | |
| Gemma 4 31B (Bedrock) | $0.14 / $0.40 | $0.48 | |

Everything is under ~$20 total; cost should not drive model choice. Prompt caching on the style guide / glossary prefix (Gemini and Bedrock both support it) cuts input cost further.

## Q5. Review method (LLM copy QA with context)

Evidence base is thin on cs/sk specifically; the following is well supported generally:
1. **Context beats model size for short strings.** Lingoport/RWS tested 2 x 18,000 UI strings: bare "translate X to Y" is insufficient; adding already-translated languages as cues and visual context raised quality and reduced the share needing human review — https://lingoport.com/blog/can-we-trust-llms-with-ui-string-translation-research-findings-from-lingoport-and-rws/. So per string send: key, EN source, SK/CS/EN current texts, developer comment, screen/feature description (or screenshot), char limit, spoken vs written, neighbouring strings of the same screen, glossary, style guide (tone, tykanie/vykanie, no cheesy fillers, no dashes in public text, "Trubbo" naming).
2. **Flag-only output.** GEMBA-MQM (Kocmi & Federmann, WMT23, https://arxiv.org/abs/2310.13988) prompts the LLM to list errors with category (accuracy, fluency, style, terminology) and severity (critical/major/minor) using a few-shot prompt, reference-free. Known weakness: over-flags and span precision against humans is low (secondary source, **[unverified]**). So request JSON: `{key, lang, severity, category, quote, why, suggested_fix}` only for real issues, with an explicit "no issues" default and a cap to curb nit-picking.
3. **Two reviewers, then adjudicate.** Run reviewer A (Gemini 3.1 Pro) and B (GPT-5.5/6.x). Auto-accept only findings both raise; send single-model findings to a judge step (the other vendor, shown the string, context and both claims) or to the founder. A Claude-written text judged by Claude is the failure mode we avoid; keep Claude out of the judging loop, but Claude can apply accepted fixes.
4. **Do not let the judge also be the rewriter on its own flagged items without a check.** WMT26 shows LLM-judge correlation with humans is only moderate for en-cs (rho 0.40).
5. **Deterministic checks first** (placeholders, plural forms, length, `%@` / `{0}`, trailing punctuation, terminology list) — cheap and removes noise before the LLM sees it.
6. **Calibrate once:** take ~40 strings per language with known problems (and ~40 known-good), run both models, measure precision of flags with the founder rating; reuse the Sept 2026 blind-test setup. Also run Opus as an informational third column to see agreement.
7. **Human spot-check:** founder reads only the disputed/high-severity subset plus a random 5%.

## Open items / unverified summary
- Bedrock credit coverage of OpenAI/Grok (Marketplace-listed) models.
- OpenAI direct list prices for GPT-6.x/5.6 (pricing page 403).
- Gemini free-tier rate limits; OpenAI daily-token eligibility for GPT-6.x.
- No Slovak numbers for GPT-6.x, Gemini 3.5-3.8, Kimi K3; no EuroEval/BenCzechMark/LMArena data.
- No benchmark directly measures UX-copy review quality in cs/sk; run the calibration above.
