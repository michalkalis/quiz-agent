# Research: Batch pre-translation pipeline with verification (SK/CS)

**Date:** 2026-08-31 | **Query:** Ako nahradiť ad-hoc serve-time preklad produkčnou dávkovou pipeline s overovaním (preklad, zmysluplnosť, jazykové špecifiká, regionálna relevantnosť) pre slovenčinu a češtinu; ktoré modely sú na tieto jazyky najlepšie; batch ceny; kedy generovať natívne namiesto prekladu.

## Executive Summary

- **Priemyselný vzor existuje a je jednotný:** chybová taxonómia (MQM) + LLM-rozhodca na označovanie chýb + deterministické kontroly + ľudská kontrola vzorky s eskaláciou označených položiek. Nikto nekontroluje ručne 100 % — kontroluje sa vzorka a všetko, čo automatika označí.
- **Pre kvízový obsah treba jednu kategóriu navyše, ktorú lokalizačný priemysel nerieši:** integrita odpovede — po preklade musí správna odpoveď ostať správna a distraktory ostať nesprávne. Toto je náš najkritickejší (a lacno automatizovateľný) check: nechať model naslepo zodpovedať preloženú otázku.
- **Výber modelu:** WMT25 (en→cs, automatické metriky, human eval až 11/2026) vedie Gemini 2.5 Pro pred GPT-4.1; Claude-4 solídny stred. Jediná nájdená slovenská human-eval štúdia vyhral **DeepL** (tesne pred GPT-4o), ktorý SK aj CS plne podporuje a je ~10× lacnejší než frontier LLM. Záver: rozhodnúť malým vlastným ramenným testom na našich otázkach, nie benchmarkom.
- **Batch API: všetci traja veľkí (Anthropic/OpenAI/Google) dávajú plošne −50 % s dobehom do 24 h**; OpenRouter zrkadlí provider batch zľavy. Predpreklad korpusu je nákladovo zanedbateľný (jednotky dolárov na jazyk vrátane overovania).
- **Čeština v Apple on-device diktovaní je POTVRDENÁ** (overené lokálne: `DictationTranscriber.supportedLocales` obsahuje cs-CZ aj sk-SK; nový SpeechTranscriber nemá ani jedno — rovnaká situácia ako slovenčina dnes). ElevenLabs Scribe aj Whisper podporujú obe.

## Key Findings

### 1. Ako vyzerá produkčná overovacia pipeline (prior art)

MQM je štandard hodnotenia prekladu: chyba = označený úsek + kategória (accuracy, fluency, terminológia, štýl, lokálne konvencie) + závažnosť (minor/major/critical). Taxonómia sa bežne prispôsobuje doméne (precedens MQM-Chat) — pre nás dáva zmysel „MQM-Quiz" s kritickou kategóriou **answer-flip** (preklad zmenil, čo je správna odpoveď).

