# Issue #93 — Per-user cost model (voice Slovak trivia)

Scope: marginal (variable) cost per user, to size the free tier + subscription price.
Ground truth on runtime cost = INPUT A code recon. Prices = INPUT B (cited inline).
All numbers labeled **[A]** are assumptions, not measured.

> **Revision 2026-07-10 (verified prices):** STT re-priced against the live ElevenLabs API price list (https://elevenlabs.io/pricing/api — Scribe v2 Realtime **$0.39/hr**, per-unit rate identical across all tiers + pay-as-you-go since the 2026-05-07 repricing); avg utterance set to **5 s** (founder call); Apple cut corrected to **15% from day one** (Small Business Program, verified developer.apple.com); LLM hot path corrected per code (no always-on parser call). Headline: **~$0.0006/answer**. The old ElevenLabs char-plan tier table was stale and is replaced by STT-hours PAYG math.

## 1. Assumptions

| Item | Value | Basis |
|---|---|---|
| Chars synthesized / question | **~70** (range 40–90) | INPUT A §2: only `question` text, MCQ options not read |
| TTS caching | **Cached + shared across ALL users**, disk LRU keyed SHA256(text+voice); each unique question synthesized once total | INPUT A §3 (`service.py:138-162`, `cache.py`) |
| → per-user marginal TTS | **≈ $0** (one-time catalog cost, amortized across every user & replay) | consequence of caching |
| TTS provider | **OpenAI** (tts-1 / gpt-4o-mini-tts), NOT ElevenLabs | INPUT A §5 (`AVSpeechSynthesizer` unused; ElevenLabs = STT only) |
| STT provider | **ElevenLabs Scribe realtime**, per answer, per user, uncacheable | INPUT A §1 (`ElevenLabsSTTService.swift`) — the real variable cost |
| STT $/answer | **~$0.00054** (Scribe v2 Realtime **$0.39/hr** verified 2026-07-09; **[A] 5 s** avg utterance incl. VAD tail — founder call, measure from real logs later) | elevenlabs.io/pricing/api |
| LLM hot path $/answer | **~$0.00005** — eval fires only when normalized/MCQ match fails (0 or 1 gpt-4o-mini call, ~300 in / <10 out tokens); no always-on parser; translation cached | code recon 2026-07-09 (`evaluator.py:73-190`); gpt-4o-mini $0.15/1M in, $0.60/1M out |
| Hosting marginal cost | **≈ $0/answer** — Fly compute is fixed monthly, not per-request; DB/cache writes negligible | infra note, not per-user |
| EUR→USD | **[A] 1.08** | fx assumption |
| App Store cut | **15% from day one** (Small Business Program covers subs + consumables, ≤$1M/yr) | developer.apple.com/app-store/small-business-program, verified 2026-07-09 |

## 2. Marginal cost per user / month ($)

Per-answer cost by scenario:
- **(a) Current (as-is):** TTS cached (~$0) + STT $0.00054 + LLM $0.00005 ≈ **$0.0006/answer**
- **(b) Worst case:** no caching, fresh **ElevenLabs TTS Multilingual** every question ($0.10/1k chars verified 2026-07-09) → 70ch = $0.007 TTS + STT + LLM ≈ **$0.0076/answer**
- **(c) Cheap path:** no caching, fresh **ElevenLabs Flash/Turbo** ($0.05/1k chars verified) → 70ch = $0.0035 + STT + LLM ≈ **$0.0041/answer**. (Cheapest Slovak alt = OpenAI gpt-4o-mini-tts ~$12/1M → ~$0.0014/answer. But **current cached arch already beats all of these**.)

| Questions/mo | (a) Current | (b) Worst | (c) Cheap Flash |
|---|---|---|---|
| 10 | $0.006 | $0.08 | $0.04 |
| 20 | $0.012 | $0.15 | $0.08 |
| 30 (free tier) | $0.018 | $0.23 | $0.12 |
| 50 | $0.03 | $0.38 | $0.21 |
| 100 | $0.06 | $0.76 | $0.41 |
| 300 | $0.18 | $2.28 | $1.23 |
| 1000 | $0.60 | $7.6 | $4.1 |

### ElevenLabs STT bill by MAU (assume 50 q/user/mo × 5 s = ~0.07 STT hrs/user/mo)
Since the 2026-05-07 repricing the per-unit rate ($0.39/hr realtime) is identical across all tiers and **pay-as-you-go exists with no monthly commitment** — no char-based plan is needed for anything (TTS is OpenAI+cached).

| MAU | STT hours/mo | PAYG cost | Cheapest covering plan |
|---|---|---|---|
| 100 | ~7 | **~$2.70** | Starter $6 (incl. 4.5 hrs) or plain PAYG |
| 1,000 | ~69 | **~$27** | PAYG (Creator $22 incl. 27 hrs, rest overage — same rate) |
| 10,000 | ~694 | **~$271** | PAYG or Scale $299 (incl. 450 hrs) |

## 3. Break-even (questions/mo before a paying user goes margin-negative)

Net revenue after **15%** Apple cut (Small Business Program, verified; EUR@1.08).

| Sub price | Net rev ($) | (a) Current | (b) Worst | (c) Cheap |
|---|---|---|---|---|
| €3.99 | $3.66 | ~6,100 | ~480 | ~890 |
| **€4.99 (locked)** | $4.58 | **~7,600** | ~600 | ~1,120 |
| Annual €29.99 (≈€2.50/mo) | $2.29/mo | ~3,800 | ~300 | ~560 |

Under **(a)**, break-even at the locked €4.99 is ~7,600 q/mo ≈ 250 answers/day ≈ 10+ hours of streamed speech — no realistic single-user consumption threatens margin. The €1.99 pack (net ~$1.83) covers its 100 questions' cost (~$0.06) with ~97% margin.

## 4. Free-tier cost of ONE free user / month ($)

| Free questions | (a) Current | (b) Worst | (c) Cheap |
|---|---|---|---|
| 20 | $0.012 | $0.15 | $0.08 |
| 30 (#93 policy) | $0.018 | $0.23 | $0.12 |
| 50 | $0.03 | $0.38 | $0.21 |
| 100 (old policy) | $0.06 | $0.76 | $0.41 |

**Is the founder's ElevenLabs fear justified?** No — under the ACTUAL architecture (a) the fear is misdirected: ElevenLabs is STT not TTS, TTS is OpenAI and cached/shared (~$0/user), so even 100 free questions costs **~$0.06/user/month** (the 30-question free tier ~$0.02); the founder should track ElevenLabs STT *minutes* (~$0.00054/answer at 5 s), not TTS.
