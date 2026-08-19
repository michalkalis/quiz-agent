# Research: LLM modely na generovanie quiz otázok — lacnejšie alternatívy k Fable 5

**Date:** 2026-08-19 | **Query:** Výber gen modelov: Fable 5 vyhráva kvalitou, ale je drahý na custom packy. Ktoré (najmä čínske) modely sú vhodné za nižšiu cenu? Len aktuálne info (august 2026).

## Executive Summary

- **Claude Opus 5 je najsilnejší kandidát na náhradu Fable 5**: #1 na EQ-Bench Creative Writing (2105 Elo, PRED Fable 5), polovičná cena ($5/$25 vs $10/$50), cez Anthropic Batch API $2.50/$12.50 — t. j. ~4× lacnejšie než Fable bez batchu.
- **Kimi K3 (Moonshot, júl 2026) je najlepší čínsky challenger**: #2 creative writing globálne (2060 Elo, tesne za Opus 5), $3/$15 — na úrovni Sonnet ceny. Nástupca nášho súčasného gen modelu Kimi K2.5.
- **DeepSeek V4 (Pro/Flash) je pre trivia DISKVALIFIKOVANÝ**: halucinácie 94–96 % na AA-Omniscience (index −23), hoci je extrémne lacný. Ceny navyše od 16. 8. rastú (peak/off-peak).
- Fakticita frontier modelov (AA-Omniscience index): Fable 5 = 40 (líder, 61 % accuracy), Opus 4.8 = 27, Kimi K3 = 18, Sonnet 5 = 15.3, Qwen3.7 Max = 14, DeepSeek V4 Pro = −23.
- Odporúčanie: **blind test Opus 5 (batch) vs Kimi K3 vs Fable 5 (batch, baseline)** na ďalšom kole ratingov — per feedback pravidlo „gen-model zmeny len s eval dátami + founder approval".

## Key Findings

### 1. Cenová tabuľka (august 2026, $/1M tokenov, input/output)

| Model | Cena | Batch/off-peak | Poznámka |
|---|---|---|---|
| Claude Fable 5 | $10 / $50 | $5 / $25 (Batch API) | súčasný víťaz kvality (D21b) |
| **Claude Opus 5** | $5 / $25 | **$2.50 / $12.50** (Batch) | #1 creative writing, silná fakticita |
| Claude Sonnet 5 | $3 / $15 | intro $2 / $10 do 31. 8. | fakticita slabšia (index 15.3) |
| **Kimi K3** | $3 / $15 | cache-hit input $0.30 | #2 creative writing; open weights (27. 7.) |
| GLM-5.2 (Zhipu) | $1.40 / $4.40 | — | MIT licencia, AA intelligence 51; fakticita nezistená |
| Kimi K2.5 (súčasný gen) | $0.60 / $3 | — | doterajší pipeline model |
| DeepSeek V4 Pro | $0.66 / $1.98 (peak od 16. 8.) | off-peak −50 % | halucinácie 94 % → nevhodný |
| Qwen3.8 Max | ~$1.6–3 (Alibaba) | — | accuracy nízka (Qwen3.7: 30 %) |

Batch API (Anthropic) = 50 % zľava, výsledky do 1 h (max 24 h) — pre pack-generation pipeline (nie hot path) plne vyhovujúce; D21b už batch smerom išiel.

### 2. Kvalita písania (EQ-Bench Creative Writing, august 2026)

1. **Claude Opus 5 — 2105 Elo** (líder)
2. **Kimi K3 — 2060 Elo**
3. GPT-5.6 Sol — 1959 Elo

Fable 5 vedie širšie boardy (LMArena Text 1506, EQ General 2050), ale v creative writingu ho Opus 5 predbieha. Pre quiz otázky (prekvapivosť, pointa, štylizácia — founder rubrika odmeňuje surprise) je creative writing benchmark najbližší proxy.

### 3. Fakticita — kritický filter pre trivia (AA-Omniscience)

| Model | Accuracy | Halucinácie | Index |
|---|---|---|---|
| Claude Fable 5 | 61 % | 54.9 % | **40** |
| GPT-5.6 Sol | 59 % | n/a | — |
| Gemini 3.1 Pro | 55.3 % | 50 % | 33 |
| Claude Opus 4.8 | 46.6 % | 35.9 % | 27 |
| Kimi K3 | 46 % | 51 % | 18 |
| Claude Sonnet 5 | 38.3 % | 37.3 % | 15.3 |
| Qwen3.7 Max | 30 % | 23 % | 14 |
| DeepSeek V4 Pro | — | **94 %** | **−23** |

Náš pipeline má fact-sourcing + verify vrstvu, takže halucinácie čiastočne chytáme — ale gen model s 94 % halucináciami zahltí verify fázu odpadom (vyššie náklady na overgen/critique). Preto DeepSeek V4 ani ako lacný gen nedáva zmysel; ako **critique/normalize model zostáva OK** (tam sa fakty neprodukujú).

