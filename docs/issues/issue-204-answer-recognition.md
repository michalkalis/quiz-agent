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
| 204.9 | Appka testuje nastavenia sama (automatické A/B), víťaza zapne sama a agent to oznámi founderovi | iOS + backend + job | sekcia nižšie |

Nerobiť (rešerš): odšumenie pred STT, audio-LLM so správnou odpoveďou v prompte, Apple STT na odpovede.

## 204.9 — Automatické testovanie nastavení (founder 2026-10-14)

Founder: „appka by si mala sama riadiť nastavenia a testovať ich, bojím sa, že zabudnem, a nastavení je veľa“. Víťaza **zapne sama**, ale founder sa to má dozvedieť **od agenta v session, nie cez Sentry e-mail** („to sa stratí“). Rešerš: Feit & Berman „Test & Roll“ https://arxiv.org/pdf/1811.00457, rozhodovacie pravidlo očakávanej straty https://chrisstucchio.com/blog/2014/bayesian_ab_decision_rule.html, carryover pri switchback https://arxiv.org/pdf/2009.00148.

- **Čo sa testuje:** neurónová VAD (204.3), AEC na externej trase (204.4), predný kardioidný mikrofón (204.5). Opakovaný pokus (204.2) ostáva ON, netestuje sa.
- **Pridelenie:** nezávislá minca pre každý prepínač, **raz na kvízové kolo** (pred prvým zapnutím mikrofónu), počas kola sa nemení. Pravdepodobnosti a stav experimentu (beží / víťaz zapnutý / vypnutý) prídu zo servera v `/api/v1/app-config` (už sa číta pri štarte a návrate do appky), aby sa experiment dal meniť bez TF buildu. Uložené v DB, nie vo Fly secrets, aby ho job mohol meniť bez reštartu.
- **Ručné prepínače:** v Settings › voice diagnostics hlavný prepínač „Automatické testovanie“ (default ON); keď je vypnutý, platia ručné prepínače ako dnes. Pridelenie nikdy neprepíše ručnú voľbu do UserDefaults (samostatná vrstva).
- **Záznam:** nová udalosť v `analytics_events` (taxonomy.py + `docs/product/analytics-events.md`) pri každej nahratej odpovedi: pridelené prepínače, `stopReason`, `detector`, `heardSpeech`, časy reči, trasa zvuku, `ecEnabled`, `micDataSource`, počet zamietnutých prepisov, `session_id` + `question_id` (spojenie s `answer_evaluated`). Dnes tieto polia idú len do Sentry, ktoré ich po čase maže.
- **Metrika:** hlavná = „zlé zachytenie“ (nahrávka do stropu ALEBO bez reči ALEBO hráč prepis zamietol); vedľajšie = oneskorenie konca po reči, podiel správnych verdiktov. AEC a mikrofón sa hodnotia len na odpovediach, kde mali účinok (trasa, `ecEnabled`).
- **Poistky v appke:** ak po zapnutí AEC odíde zvuk z autorádia (zmena výstupnej trasy), appka AEC na tomto zariadení vypne, zaznamená udalosť a do konca experimentu ho nepridelí. Pád neurónového modelu už padá na energetickú VAD.
- **Týždenný vyhodnocovač** (GitHub Actions podľa vzoru `fresh-topup.yml` / `prod-monitor.yml`, logy len agregáty, repo je verejné): Beta-Bernoulli na prepínač, oddelene podľa trasy (BT/CarPlay vs. ostatné). Víťaz = P(lepší) ≥ 0,95, očakávaná strata < 1 p. b., ≥ 40 odpovedí na rameno a trasu → job ho zapne natrvalo (pridelenie 100 %). Poistka: rameno s výrazne horším „zlým zachytením“ vypne skôr. Po 6 týždňoch bez rozdielu ostane default OFF.
- **Oznámenie cez agenta:** job pri každom rozhodnutí (víťaz, vypnuté rameno, koniec bez rozdielu) otvorí GitHub issue so štítkom `voice-experiment` a súhrnom (len agregáty). `.claude/hooks/session-start.sh` ho pri štarte každej session vypíše (rýchle `gh issue list`, s časovým limitom, potichu pri chybe), agent to povie founderovi a issue po oznámení zavrie.
- **Hotovo** = assignment + udalosť + job + hook v main, backend nasadený, job prešiel na sucho (dry-run) aj s pravou DB, TF build z `main` vydaný (founder 2026-10-14 o build požiadal).

