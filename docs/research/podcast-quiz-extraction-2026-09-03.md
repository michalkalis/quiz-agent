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

**Founder rozhodnutia (2026-09-03):** nie celý korpus, najprv pár epizód → ohodnotiť → potom rozhodnúť · **len inšpirácia, priamy import určite nie** (možno nové témy/kategórie) · NPR skúsiť.

## 5. Kolo 1: 3 epizódy extrahované, 61 otázok na hodnotení

**Extrakcia** (YouTube titulky → Sonnet, 0 €): epizódy Japonská kuchyně/Polsko/atentáty · Věže/Poslanecká sněmovna/slang · Pivní zeměpis/slogany/LEGO → **153 otázok** (52 + 53 + 48). Voľne dostupný je len prvých ~55 min každej epizódy (zvyšok za paywallom), t. j. ~50 zo 70 otázok. Odpoveď potvrdená v nahrávke: 141/153, doplnená LLM: 7, neznáma: 5. CZ-lokálnych: 53/153 (tretina).

**Hodnotiaci batch** `1d2085e8` (61 otázok, stratifikované podľa kola, CZ-lokálne obmedzené na 5, LLM-doplnené odpovede označené ⚠ v poznámke, link na YouTube s časom):
`https://quiz-pack-api.fly.dev/web/rate/1d2085e8-a564-4c2a-9376-b2cc3fa39e54?rater=michal`
Rating nemá vplyv na korpus (import je samostatný skript, nespúšťať). Export: `scripts/rating_page/export_ratings.py`.

**Formáty kôl (inšpirácia pre nové herné módy):**
- *Rozehřívačka* — 60 s rýchlych otázok na hráča (10–15 Q), skóre = počet správnych. → kandidát na „blesk“ režim v aute.
- *Tematické kolo* — 10 otázok na jednu úzku tému (LEGO, veže, japonská kuchyňa). → náš top-up okruh, ale témy sú konkrétnejšie než naše kategórie.
- *Tipovačka* — 5 číselných odhadov (kto je bližšie, vyhráva). → nový formát bez „správne/nesprávne“, ideálny pre hlas.
- *Hádačka* — postupné nápovedy k jednému pojmu, skorší tip = viac bodov. → hlasovo prirodzené, zatiaľ nemáme.
- *Co je čtvrté?* — doplň štvrtý prvok trojice. · *Slovník mládeže* — vysvetli slang.

**Banka tém:** 377 unikátnych okruhov z názvov 128 bežných epizód → `docs/testing/runs/podcast-kvizplease-2026-09-03/themes-160-episodes.md`. Nápadne časté a u nás chýbajúce: značky a slogany, seriály/telenovely, hry (LEGO, Pokémon, karty), „bizarné zákony“, deti slávnych, zaniknuté štáty.

**NPR (EN) — skúsené, slabý výnos:** Ask Me Another (transkripty sú len 4-min segmenty, slovné hry) 8 otázok/2 epizódy; Wait Wait (novinový kvíz, väčšina otázok zastará do roka) 9 otázok, 5 evergreen. Spolu 17 → `npr_qa.json`. Verdikt: ako zdroj otázok nie; ako inšpirácia formátov („Bluff the Listener“ = 3 príbehy, jeden pravdivý) áno.

**Ďalší krok:** founder ohodnotí batch → export → porovnať priemer/rozptyl s generovanými batchmi (rovnaká 1–10 rubrika) → rozhodnúť o ďalších epizódach a o nových formátoch/témach.
