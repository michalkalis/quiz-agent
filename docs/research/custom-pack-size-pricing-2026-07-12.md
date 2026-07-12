# Research: Custom quiz-pack size & pricing (issue #95)

**Date:** 2026-07-12 | **Query:** Optimal size and EUR price for custom AI-generated quiz packs (consumable IAP), vs €4.99/mo sub and €1.99/100q credit pack.

## Executive Summary

- **Recommended v1 tier: one size — 30 questions at €3.99** (Apple price point). Optional later upsell: 50 questions at €5.99. Drop pack_10/20.
- Our only measured generation cost is **~$0.04–0.05 per accepted question** (Opus 4.8 via OpenRouter, all-in for the generation step, 3× over-gen). With verification/scoring overhead, plan **~$0.05–0.08/q all-in** → a 30-q pack costs **~$1.50–2.40 to produce**. A €2.99 price nets ~€2.54 (15% SBP cut) ≈ $2.77 — margin gets thin at the cost ceiling; **€3.99 nets ~€3.39 ≈ $3.70 → healthy 35–60% margin**.
- 30 questions ≈ one typical drive: EU average commute is ~25 min (Eurostat 2019); at a voice Q&A cadence of ~30–45 s/question, 30 questions ≈ 15–25 min. Matches founder intuition that >30 risks tedium; virtual-trivia guidance also favors short rounds (5–20 q/round, fatigue beyond ~2 min/q pacing).
- Market anchors: trivia consumables cluster at $0.99–$4.99 (Trivia Crack: $0.99 daily pack, $2.99–3.99 lives/credit packs); AI-quiz generators price *creation* as subscription $9–29/mo — a one-off personalized pack at €3.99 sits comfortably between "cheap consumable" and "creation tool", and stays under the €4.99 sub so the sub remains the headline offer.
- **Gap to fix:** the #72 production run (46 topics) recorded no actual dollar spend. First founder pack order should log measured all-in cost per question to validate the $0.05–0.08 planning band.

## Key Findings

