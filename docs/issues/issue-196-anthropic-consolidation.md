# #196 — AI volania čo najviac na priame Anthropic API (Max kredit)

**Triage:** enhancement · ready (kľúč `ANTHROPIC_API_KEY` už je v root `.env` aj Fly secrets `quiz-pack-api`; chýba v `quiz-agent-api`)
**Založené:** 2026-10-09 (founder: „presmerovanie čo najviac volaní na Anthropic API… aj OpenAI a Google volania, nech nie sú zbytočné ďalšie výdavky“)
**Vetva:** `feat/196-anthropic-direct`

## Cieľ

Founder má od 2026-10-07 mesačný Anthropic API kredit k Max predplatnému. Každé AI volanie, ktoré vie robiť Claude, má ísť **priamo** na Anthropic API (čerpá kredit, bez poplatku OpenRouteru). OpenAI/Google/DeepSeek ostanú len tam, kde to Anthropic nevie, alebo kde porovnanie ukáže, že Claude kontrolu zhorší. **Kvalita otázok sa nesmie znížiť.**

## Rozhodnutia foundera (2026-10-09)

- Presun čo najviac volaní, aj z OpenAI a Google.
- Kontroly kvality (hodnotitelia, overovanie, kritika — dnes zámerne iné firmy kvôli self-preference bias): **skúsiť aj ich, ale len s porovnaním**; presunúť len ak Claude zachytí rovnaké chyby.

## Mapa volaní (recon 2026-10-09)

Smerovanie: `packages/shared/quiz_shared/llm/factory.py` — `LLM_GATEWAY=direct|openrouter|session`, `LLM_ROLE_*`; chat ide cez `ChatOpenAI`, priamy Anthropic klient (`anthropic_client()`) používa len fact-check. Claude/Gemini chat roly dnes fungujú len cez OpenRouter alebo `bedrock:`.

| Skupina | Volania | Dnes | Plán |
|---|---|---|---|
| A — už Claude, len okľukou | generovanie (`LLM_ROLE_GEN`), serve-time preklad (`TRANSLATION_MODEL`) | OpenRouter / Bedrock | priamo Anthropic, bez zmeny modelu |
| B — presun s porovnaním (hot path) | hodnotenie odpovedí (EVAL), parser povelov (PARSE) | OpenAI `gpt-4o-mini` | Haiku 5.5, eval na existujúcich sadách |
| B — presun s porovnaním (offline) | fakty z webu (`openai_web_search_source`), OpenTriviaDB prepis, texty hint/siluety, hint validácia (vision), expiry, topic planner | OpenAI `gpt-5-mini` / `gpt-4o(-mini)` / `gpt-5.6-sol` | Claude (+ `web_search` tool) |
| C — nezávislé kontroly | multi-judge scoring, VERIFY, FACTCHECK, CRITIQUE, DEDUP_JUDGE, answerability, shape, normalizácia, translation judge/regional | OpenAI / Gemini / DeepSeek | porovnanie na jednej dávke (zachytené chyby vs. dnes) → founder rozhodne |
| D — Anthropic nemá | embeddings `text-embedding-3-small` (pgvector 1536, re-embed korpusu), Whisper/Scribe STT, TTS (ElevenLabs/`tts-1`), `gpt-image-1` | OpenAI / ElevenLabs | ostáva |

## Tracky

- [x] **196.1 — HOTOVÉ 2026-10-09 (PR #323):** priamy Anthropic chat v factory:** prefix/route `anthropic:` (alebo `LLM_GATEWAY=anthropic` pre `claude-*` id) → `ChatAnthropic`, usage callback + `llm_usage.py` ceny (Sonnet 5 je dnes $2/$10, tabuľka má $3/$15); kľúč `ANTHROPIC_API_KEY` doplniť do Fly secrets `quiz-agent-api` (pack-api a `.env` ho majú). Hotovo = unit testy routingu + jedna reálna generácia na prode čerpá kredit.
- [x] **196.2 — skupina A — HOTOVÉ 2026-10-09:** nasadené quiz-agent-api + quiz-pack-api (worker ostáva stopnutý), kľúč doplnený do quiz-agent-api; preklad cez Anthropic overený (2 s), lokálne generovanie 3 otázok cez Opus 5.5 priamo bez chýb. Prod: `LLM_ROLE_GEN=claude-opus-5-5`, kontroly (CRITIQUE/NORMALIZE/VERIFY/JUDGE) bežia na `bedrock:deepseek.v3.2` / `bedrock:zai.glm-5` (AWS kredit) → porovnanie v 196.5 oproti nim. Open = founder potvrdí v Console, že čerpanie ide z Max kreditu.
- [ ] **196.3 — skupina B hot path:** eval Haiku 5.5 vs `gpt-4o-mini` (presnosť hodnotenia sk/cs/en, latencia) → founder schváli → prepnúť.
- [ ] **196.4 — skupina B offline:** prepnúť po malom porovnaní výstupov.
- [ ] **196.5 — skupina C:** jedna dávka so známymi chybami, Claude kontrolóri (iný model než generátor) vs. dnešní → tabuľka zachytených chýb → founder rozhodne per rola.
- [ ] **196.6 — upratanie:** OpenRouter kľúč/billing zrušiť, ak po 196.5 nič neostane; inak ponechať len pre zvyšné roly.

Útrata: pred každým eval behom odhad + súhlas (pravidlo spend approval); porovnania idú z Max kreditu.
