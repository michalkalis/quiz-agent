# Kvízové podcasty ako zdroj otázok — bezplatná extrakcia a využitie

**Dátum:** 2026-09-03 · **Stav:** prieskum + overený pilot, čaká na rozhodnutie foundera
**Zadanie:** vyextrahovať otázky/odpovede z podcastu „Kvíz, please!“ a podobných SK/EN podcastov,
bez platených služieb (žiadny ElevenLabs), a navrhnúť ich využitie.

## 1. Zdroje

### Kvíz, please! (CZ) — hlavný kandidát
- Jediný čistý kvízový podcast v CZ/SK; 160 epizód, ~50–80 min, ~70 otázok/epizóda → odhad **~10 000 otázok**.
- Formát: rozohrievačka 60 s (rýchle otázky), tematické okruhy, otvorené odpovede (nie MCQ), 3 moderátori sa striedajú.
- Audio: verejný RSS `https://anchor.fm/s/e7a79e2c/podcast/rss` (MP3 enclosure). YouTube `@Kvizplease` — plné epizódy **s českými auto-titulkami**.
- Text otázok: **neexistuje voľne**. Autori predávajú „PDF s otázkami“ cez Herohero/Forendors. Licencia nie je na webe uvedená.

### Slovenské podcasty
- **Plní rozumu** (SK, Spotify/Apple) — 10 MCQ otázok/epizóda, jedna téma; malý objem, bez textu.
- Iný čisto kvízový SK podcast **nenájdený** (SME, Denník N, RTVS, Aktuality, Refresher preverené). „Pub kvíz“ = živé eventy, nie podcasty.

### Anglické podcasty (výber s textom zadarmo = najlacnejšie)
| Podcast | Text zadarmo | Objem |
|---|---|---|
| NPR **Ask Me Another** (ukončený 2021) | plné transkripty na npr.org | ~9 rokov archívu |
| NPR **Wait Wait… Don't Tell Me!** | plné transkripty | 1000+ |
| **Trivia With Budds** | ukážkové otázky na webe | denne, 1000+ |
| Good Job, Brain! · Trivial Warfare · Triviality · BBC Brain of Britain / Round Britain Quiz | len audio (Apple prepis EN zadarmo, viď §2) | 300–1000+ |

### Hotové voľné datasety
- OpenTriviaQA (GitHub, CC), Open Trivia DB (Kaggle) — EN, hotový text.
- db-quiz (GitHub) — AZ-kvíz štýl z českej Wikipédie/DBpedia.
- Slovenský pub-quiz dataset **neexistuje**.

## 2. Bezplatný pipeline (overený lokálne 2026-09-03)

| Krok | Nástroj | Cena | Overené |
|---|---|---|---|
| Audio | RSS enclosure (curl) alebo YouTube | 0 | ✅ |
| Prepis CZ/SK — cesta A | **YouTube auto-titulky** (`yt-dlp --write-auto-subs`) | 0, žiadny výpočet | ✅ kvalita porovnateľná s Whisperom, navyše značky zmeny rečníka |
| Prepis CZ/SK — cesta B | **mlx-whisper large-v3-turbo** lokálne na M4 Pro | 0 | ✅ 22× realtime (zahriaty) → celý archív ~7 h výpočtu |
| Prepis EN | Apple SpeechAnalyzer on-device (macOS 26) alebo Whisper | 0 | ✅ EN áno; **CZ/SK Apple nepodporuje** (30 locale, bez cs/sk) |
| Extrakcia Q&A z prepisu | LLM cez session gateway (Claude Code subscription, #169) alebo Ollama lokálne | 0 (subscription) | ✅ pilot nižšie |

Poznámky: ffmpeg na tomto Macu je rozbitý (neoficiálny tap), dekódovanie MP3 → WAV zvládne vstavaný `afconvert`.

### Pilot: 10 min epizódy 160 (rozohrievačka)
- 10 min audia → 26 otázok (Whisper 248 s studený štart, potom 22× realtime).
- Odpoveď potvrdená v prepise: 21/26 · doplnená LLM z vlastných znalostí: 4 · neznáma: 1.
- ASR poznámka pri 18/26 (väčšinou drobné preklepy; **vlastné mená sú riziko**: „Adéla“ z filmu *Adéla ještě nevečeřela* prepis zachytil ako „Odela“ a LLM ju nesprávne „opravil“ na Audrey II; „Křupky“ → „Šupky“).
- Záver: extrakcia funguje, ale každá doplnená/opravená odpoveď musí prejsť fact-checkom (#166) — nie priamo do korpusu.
- Výstup: `podcast-quiz-extraction-2026-09-03-pilot.json` (26 položiek s časovými značkami a provenienciou odpovede).

## 3. Využitie v projekte — kde sa to zapojí

1. **Štýlové exempláre pre generovanie** — `apps/quiz-pack-api/data/examples/gold_standard.json` (53 položiek, few-shot do promptov). Ľudsky písané otázky s rating ≥ 8 rozšíria vzorku; slabé idú do `anti_patterns.json`.
2. **Kalibračná sada pre hodnotenie** — rating web (#154–156) prijme extrahované otázky ako blind batch; founder ich ohodnotí rovnako ako generované → prvé porovnanie „človek vs. model“ na rovnakej rubrike, regresný cieľ pre judge panel.
3. **Banka tém a formátov** — `app/sourcing/topic_pool.py`: 160 epizód × 3–4 okruhy = ~500 konkrétnych tém, ktoré reálni tvorcovia považovali za zábavné (Japonská kuchyňa, tramvaje, atentáty…). Priamo dopĺňa top-up okruhy z #167.
4. **Testovacia sada pre vyhodnocovač odpovedí** — reálne hovorené odpovede súťažiacich (nesprávne, čiastočné, „eee Piškorky“) = chýbajúci korpus pre `apps/quiz-agent` evaluator testy.
5. **Priamy import do korpusu** — `Question.source="imported"` + `source_url` existuje. **Neodporúčam bez súhlasu autorov** (viď §4).

## 4. Riziká a rozhodnutie pre foundera

- **Licencia:** otázky sú platený produkt autorov (PDF za predplatné). Hromadná extrakcia na priame použitie v appke = kopírovanie ich produktu. Inšpirácia (štýl, témy, obtiažnosť, kalibrácia) je bezpečná; verbatim import nie. Odporúčam napísať autorom (kvizplease.cz) — malý CZ/SK ekosystém, partnerstvo je reálne.
- **Jazyk:** korpus je CZ, appka generuje EN (founder pravidlo) so SK/CS vetvou (#168). Pre exempláre treba preklad alebo použiť EN podcasty na štýl a CZ len na témy/kalibráciu.
- **Rýchle kolá strácajú odpovede** v prepise (súťažiaci hovorí cez moderátora) — LLM ich doplní z vlastných znalostí, treba označiť provenience.

**Otázky na foundera:**
1. Ísť do plnej extrakcie Kvíz, please! (~10k otázok, ~7 h výpočtu na Macu, 0 €) — áno/nie?
2. Účel: len inšpirácia (témy + kalibrácia + exempláre) alebo aj priamy import? Pri importe najprv osloviť autorov.
3. Pridať EN podcasty s hotovými transkriptami (NPR) ako druhý zdroj?
