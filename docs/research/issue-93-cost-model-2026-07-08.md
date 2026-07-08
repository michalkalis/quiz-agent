# Issue #93 — Per-user cost model (voice Slovak trivia)

Scope: marginal (variable) cost per user, to size the free tier + subscription price.
Ground truth on runtime cost = INPUT A code recon. Prices = INPUT B (cited inline).
All numbers labeled **[A]** are assumptions, not measured.

## 1. Assumptions

| Item | Value | Basis |
|---|---|---|
| Chars synthesized / question | **~70** (range 40–90) | INPUT A §2: only `question` text, MCQ options not read |
| TTS caching | **Cached + shared across ALL users**, disk LRU keyed SHA256(text+voice); each unique question synthesized once total | INPUT A §3 (`service.py:138-162`, `cache.py`) |
| → per-user marginal TTS | **≈ $0** (one-time catalog cost, amortized across every user & replay) | consequence of caching |
| TTS provider | **OpenAI** (tts-1 / gpt-4o-mini-tts), NOT ElevenLabs | INPUT A §5 (`AVSpeechSynthesizer` unused; ElevenLabs = STT only) |
| STT provider | **ElevenLabs Scribe realtime**, per answer, per user, uncacheable | INPUT A §1 (`ElevenLabsSTTService.swift`) — the real variable cost |
| STT $/answer | **[A] ~$0.0007** (assume Scribe realtime ~$0.40/hr, ~6s avg utterance incl. VAD tail) | ElevenLabs STT pricing NOT in provided inputs — flagged as assumption |
| LLM hot path $/answer | **~$0.00011** — parser always + eval on ~30% (open) questions, gpt-4o-mini; translation cached | INPUT A §4; gpt-4o-mini $0.15/1M in, $0.60/1M out |
| Hosting marginal cost | **≈ $0/answer** — Fly compute is fixed monthly, not per-request; DB/cache writes negligible | infra note, not per-user |
| EUR→USD | **[A] 1.08** | fx assumption |
| App Store cut | **30%** (15% under Small Business Program — noted) | Apple standard |

## 2. Marginal cost per user / month ($)

Per-answer cost by scenario:
- **(a) Current (as-is):** TTS cached (~$0) + STT $0.0007 + LLM $0.00011 ≈ **$0.0008/answer**
- **(b) Worst case:** no caching, fresh **ElevenLabs Multilingual v2** every question (~$180/1M chars, INPUT B §1) → 70ch = $0.0126 TTS + STT + LLM ≈ **$0.0134/answer**
- **(c) Cheap path:** no caching, fresh **ElevenLabs Flash v2.5** (~$90/1M, INPUT B §1) → 70ch = $0.0063 + STT + LLM ≈ **$0.0071/answer**. (Cheapest Slovak alt = OpenAI gpt-4o-mini-tts ~$12/1M → ~$0.0016/answer; Google WaveNet $16/1M similar — INPUT B §2. But **current cached arch already beats all of these**.)

| Questions/mo | (a) Current | (b) Worst | (c) Cheap Flash |
|---|---|---|---|
| 10 | $0.008 | $0.13 | $0.07 |
| 20 | $0.016 | $0.27 | $0.14 |
| 50 | $0.04 | $0.67 | $0.36 |
| 100 | $0.08 | $1.34 | $0.71 |
| 300 | $0.24 | $4.02 | $2.13 |
| 1000 | $0.80 | $13.4 | $7.1 |

### ElevenLabs plan tier needed by MAU (assume 50 q/user/mo)
Prices: INPUT B §1. **Scenario (a) needs NO ElevenLabs TTS plan** — TTS is OpenAI+cached; ElevenLabs there is STT, billed by minutes not a char plan.

| MAU | (b) Worst (Multilingual v2, 1 cr/char) | (c) Cheap (Flash v2.5, 0.5 cr/char) |
|---|---|---|
| 100 | 350k cr → **Pro $99** | 175k cr → **Pro $99** |
| 1,000 | 3.5M cr → **Business $990** | 1.75M cr → **Scale $299** |
| 10,000 | 35M cr → **Enterprise** (~6× Business) | 17.5M cr → **Enterprise** (~3× Business) |

## 3. Break-even (questions/mo before a paying user goes margin-negative)

Net revenue after 30% Apple cut (EUR@1.08). No market price anchor was provided → the three prices are **[A] candidates**, not benchmarked.

| Sub price | Net rev ($) | (a) Current | (b) Worst | (c) Cheap |
|---|---|---|---|---|
| €3.99 | $3.02 | ~3,800 | ~225 | ~425 |
| €5.99 | $4.53 | ~5,660 | ~340 | ~640 |
| €7.99 | $6.04 | ~7,550 | ~450 | ~850 |

Under 15% Small-Business cut, headroom is ~20% higher. Under **(a)**, no realistic single-user consumption (even 1,000 q/mo) threatens margin.

## 4. Free-tier cost of ONE free user / month ($)

| Free questions | (a) Current | (b) Worst | (c) Cheap |
|---|---|---|---|
| 20 | $0.016 | $0.27 | $0.14 |
| 50 | $0.04 | $0.67 | $0.36 |
| 100 (current policy) | $0.08 | $1.34 | $0.71 |

**Is the founder's ElevenLabs fear justified?** No — under the ACTUAL architecture (a) the fear is misdirected: ElevenLabs is STT not TTS, TTS is OpenAI and cached/shared (~$0/user), so even 100 free questions costs **~$0.08/user/month**; the founder should track ElevenLabs STT *minutes* (~$0.0007/answer), not TTS.