LLM-rozhodca (GEMBA-MQM štýl) je oficiálny WMT baseline: model dostane zdroj + preklad a vráti chybové úseky s kategóriou a závažnosťou, bez referenčného prekladu. Pozor: prompt rozhodcu je citlivý na model (nie je prenosný bez doladenia) a multilingválna konzistencia rozhodcov je slabšia — pred nasadením validovať na malej referenčnej sade (máme presne na to postavenú 7-chybovú referenciu z #166).

Automatické QE modely (CometKiwi/xCOMET, open weights) dávajú skóre bez referencie, ale pre stredne-zdrojové jazyky majú horšiu kalibráciu — použiteľné nanajvýš ako triage signál, nie ako brána. Pre náš objem (stovky až tisíce krátkych otázok) je LLM-rozhodca jednoduchší a stačí.

Back-translation je lacný prvý filter na faktické otázky (čísla/mená/dátumy), ale zlyháva presne na idiómoch a kultúrnych posunoch — nepoužívať samostatne.

Priemyselná prax: Netflix loguje kategóriu každej opravy (nie tiché fixovanie); Airbnb vracia ľudské opravy späť do prekladového systému; všeobecný vzor = vzorkovanie + auto-eskalácia označeného obsahu človeku. Herná lokalizácia má checklist priamo použiteľný pre kvíz: jednotky, idiómy, formáty čísel/dátumov, pretečenie textu v UI.

### 2. Kvízové špecifiká (syntéza — dedikovaná literatúra neexistuje)

- **Integrita distraktorov:** preklad môže distraktor spraviť „správnym" (posun významu, gram. rod, idióm) — treba explicitný post-translation check symetrie možností, nie len plynulosť.
- **Slovné hračky:** správna akcia je vyradiť/preformulovať, nie prekladať. Náš `language_dependent` atribút z generovania je presne na to — treba ho zmeniť z observačného na tvrdý filter pre ne-EN.
- **Vlastné mená a názvy diel:** samostatná pravidlová/glosárová kontrola (naše „title rule" z buildu 53 patrí do glosára pipeline).
- **Jednotky:** plynulostný rozhodca nechytí vecne zle prevedenú jednotku — deterministický guard (čísla/jednotky sa prekladom nesmú zmeniť), plus regionálna vlajka pre imperiálne otázky (#99 už také eviduje).

### 3. Ktorý model na SK/CS

Tvrdé dáta: WMT24 vyhral Claude 3.5 Sonnet 9/11 párov; WMT25 predbežne (automatické metriky) en→cs: Gemini 2.5 Pro #1 (88,7), GPT-4.1 (80,8), Claude-4 (79,6); DeepL „spoľahlivý stred" nad malými open modelmi. Slovenská human-eval štúdia (SKASE, 90 viet, rodení anotátori): DeepL 1. (fluency 3,70 / adequacy 3,73), GPT-4o tesne 2., Google Translate 3. Pre mini-class modely na sk/cs neexistuje priamy benchmark — náš vlastný nález (gpt-4o-mini kalky → prechod na Opus) je konzistentný s literatúrou o páde malých modelov na stredne-zdrojových jazykoch, ale formálne je to neoverené.

Dôsledok: žiadny jednoznačný víťaz. DeepL má glosáre + najnižšiu cenu (~5,5 $/M znakov PAYG, free tier 500K znakov/mes.), ale nevie kontext kvízu (integrita distraktorov, vysvetlenia). Frontier LLM vie celý payload s pravidlami naraz. → ramenný test na ~30–40 otázkach: súčasný Opus vs Gemini 2.5 Pro vs GPT-4.1 vs DeepL, blind hodnotenie na existujúcom rating webe (infra z #154–#156), rozhodca validovaný proti founderovým verdiktom. Model sa nemení bez eval dát + schválenia (standing rule).

### 4. Batch ceny (overené 2026)

| Provider | Zľava | Dobeh | Poznámka |
|---|---|---|---|
| Anthropic Message Batches | −50 % in+out | <24 h (typicky ~1 h) | 10k req/batch, kombinuje sa s prompt cachingom |
| OpenAI Batch | −50 % | <24 h (1–6 h typicky) | všetky modely |
| Gemini Batch | −50 % | <24 h | všetky modely |
| OpenRouter batch | zrkadlí provider −50 % | — | náš gateway; batch quickstart existuje |

### 5. Natívne generovanie vs preklad

Žiadna dedikovaná štúdia pre kvízový obsah. Adjacentné poznatky: univerzálne témy sa prekladajú čisto, regionálne nie; preklad otázok do cieľového jazyka môže dokonca zlepšiť zrozumiteľnosť; riziká natívneho generovania = horšia faktickosť modelov mimo angličtiny + rozpad jedného korpusu na jazykové vetvy (N× QA, N× fact-check — pri našej draho vybudovanej fact-check pipeline zásadná nevýhoda). Záver: ostať pri EN ako zdrojovom korpuse; natívne generovanie zvážiť neskôr len pre **regionálne kategórie** (SK/CZ reálie), kde preklad z EN principiálne nepomôže.

### 6. Hlasová vrstva pre češtinu (overené)

- Apple `DictationTranscriber` (iOS 26 / macOS 26): **cs-CZ podporované** — overené lokálne výpisom `supportedLocales` (54 locales, cs-CZ aj sk-SK áno; overené na macOS, iOS zoznam historicky totožný — sk-SK na zariadení reálne funguje). Nový `SpeechTranscriber` nemá žiadny slovanský jazyk — čeština pôjde tou istou dictation cestou ako slovenčina.
- ElevenLabs Scribe: čeština aj slovenčina podporované (čeština v „excellent" tieri, ≤5 % WER). Whisper: obe podporované.
- Povelový slovník: čeština a slovenčina sú si po diakritickom foldingu, ktorý matcher robí, extrémne blízke („přeskoč"→„preskoc" = zhodné so SK) — český lexikón je malý prírastok k slovenskému, veľká časť sa zdieľa.

## Implications for Hangs

1. Ad-hoc serve-time preklad nahradiť **dávkovým predprekladom s bránou**: prekladá sa dopredu (batch −50 %), servíruje sa len schválený preklad; nepreložená/neschválená otázka sa v ne-EN jazyku jednoducho nevyberie do kvízu (koniec tichých únikov do EN aj čakania na LLM v hot pathe — konzistentné s pravidlom „LLM mimo hot path").
2. Overovacie stupne na otázku: (a) deterministické guardy (čísla/jednotky/formát/nepreložené reťazce — čiastočne existujú), (b) **blind answerability check** v cieľovom jazyku (odpoveď ostala správna, distraktory nesprávne), (c) MQM-Quiz LLM-rozhodca (kalky, idiómy, prirodzenosť, tituly), (d) regionálna relevantnosť (vlajka, nie auto-drop). Kritické chyby blokujú, ostatné + vzorka idú na ľudskú kontrolu cez rating web.
3. Ľudské opravy sa logujú s kategóriou a spätne kŕmia glosár/prompt (Netflix/Airbnb vzor).
4. `language_dependent` → tvrdý filter pre ne-EN (generovanie ho už nastavuje).
5. Model per jazyk: ramenný test, nie dogma; DeepL ako lacné rameno do testu.

## Recommendations

1. Postaviť batch predprekladovú pipeline s bránou (guards → answerability → MQM-Quiz rozhodca → ľudská vzorka) a stavom prekladu (pending/approved) per otázka+jazyk; servírovať len approved.
2. Pred voľbou modelu spustiť 4-ramenný blind test (Opus / Gemini 2.5 Pro / GPT-4.1 / DeepL) na ~30–40 otázkach × SK aj CS na rating webe; rozhodcu kalibrovať na založených founder verdiktoch.
3. Prekladať postupne po dávkach podľa rastu testerov (netreba celý korpus naraz); všetko cez Batch API.
4. `language_dependent` otázky vyradiť zo servírovania v ne-EN jazykoch hneď (malá zmena, nezávislá od pipeline).
5. Regionálne kategórie (SK/CZ reálie) riešiť neskôr natívnym generovaním, nie prekladom.

## Sources

1. [The MQM Framework (themqm.org, 2025)](https://themqm.org/wp-content/uploads/2025/10/2405.16969v5.pdf) — aktuálna primárna referencia taxonómie a závažností
2. [GEMBA-MQM (arXiv 2310.13988)](https://arxiv.org/pdf/2310.13988) — LLM-rozhodca s chybovými úsekmi, WMT baseline
3. [xCOMET (Unbabel)](https://unbabel.com/xcomet-translation-quality-analysis/) + [COMET GitHub](https://github.com/Unbabel/COMET) — open-weight QE; [limity pre nízko/stredne-zdrojové páry (LREC 2024)](https://aclanthology.org/2024.lrec-main.315/)
4. [WMT25 predbežné poradie (arXiv 2508.14909)](https://arxiv.org/pdf/2508.14909) + [Slator digest](https://slator.com/wmt25-preliminary-results-gemini-2-5-pro-gpt-4-1-lead-ai-translation/) — en→cs rebríček; [WMT24 findings](https://aclanthology.org/2024.wmt-1.12.pdf) — Claude 3.5 víťaz 9/11
5. [Slovenská MT human-eval štúdia (SKASE JTI29)](http://www.skase.sk/Volumes/JTI29/08.pdf) — DeepL > GPT-4o > Google Translate na slovenčine
6. [DeepL supported languages](https://developers.deepl.com/docs/getting-started/supported-languages) — SK/CS podpora, glosáre
7. [Anthropic Batch](https://docs.claude.com/en/docs/build-with-claude/batch-processing) · [OpenAI Batch](https://developers.openai.com/api/docs/guides/batch) · [OpenRouter batch](https://openrouter.ai/docs/batch-quickstart) — −50 % / 24 h
8. [Backtranslation ako QC nástroj — kritika](https://www.researchgate.net/publication/390519258_Backtranslation_as_a_Quality_Control_Tool_in_Translation_Studies_Challenges_and_Practical_Insights) — prečo nie samostatne
9. [Game Localization QA checklist (Circle Translations)](https://circletranslations.com/blog/game-localization-qa) — jednotky/idiómy/overflow checklist prenosný na kvíz
10. [Netflix Localization QC](https://partnerhelp.netflixstudios.com/hc/en-us/articles/115000353211-Introduction-to-Netflix-Quality-Control-QC) · [Airbnb adaptívna MT (Slator)](https://slator.com/airbnb-translation-engine-applies-machine-translation-to-ugc/) — logované opravy, spätná väzba do systému
11. Lokálne overenie: `DictationTranscriber.supportedLocales` (macOS 26, 2026-08-31) — 54 locales, cs-CZ ✓, sk-SK ✓; [ElevenLabs Scribe czech](https://elevenlabs.io/speech-to-text/czech)
