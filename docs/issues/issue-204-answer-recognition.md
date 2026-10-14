# #204 — Spoľahlivejšie rozpoznanie hlasovej odpovede

**Triage:** enhancement · in-progress
**Založené:** 2026-10-14 (founder: „rozpoznávanie odpovedí nefunguje tak dobre ako Wispr Flow; jednoznačne nie hlasové príkazy“)
**Rešerš:** [answer-recognition-vs-wispr-2026-10-14](../research/answer-recognition-vs-wispr-2026-10-14.md)
**Súvisí:** #184 — batch STT + lokálna VAD, #185 — test v aute (VP len pri reproduktore/HFP), #197 — nahrávky z auta → replay

## Cieľ a kedy je hotovo

Hráč v aute nemusí kričať, odpoveď sa neodreže ani nenahrá s kusom hluku a správne povedaná odpoveď sa uzná.
**Hotovo** = každá zmena je za vlastným prepínačom (A/B), na nahrávkach z auta (replay #197) je zmeraný verdikt pred/po a zapnuté ostanú len tie, ktoré pomohli bez nárastu falošne uznaných odpovedí.

## Rozhodnutia foundera (2026-10-14)

- **Zmeny hneď, za prepínačmi** (A/B), nie až po meraní.
- **Koniec odpovede = lepšia automatika** (neurónový detektor hlasu). Žiadne ručné ťuknutie „hotovo“ — strop nahrávania už existuje.
- **Pri neistote appka rozhodne sama**, bez „Myslel si X?“.
- **Opakovaný pokus nesmie vrátiť ten istý zlý prepis:** hráč povie „modrá“, appka počuje „mokrá“, hráč dá nahrať znova → appka nesmie znova vyhodnotiť „mokrá“.

## Prepínače a tracky

Prepínače iOS sú v Settings › voice diagnostics (`VoicePipelineFlags`), backendové v `config.py` (env). Každá odpoveď loguje do Sentry, ktoré varianty boli aktívne.

| Track | Čo | Kde | Prepínač / default |
|---|---|---|---|
| 204.1 | Záložné STT: `gpt-transcribe` dostane `languages` (pole) namiesto `language` + `keywords` | backend | oprava chyby, bez prepínača |
| 204.2 | Opakovaný pokus nevráti zamietnutý prepis (kontrakt nižšie) | backend + iOS | iOS `avoidRejectedTranscriptOnRetry` = ON |
| 204.3 | Neurónová VAD (Silero v6, CoreML pribalený v appke) namiesto energetickej pri rozhodnutí reč/ticho; strop 8 s ostáva | iOS | `neuralVADEnabled` = OFF |
| 204.4 | AEC bez voice processing na A2DP/CarPlay (`setPrefersEchoCancelledInput`, iOS 18.2+, default mode); log `isEchoCancelledInputEnabled` + výstupná trasa | iOS | `echoCancelledInputOnExternalRoutes` = OFF |
| 204.5 | Predný vstavaný mikrofón + kardioida (`setPreferredDataSource` / `setPreferredPolarPattern`) | iOS | `frontCardioidMic` = OFF |
| 204.6 | Fonetická úroveň sk/cs/en v hodnotení (i/y, ch/h, znelosť, sh→š, w→v, ph→f, zahodená diakritika) medzi „znie ako“ a LLM sudcom | backend | `ANSWER_PHONETIC_MATCH` = OFF |
| 204.7 | Pri tvorbe otázky: výslovnostné varianty + podobne znejúce nesprávne odpovede → nápoveda aj pre otvorené otázky | quiz-pack-api + backend | neskôr, po meraní |
| 204.8 | A/B inej služby (Soniox v5, gpt-transcribe s nápovedou) na replay korpuse | skript | neskôr |

Nerobiť (rešerš): odšumenie pred STT, audio-LLM so správnou odpoveďou v prompte, Apple STT na odpovede.

## Kontrakt 204.2 — zamietnuté prepisy

- `POST /voice/submit` prijme **voliteľné** pole formulára `rejected_transcripts` = JSON pole reťazcov (prepisy, ktoré hráč pri tejto otázke už zamietol cez „nie / znova“). Chýbajúce pole = dnešné správanie (appka 1.0 ostáva funkčná).
- Backend: ak normalizovaný nový prepis zodpovedá niektorému zamietnutému, skúsi ďalšiu hypotézu — Scribe s `keyterms` = správna odpoveď + alternatívy (+ MCQ možnosti) a iným `seed`; potom `gpt-transcribe` s `keywords` rovnako. Vráti prvý prepis, ktorý sa nezhoduje so zamietnutým; ak sa zhodujú všetky, vráti pôvodný. Do logu len príznak a počet pokusov, nie slová.
- iOS: zamietnuté prepisy sa držia pre aktuálnu otázku (vynulujú sa pri ďalšej otázke) a posielajú sa len pri zapnutom prepínači.

## Meranie

Replay (`scripts/voice_replay.py`) na nahrávkach z auta s prepínačmi zapnutými/vypnutými: zmena verdiktu, falošné zamietnutie / uznanie podľa jazyka, oneskorenie konca, podiel nahrávok do stropu. Na 204.3 detektor prehraný v Swift teste na Macu.

## Stav

- 2026-10-14: rešerš hotová, tracky 204.1–204.6 v práci.