## Kontrakt 204.2 — zamietnuté prepisy

- `POST /voice/submit` prijme **voliteľné** pole formulára `rejected_transcripts` = JSON pole reťazcov (prepisy, ktoré hráč pri tejto otázke už zamietol cez „nie / znova“). Chýbajúce pole = dnešné správanie (appka 1.0 ostáva funkčná).
- Backend: ak normalizovaný nový prepis zodpovedá niektorému zamietnutému, skúsi ďalšiu hypotézu — Scribe s iným `seed`, potom `gpt-transcribe`. **Nápoveda nikdy neobsahuje správnu odpoveď samotnú:** MCQ dostane všetky možnosti (ako dnes), otvorená otázka žiadne `keyterms` (inak by hráč mohol zamumlať, zamietnuť a dostať uznanú správnu odpoveď). Správna odpoveď v nápovede až s podobne znejúcimi nesprávnymi odpoveďami z 204.7. Vráti prvý prepis, ktorý sa nezhoduje so zamietnutým; ak sa zhodujú všetky, vráti pôvodný. Do logu len príznak a počet pokusov, nie slová.
- iOS: zamietnuté prepisy sa držia pre aktuálnu otázku (vynulujú sa pri ďalšej otázke) a posielajú sa len pri zapnutom prepínači.

## Meranie

Replay (`scripts/voice_replay.py`) na nahrávkach z auta s prepínačmi zapnutými/vypnutými: zmena verdiktu, falošné zamietnutie / uznanie podľa jazyka, oneskorenie konca, podiel nahrávok do stropu. Na 204.3 detektor prehraný v Swift teste na Macu.

## Stav

- 2026-10-14: rešerš hotová (PR #408). **Kód 204.1–204.6 v main:**
  - Backend v154 (204.1 záložné STT `languages` + `keywords`, PR #409; 204.2 server, PR #412). 204.6 fonetická zhoda v main (PR #416), ešte nenasadená, OFF; Šekspír/Shakespeare nepokrýva (ostáva na sudcovi), Tolstoj/Tolstoy tiež nie.
  - iOS: 204.2 zamietnuté prepisy pri opakovanom pokuse (PR #413, ON), 204.3 Silero v6 VAD (PR #415, OFF, +0,65 MB, pád modelu → energetická VAD), 204.4 + 204.5 AEC na externej trase a predný kardioidný mikrofón (PR #414, OFF; 204.5 len bez voice processing).
  - Sentry „answer recording stopped“ nesie `detector`, `neuralHeardSpeech`, `avoidRejected`, `rejectedCount`, `ecFlag/ecAvailable/ecEnabled`, `micDataSource`, `micPolarPattern`.
- **Open:** TF build na požiadanie → test v aute:
  - 204.3: s prepínačom ON/OFF porovnať podiel nahrávok do stropu a oneskorenie konca.
  - 204.4: na A2DP/CarPlay musí zvuk ostať v autorádiu; `ecEnabled=false` = iOS to na A2DP nepodporuje; mód sa na externej trase mení `.spokenAudio` → `.default`, skontrolovať stlmenie hudby.
  - 204.5: `micDataSource=Front`, `micPolarPattern=Cardioid`; v režime hovoru musí prevziať mikrofón auta.
  - Potom replay na nahrávkach → rozhodnúť, čo ostane zapnuté, a 204.6 zmerať pred zapnutím. 204.7/204.8 až po meraní.
