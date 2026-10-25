# Research: cheaper TTS than ElevenLabs Multilingual v2 without quality loss

**Date:** 2026-10-25 | **Query:** ElevenLabs costs a lot for reading questions and answers. Find competitors at a better price, same quality (sk/cs/en).

## Current state (from code + ElevenLabs API, 2026-10-25)

- Model `eleven_multilingual_v2`, voice George (won the 2026-07-26 listening test, en + sk). List price **$80 / 1M characters**.
- ElevenLabs is now TTS only (answer recognition moved to OpenAI in #208.1 — answer transcription).
- Every clip is cached (disk L1 + R2 L2, #207.20), so we pay once per unique text per language, not per play. ~185 credits per first read of a question (≈ $0.015 at list price).
- Plan: Starter; billing period usage 2,766 / 42,725 credits. Over the daily budget, speech falls back to OpenAI `tts-1`.
- `eleven_flash_v2_5` (half price) was already rejected: weaker non-English pronunciation.

## Executive summary

- **Cheapest zero-integration win: Eleven v4 Turbo** — $40 / 1M (half of today), ranked #1 on the Artificial Analysis TTS arena (English), supports sk + cs, same George voice. Config change only (`ELEVENLABS_TTS_MODEL`).
- **Biggest saving at near-top quality: Gemini 3.8 Flash TTS** — ~$16.50 / 1M (≈ 5× cheaper), arena #5, Slovak and Czech listed. Launch pricing ends 2026-12-31; from 2027 roughly doubles (~$33 / 1M). New provider + new voice (George is lost).
- **Not worth it:** Cartesia Sonic 3.6 ($49, only ~40% saving, provider switch); Azure Neural/HD (~$15–22, absent from arena top 15); OpenAI tts-1 (cheap, clearly lower quality — today's fallback).
- **Unverified for sk/cs:** Inworld Realtime TTS-2 ($20.80, arena #6), Alibaba Qwen-Audio-3.1-TTS-Plus ($19.30, arena #3).
- **Every public ranking is English-dominated.** No sk/cs head-to-head exists; "no quality loss" can only be proven by our own blind listening test.

## Key findings

### Price × quality (Artificial Analysis, provider-voice arena, Oct 2026)

| Model | Elo | $ / 1M chars | sk / cs | Integration |
|---|---|---|---|---|
| Eleven v4 Turbo | 1335 | 40 | yes / yes | model flag only |
| Eleven v4 | 1330 | 80 | yes / yes | model flag only |
| Qwen-Audio-3.1-TTS-Plus | 1306 | 19.30 | unverified | new provider |
| Cartesia Sonic 3.6 | 1289 | 49 | yes / yes | new provider |
| Gemini 3.8 Flash TTS | 1282 | 16.50 | yes / yes | new provider |
| Inworld Realtime TTS-2 | 1269 | 20.80 | unverified | new provider |
| Gemini 3.8 Flash-Lite TTS | 1254 | 11 | check list | new provider |
| Eleven Multilingual v2 (today) | not in top 15 | 80 | yes / yes | — |

Multilingual v2 is "previous generation" in ElevenLabs docs (not deprecated). Cartesia leads 8 of 9 non-English arenas (sk/cs not among them); Eleven v3 is top 3 in 7 of 9.

### Eleven v4 Turbo
Real-time variant of v4, 90+ languages incl. Czech and Slovak; ElevenLabs notes some languages are more fluent than others. Same voice library, so George stays. Caveat: Multilingual v2 is recommended by ElevenLabs where number normalization matters; we already normalize numbers ourselves (`number_normalization.py`), so lower risk, but test numbers/dates.

### Gemini 3.8 Flash TTS
130 languages incl. Slovak and Czech. Token-billed ($0.50 / 1M input, $9 / 1M audio output through 2026-12-31; ~$1 / $18 after). Steerable style via prompt. Cached audio is a one-time cost, so the 2027 increase matters only for new questions.

## Implications for Trubbo

- Because audio is cached, spend scales with **new questions × languages**, not players. Any switch means re-synthesizing the corpus once (or only new questions, mixing voices — not recommended; one host voice per language is part of the product).
- A voice change is a product decision (George was chosen by the founder).

## Recommendations

1. **Blind listening test** (cost < $1): same ~10 sk + 10 cs + 10 en real questions incl. numbers and names, in Multilingual v2 (today), Eleven v4 Turbo, Gemini 3.8 Flash TTS; founder picks blind in an artifact.
2. If v4 Turbo ≥ v2 on sk/cs → switch the model flag (−50 %, no code change, George stays).
3. If Gemini wins or ties → add a Gemini provider behind the existing provider switch (−80 % now, ~−60 % from 2027).
4. Re-check Inworld / Qwen sk-cs support only if neither passes.

## Sources

1. [Artificial Analysis TTS leaderboard](https://artificialanalysis.ai/text-to-speech/leaderboard) — Elo + normalized $ / 1M
2. [ElevenLabs API pricing](https://elevenlabs.io/pricing/api) — v2/v3 $0.08 / 1K, Flash/Turbo $0.04 / 1K
3. [ElevenLabs models](https://elevenlabs.io/docs/overview/models) — v4 / v4 Turbo languages, v2 status
4. [Eleven v4 docs](https://elevenlabs.io/docs/overview/capabilities/text-to-speech/eleven-v4) — Czech/Slovak in language list
5. [Gemini 3.8 Flash TTS (Google AI)](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash-tts) — 130 languages incl. sk/cs
6. [Gemini 3.8 Flash TTS pricing (eesel)](https://www.eesel.ai/blog/gemini-3-8-flash-tts-pricing) — launch rates, 2027 increase
7. [Cartesia Sonic 3.6 docs](https://docs.cartesia.ai/build-with-cartesia/tts-models/latest) — 44 languages incl. cs/sk
8. [Artificial Analysis multilingual arenas (X)](https://x.com/ArtificialAnlys/status/2102490340678856997) — non-English rankings
9. [Gradium: ElevenLabs alternatives 2026](https://gradium.ai/content/best-elevenlabs-alternatives-2026-tts-apis-voice-quality-price) — price/quality overview (vendor blog)
10. [Google Chirp 3 HD](https://docs.cloud.google.com/text-to-speech/docs/chirp3-hd) — sk/cs support, $30 / 1M
11. [Azure Speech pricing](https://azure.microsoft.com/en-us/pricing/details/speech/) — Neural / HD tiers