### 4. Novinky august 2026

- **Kimi K3** (17. 7.): 2.8T parametrov, najväčší open-source model; váhy na HF od 27. 7. 1M kontext. Pre nás relevantné: priamy upgrade línie Kimi, ktorá vyhrala júlový blind test.
- **DeepSeek V4 Pro 0813** (12. 8. GA): vendor benchmarky (DeepSWE 62.7) zatiaľ nezávisle nereplikované; na LiveBench agentic coding posledný zo 7 frontier modelov. Peak/off-peak pricing od 16. 8. — všetky sadzby efektívne rastú.
- **GLM-5.2 / 5.3** (Zhipu): MIT, 1M kontext, AA intelligence 51 — medzi K3 (57) a DeepSeek V4 Pro (44). Cenovo zaujímavý stred, ale bez dát o fakticite — musel by prejsť vlastným evalom.
- Sonnet 5 intro pricing $2/$10 končí **31. 8. 2026** — potom $3/$15.

## Implications for Hangs

- **Náklady na 100 q dávku (D21b škála):** ak Fable 5 batch = X, potom Opus 5 batch ≈ 0.5X, Kimi K3 ≈ 0.6X (bez batch zľavy), GLM-5.2 ≈ 0.18X. Oproti Fable bez batchu je Opus 5 batch ~4× lacnejší.
- Opus 5 je rovnaká rodina ako Fable → D21b prompty a Batch API infra sa prenesú takmer bez zmien (pozor: prompty písané pre Fable môžu byť pre Opus príliš voľné — Opus chce skôr brzdy, viď shared.md).
- Kimi K3 na OpenRouter — vyžaduje OpenRouter top-up (kredit je na nule).
- Pravidlá platia: frontier-only v gen stacku (K3, Opus 5, GLM-5.2 kvalifikujú; DeepSeek V4 nie kvôli fakticite), a žiadna výmena bez eval dát + founder approval.

## Recommendations

1. **Do ďalšieho kola ratingov zaradiť 3-ramenný blind test: Fable 5 (batch, baseline) vs Opus 5 (batch) vs Kimi K3.** Ak Opus 5 dorovná Fable, custom packy bežia na ~50 % nákladov; ak vyhrá K3, na ~30 %.
2. **DeepSeek V4 do gen fázy nezaraďovať** (fakticita); V3.2 v critique/verify roli ponechať.
3. **GLM-5.2 ako lacný outsider** — zaradiť len ak chceme 4. rameno; inak počkať na dáta o fakticite.
4. Ak sa rozhodne pre Sonnet 5, rozhodnúť **pred 31. 8.** (koniec intro pricingu) — ale fakticita (15.3) z neho robí slabšieho kandidáta než K3 za rovnakú cenu.

## Sources

1. [MarkTechPost — Kimi K3 vs DeepSeek V4 Pro vs GLM-5.2](https://www.marktechpost.com/2026/07/18/kimi-k3-vs-deepseek-v4-pro-vs-glm-5-2-open-trillion-scale-moe-models-compared-on-benchmarks-license-and-serving-cost/) — ceny, benchmarky, licencie troch open MoE modelov
2. [Suprmind — AI Hallucination Rates & Benchmarks Aug 2026](https://suprmind.ai/hub/ai-hallucination-rates-and-benchmarks/) — AA-Omniscience skóre naprieč modelmi
3. [BenchLM — Best Chinese AI Models Aug 2026](https://benchlm.ai/best/chinese-models) — rebríček čínskych modelov (K3 líder)
4. [TechTimes — DeepSeek V4 Pro 0813 GA](https://www.techtimes.com/articles/324241/20260813/deepseek-v4-pro-0813-goes-ga-benchmark-claims-await-independent-proof.htm) — GA, nezávisle neoverené benchmarky
5. [AI Pricing Guru — DeepSeek peak/off-peak update](https://www.aipricing.guru/news/deepseek-api-pricing-update-peak-off-peak-august-2026/) — zmena cien od 16. 8.
6. [EQ-Bench Creative Writing Leaderboard](https://eqbench.com/creative_writing.html) — Opus 5 (2105) > Kimi K3 (2060) > GPT-5.6 Sol (1959)
7. [BenchLM — Kimi API Pricing Aug 2026](https://benchlm.ai/moonshot/api-pricing) — K3 $3/$15
8. [Kili Technology — Kimi K3 benchmarks & hallucinations](https://kili-technology.com/blog/kimi-k3s-benchmarks-and-hallucinations----what-that-tells-us-about-ai-evaluation) — K3 SimpleQA/kalibrácia
9. Anthropic API docs (claude-api skill, cache 2026-06) — Fable 5 $10/$50, Opus 5 $5/$25, Sonnet 5 intro $2/$10 do 31. 8., Batch API −50 %