### 1. Market: what comparable IAPs cost
Trivia consumables in top apps cluster low: Trivia Crack sells a Daily Question Premium Pack at $0.99, lives packs at $2.99–19.99, credit packs from $4.99 ([App Store](https://apps.apple.com/us/app/trivia-crack-brain-quiz-games/id651510680)). Generic quiz-pack unlocks sit at $0.99–3.99 ([Quiz Games No Ads](https://apps.apple.com/us/app/quiz-games-no-ads-trivia/id611246006), [Trivia Star](https://apps.apple.com/us/app/trivia-star-trivia-games-quiz/id1508418993)). None of these are personalized — they're shared-corpus content, i.e. the analogue of our €1.99/100q credit pack, which is priced consistently with this band.

Personalized/AI-generated quiz *creation* is priced much higher, but as B2B/prosumer subscriptions: QuizFlex $9–29/mo ([pricing](https://quizflex.ai/pricing)), MyQuizGen $8.99/mo ([App Store](https://apps.apple.com/us/app/myquizgen-ai-quiz-generator/id6670340129)), Quizbot one-time $30/4000 q ([quizbot.ai](https://quizbot.ai/)), TriviaMaker subscriptions ([pricing](https://triviamaker.com/pricing/)). There is no direct consumer precedent for "one custom pack as a one-off IAP" — we set the anchor ourselves; the constraint is internal (above credit pack per-question value, below/near the sub).

### 2. Our production cost (internal, cited)
- Measured 2026-07-11: **~$4–5 per 100 accepted questions** for the Opus 4.8 generation step all-in (7K-token uncached prompts, 3× over-generation, reasoning-heavy output) → ~$0.04–0.05/q (`docs/research/openrouter-creative-question-models-2026-06-26.md:134,189`).
- On top: Sonnet 4.6 scoring judge + Gemini fact-check (sticker prices only, no measured $/q) and Tavily tracked as a flat 1¢/call placeholder (`apps/quiz-pack-api/app/orchestrator/stages/sourcing.py:25`). Planning band **$0.05–0.08/q all-in**.
- Per-pack COGS: 30 q ≈ $1.50–2.40 · 50 q ≈ $2.50–4.00 · 10 q ≈ $0.50–0.80 (but fixed prompt overhead makes small packs least efficient per question).
- No measured spend exists for the #72 run (46 topics) — cost capture is a to-do for the first real pack.

### 3. Session length: 30 questions fits one drive
EU average commute ~25 min, 61% under 30 min ([Eurostat](https://ec.europa.eu/eurostat/web/products-eurostat-news/-/ddn-20201021-2)); broader European averages ~38 min ([Euronews](https://www.euronews.com/next/2024/09/25/these-are-europes-longest-and-shortest-commutes-to-work-how-does-your-country-compare)). Trivia design guidance: rounds of 10–20 questions, short rounds (≤5 in high-fatigue settings), ~2 min/q ceiling before fatigue ([cheaptrivia](https://cheaptrivia.com/blogs/trivia-talk/how-long-does-trivia-night-last-tips-for-planning-your-event), [typito](https://typito.com/blog/how-to-run-trivia-for-a-large-group-20-200-people-formats-rules-and-timing-that-actually-work-2026-latest/)). At our voice cadence (~30–45 s/q), 30 q ≈ 15–25 min = one commute; 50 q spans ~2 sessions (fine as a road-trip tier, unnecessary for v1).

### 4. Price anchoring vs the €4.99 sub
The sub (€4.99/mo, unlimited shared corpus) must stay the headline. A custom pack is a *different* value axis (your topic, yours to keep), so pricing near the sub is defensible — but going above it (€5.99+ for 30 q) would make the sub look bad value in reverse and invite "why is one pack more than a whole month?". €3.99 for 30 custom questions: 20% under the sub, 6× the per-question price of the €1.99/100q credit pack (€0.133/q vs €0.02/q) — clearly premium, clearly personalized.

## Implications for Hangs

- `_PRODUCT_TIERS` (pack_10/20/30/50) shrinks to **pack_30** for v1 (keep the dict extensible; pack_50 is the natural second tier at €5.99).
- Session 4 ASC product: `com.carquiz.pack.custom.30` @ €3.99 (consumable). Nothing to create now — payments deferred.
- Custom packs bypass the 30/mo free quota (decided 2026-07-12) — consistent with paid-content positioning.
- First founder order must log measured all-in $/pack (closes the #72 cost-capture gap and validates margin before payments go live).

## Recommendations

1. **v1: single tier, 30 questions, €3.99** (`pack_30` → later `com.carquiz.pack.custom.30`). One size = simplest UI (no tier picker), matches one-drive session length, 35–60% margin at measured costs.
2. **Defer pack_50 @ €5.99** as a "road trip" upsell once v1 sells; drop pack_10/20 (poor unit economics, weak perceived value).
3. **Instrument cost capture** on the first founder-ordered pack (total OpenRouter + Tavily spend per order) before enabling payments.
4. Keep custom packs visually separate from the €1.99 credit pack (already planned — entry point outside PaywallView).

## Sources

1. [Trivia Crack — App Store IAP list](https://apps.apple.com/us/app/trivia-crack-brain-quiz-games/id651510680) — consumable price points $0.99–$99.99
2. [Eurostat: commuting time 2019](https://ec.europa.eu/eurostat/web/products-eurostat-news/-/ddn-20201021-2) — EU avg 25 min, 61% < 30 min
3. [Euronews: Europe's commutes 2024](https://www.euronews.com/next/2024/09/25/these-are-europes-longest-and-shortest-commutes-to-work-how-does-your-country-compare) — country spread
4. [cheaptrivia: trivia night length](https://cheaptrivia.com/blogs/trivia-talk/how-long-does-trivia-night-last-tips-for-planning-your-event) — rounds/fatigue guidance
5. [typito: trivia formats that scale](https://typito.com/blog/how-to-run-trivia-for-a-large-group-20-200-people-formats-rules-and-timing-that-actually-work-2026-latest/) — 10–20 q/round, short-round advice
6. [QuizFlex pricing](https://quizflex.ai/pricing) · [MyQuizGen](https://apps.apple.com/us/app/myquizgen-ai-quiz-generator/id6670340129) · [Quizbot](https://quizbot.ai/) · [TriviaMaker](https://triviamaker.com/pricing/) — AI quiz-creation pricing (subscription-shaped)
7. Internal: `docs/research/openrouter-creative-question-models-2026-06-26.md:134,189` — measured $4–5/100 accepted questions; `docs/issues/issue-93-subscription-iap-packs.md` + `docs/handoffs/handoff-2026-07-11-1255.md:13` — €1.99/100q credit pack; `apps/quiz-pack-api/app/api/v1/orders.py:37-42` — `_PRODUCT_TIERS`
