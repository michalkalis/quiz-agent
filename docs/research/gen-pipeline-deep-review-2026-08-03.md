# Generačná pipeline — hĺbkový report (2026-08-03)

Kompletný prehľad celej pipeline na generovanie otázok: každý krok, použité modely, prompty s príkladmi, zdôvodnenia (research + tvoje júlové kalibrácie), dnes nasadené zmeny a otvorené rozhodnutia.

**Ako sa vyjadriť:** otvorené body sú číslované <span class="badge warn">O1</span>–<span class="badge warn">O5</span>. Odpovedz v chate číslom (napr. „O1 áno, O3 nie, O2 vysvetli viac").

Legenda: <span class="badge ok">NASADENÉ</span> = dnes v kóde, otestované a odoslané · <span class="badge info">SCHVÁLENÉ</span> = tebou odsúhlasené, implementácia beží/naplánovaná · <span class="badge warn">OTVORENÉ</span> = čaká na tvoje rozhodnutie

---

## 1. Celkový obraz

```
Objednávka → Zber faktov → GENEROVANIE → Critique + párový výber → Overenie faktov
           → SKÓROVACIA BRÁNA → Top-up (dogenerovanie) → Uloženie
```

Po dnešnej zmene beží **dedup (odstránenie duplicít) hneď po generovaní** — predtým až na konci, takže sa platilo drahé hodnotenie aj za otázky, ktoré potom vyleteli ako duplicity.

| Krok | Model | Volaní na 12-ot. balík | Úloha |
|---|---|---|---|
| Zber faktov | žiadny LLM (Wikipedia, Tavily) | 0 | podklady — otázky vznikajú z reálnych faktov |
| Generovanie | Claude Fable 5 | ~1–6 | vyrobí 3× viac kandidátov, než treba |
| Critique | GPT-5.6 | ~36 | oznámkuje každého kandidáta (kalibrované kotvy) |
| Párový výber | GPT-5.6 | ~50–60 | duely kandidátov → výber najlepších |
| Dedup | embeddingy (lacné) | 0 | duplicity voči korpusu aj v dávke |
| Overenie faktov | Tavily + Gemini 3.1 Pro | ~12 | pravdivosť; Gemini len keď Tavily nestačí |
| Skórovacia brána | GPT-5.6 + Gemini 3.1 Pro | ~168 | 2 sudcovia × 7 dimenzií na každú otázku |
| Top-up | opakuje reťaz | podľa potreby | dopĺňa vyhodené (max 2 kolá) |

**Ekonomika:** ~95 % volaní je hodnotenie, nie tvorba. Jediné merané číslo: ~50–70 ¢ za 4-otázkový balík (OpenRouter dry-run z #134) ≈ 12–17 ¢/otázka. Detailné meranie = záverečná fáza (tvoje rozhodnutie: najprv vyladiť, potom merať).

---

## 2. Zber faktov — vstupný strop kvality

**Čo robí:** Tavily web search + Wikipedia + OpenTriviaDB → fakty zoradené podľa „prekvapivosti". Otázka nikdy nevzniká z pamäte modelu — vždy z konkrétneho faktu so zdrojovou URL (ochrana proti vymysleným „faktom", čo je podľa researchu dominantná chyba LLM generovania otázok).

**Známy problém (z #134, zatiaľ neriešený):** Tavily na všeobecné dopyty vracia „listicle" zdroje (10-najs-zoznamy). Strop kvality otázok = strop kvality faktov. Research odporúča MMR diverzitu pri výbere faktov (vyberať fakty, ktoré sú relevantné A zároveň sa navzájom nepodobajú) + tematické plánovanie pred generovaním.

<span class="badge warn">O1</span> **Fact-sourcing ako samostatný issue?** Odporúčam áno — je to zdokumentovaný hlavný strop kvality. Pripravil by som issue (lepšie zdroje, MMR diverzita, tematický plán) na samostatnú session.

---

## 3. Generovanie — prompt po častiach

Primárny prompt: `question_generation_v3_fact_first.md`. Model: Claude Fable 5 (najsilnejší dostupný; tvoje pravidlo: generácia vždy frontier). Teplota 0.8 (vyššia = kreatívnejšie).

### 3a. Persona a cieľ

> *"You are an expert pub quiz master writing trivia for a voice-only quiz played hands-free while driving. Every question is heard ONCE, by a non-native-English adult… Goal: questions that give the player a reveal — 'no way, really?' — worth retelling later. Plain recall is a defect, not a baseline."*

Prečo takto: cieľ + kontext + dôvod namiesto krokového návodu — presne štýl, ktorý Anthropic odporúča pre Claude modely. „Plain recall is a defect" kóduje tvoju júlovú kalibráciu.

### 3b. KONTRAKT — 15 tvrdých pravidiel s prioritou

Pri kolízii vyhráva vyššie: **ukotvenie vo faktoch → férová odpovedateľnosť → jazyková prenosnosť → zrozumiteľnosť na jedno vypočutie → maximálna zábava**.

| # | Pravidlo (podstata) | Prečo existuje |
|---|---|---|
| 1 | Odpoveď pochádza z JEDNÉHO zdrojového faktu, URL sa kopíruje; slabý fakt = preskoč, nikdy nesil | proti halucináciám; slabé fakty sa nezachraňujú (tvoja filozofia) |
| 2 | Každá otázka skrýva reveal — model musí pomenovať mylný predpoklad hráča, ktorý odpoveď vyvráti | operacionalizuje „prekvapenie"; ak ho nevie pomenovať, je to holá faktovka |
| 3 | Zakázané: „What is the capital of…", „Who wrote…", holé lookupy, otrepané klišé, niche fandom, US-only rámce | tvoje júlové hodnotenia (klišé penalta) |
| 4 | Prekvapenie žije v otázke a spojení — odpoveď musí byť niečo, čo hráč pozná („of course!", nie „if you say so") | founder kalibrácia — neuspokojivé odpovede zabíjajú zážitok |
| 5 | Vždy aspoň jedna cesta k odpovedi okrem pamäte: odhad, eliminácia, časová os, každodenná skúsenosť | „dead-end" otázky = najčastejšia trieda tvojich záporných hodnotení |
| 6 | Žiadne prezradenie: ani slovo odpovede v zadaní, ani rámec riešiteľný stereotypom, ani krivé dĺžky MCQ možností | tvoje príklady z 07-15 (britský tank varí → čaj) |
| 7–8 | Jedna myšlienka na vetu, JEDNA ostrá stopa; každý pojem ukotvený (vysvetlenie vzácneho termínu, dátum pri rekorde, uhol pohľadu pri vneme) | hlasový kvíz — počuje sa RAZ, za volantom |
| 9 | Odpoveď 1–5 slov, bez pomlčiek a vsuviek; vysvetlenie 1–2 hovorené vety so zaujímavou pointou | krátke odpovede sa dajú hlasom vyhodnotiť |
| 10–11 | Metrické jednotky; čísla ako ich ľudia vyslovujú; presný rok len keď je rok pointou | počúvateľnosť + medzinárodnosť |
| 12 | Otázka musí ostať PRAVDIVÁ po doslovnom preklade (kvízy bežia aj po slovensky/česky/nemecky); anglické slovné hračky = flag `language_dependent` | tvoj trh; vlajkované otázky sa v neanglických sessions nepodávajú |
| 13–14 | Max 30 % otázok začína „Which"; min. 4 rôzne vetné štruktúry; min. 4 rôzne vzory; „rozmýšľacie" vzory pred faktovkami | proti monotónnosti dávky |
| 15 | True/false: kľúče ~50/50 a nikdy netelegrafované; T/F so zaujímavým číslom sa mení na číselnú MCQ | tvoj nález: 94 % T/F odpovedí bolo „True" |

### 3c. Knižnica 13 vzorov

Od „Surprising Connection" (muškátový oriešok za Manhattan) po „Reverse Engineer" (výsledok → čo k nemu viedlo). Prompt káže: vzory 7–13 (odhad, porovnávacia stávka, laterálne hádanky…) zvyčajne bijú vzory 1–6 (faktovky) — lebo dávajú hráčovi cestu k odpovedi.

### 3d. Few-shot príklady <span class="badge ok">NASADENÉ dnes prerobené</span>

Model dostáva s každým volaním **4 gold + 3 anti-vzory**. Research: 3–5 príkladov je optimum (viac = doložené zhoršenie a homogenizácia výstupov) → počet ostáva, kvalita injektáže sa dnes zmenila:

- **Rotácia pri každom volaní** (bola: fixné na celú objednávku) — tvoje rozhodnutie; cache úspora ostáva, lebo statická časť promptu (kontrakt+vzory) sa cachuje ďalej a príklady sa presunuli za cache hranicu.
- **Zámerne rôznorodý výber** — 4 príklady = 4 rôzne vzory/témy (bolo: čistá náhoda, pokojne 4× ten istý vzor).
- **Anotácia pri všetkých 4** — každý príklad nesie „prečo je výborný" (boli len 2); pri príkladoch so skrytou odpoveďou poistka proti prezradeniu.
- **Anti-vzory ako kontrastné páry** — 14 × „zlá → opravená verzia toho istého faktu + prečo", 10 × tvrdé „NEZACHRÁNITEĽNÉ, preskoč fakt" (niche, jazykovo viazané, definície). Research: holé negatíva majú minimálny efekt, kontrastné páry +15 bodov.

Ukážka páru, ako ho model uvidí:

> **BAD:** "In what year did World War I begin?" → 1914
> **Why it's bad:** Pure date recall…
> **FIXED (same fact, done right):** "The world's first electric traffic light was switched on the same year a war broke out that would change everything. Which war?" → World War I
> **Why the fix works:** A bare date becomes a surprising collision of the mundane and the historic; the player can estimate from 'electric traffic light ≈ early 1900s'…

**Stav zásobníka:** 32 gold príkladov (tvoje hodnotenie 8+), ale krivý — veda 13, história 7, **zábava 0, šport 1, jedlo 1, MCQ len 3**. <span class="badge info">SCHVÁLENÉ</span>: hodnotiace kolo na doplnenie dier (~20–30 kandidátov, hodnotíš v chate) — na konci session.

### 3e. Diverzita kandidátov <span class="badge info">SCHVÁLENÉ, implementácia čaká</span>

Research (Verbalized Sampling, 2025): dnešné modely majú po tréningu prepad kreatívnej rozmanitosti až na ~1/4 — „vygeneruj 36 otázok" typicky dá variácie tých istých nápadov. Do promptu pribudne overená inštrukcia: pre každý fakt zvážiť viac framingov a vybrať najmenej typický, ktorý spĺňa KONTRAKT (uvádzaný zisk 2–3× diverzita pri zachovanej kvalite).

---

## 4. Critique + párový výber (výberca)

**Čo robí:** každý z ~36 kandidátov dostane známku (1 volanie GPT-5.6, teplota 0.3), potom najlepších ~24 ide do duelov („ktorá z dvoch je lepšia?") a víťazi postupujú. Research potvrdzuje: duely sú spoľahlivejšie než absolútne známky, a **kvalita výbercu je strop** toho, čo 3× nadgenerovanie dokáže priniesť.

**Čo je v critique prompte dobré (nemením):** kalibračné kotvy zo skutočných otázok pre 4 úrovne (9-10: muškátový oriešok · 7-8: banán-bobuľa · 5-6: chobotnica-srdcia · 3-4: symbol zlata), očakávané rozdelenie známok proti nafukovaniu („ak dávaš všetkému 7+, preháňaš"), a 14 tried červených vlajok s automatickými penaltami — všetky vytiahnuté z tvojich júlových hodnotení (prezradená odpoveď −3, telegrafované T/F −3, otrepané klišé −3, mŕtva ulička −2…).

**Párový výber:** deterministický „ring" — každý kandidát sa stretne s 5 susedmi (alebo všetci so všetkými pri malých dávkach), poradie A/B sa strieda na potlačenie pozičného biasu (doložený jav: sudcovia favorizujú prvú možnosť). Silnejšia mitigácia (každý pár oboma smermi, nezhoda = remíza) by zdvojnásobila volania — odporúčam odložiť do fázy merania nákladov.

### Zjednotenie rebríčka <span class="badge info">SCHVÁLENÉ, implementácia čaká</span>

Výberca dnes hodnotí starú všeobecnú taxonómiu (7 dimenzií), brána tvoju kalibrovanú (iných 7). 5 sa prekrýva, 2 sa rozchádzajú — tvoje rozhodnutia:

- **„Vzdelávacia hodnota" sa ruší** — výberca prestane odmeňovať „poučné ale nudné" (napr. *"Which gas makes up 78 % of Earth's atmosphere?"* — výberca pustí, brána zabije, peniaze prepálené). Poučnosť ostáva prirodzene v kotvách.
- **„Univerzálnosť" prestáva byť dimenziou, ostáva tvrdou červenou vlajkou** (niche = −3 penalta) — zabije zlé otázky rovnako, nezaberá miesto medzi dimenziami zábavnosti.

Výberca po prepise hodnotí tých istých 7 vlastností ako brána → celý lievik optimalizuje jedno kritérium: tvoje.

---

## 5. Overenie faktov

Faktické otázky: Tavily vyhľadá dôkazy; keď je výsledok nejednoznačný, rozhoduje Gemini 3.1 Pro. Logické/laterálne otázky: kontrola vnútornej konzistencie. Otázky s istotou pod 50 % letia. <span class="badge ok">NASADENÉ</span>: logický overovateľ mal natvrdo zadrôtovaný starší model mimo centrálneho registra — opravené, ide cez register ako všetko ostatné.

---

## 6. Skórovacia brána — 2 sudcovia × 7 dimenzií

Finálny strážnik: každú otázku známkuje GPT-5.6 aj Gemini 3.1 Pro v **7 samostatných volaniach** (jedna dimenzia = jedno volanie). Priemer pod 3.0/5 → kôš; MCQ so slabými distraktormi → kôš; veto na neodpovedateľnosť/nulové prekvapenie.

**Prečo 7 samostatných volaní:** pozorované v našej pipeline (nie teória) — pri známkovaní všetkého naraz sa známky navzájom „špinili" (zlé podanie stiahlo aj známku za prekvapenie). Research to potvrdzuje: dekompozícia znižuje aj self-preference bias o ~30 %. **Prečo 2 sudcovia z iných rodín než generátor:** modely nadržiavajú vlastnému štýlu (doložené „preference leakage") — Claude generuje, GPT+Gemini súdia.

7 dimenzií (kalibrované tvojimi hodnoteniami z júla):

| Dimenzia | Meria | Kotva |
|---|---|---|
| Rozprúdi debatu | tipy a príbehy pri stole pred odpoveďou? | 1–3 = „vieš alebo nevieš" |
| Prekvapenie | „aha!" moment | klišé = automaticky 1–3, akokoľvek pekne napísané |
| Prerozprávateľnosť | povieš to večer kamarátovi? | 9–10 = príbeh na ten istý deň |
| Vhodnosť za volant | jedno vypočutie | vnorené negácie/dvojité podmienky = 1–3 |
| Remeselné podanie | 9 konkrétnych chýb, každá stropuje na 3 | leak odpovede, telegrafované T/F, deduktívny giveaway… |
| Faktická istota | je odpoveď určite správna? | MCQ: práve jedna obhájiteľná možnosť |
| Cesta k odpovedi | odhad/eliminácia/dedukcia? | mravce vs. ľudia = 9 · „bookkeeper" = 2 |

### Navrhované opravy sudcov <span class="badge warn">O2</span>

**(a) Poradie „úvaha → známka".** Model píše výstup postupne — keď šablóna žiada známku ako prvú, vysloví ju pred akoukoľvek úvahou a úvahu už len dopisuje ako obhajobu (kanonický výsledok researchu o štruktúrovaných výstupoch). Zmena v 3 šablónach, obsah polí bez zmeny:

- brána: `{"score": 7, "reasoning": "…"}` → `{"reasoning": "…", "score": 7}`
- duel: `{"winner": "A", "reason": "…"}` → `{"reason": "…", "winner": "A"}`
- critique: JSON blok sa preusporiada — najprv zdôvodnenie/silné/slabé stránky/vlajky, až potom známky a verdikt

**(b) Teplota Gemini sudcu 0.3 → 1.0.** Oficiálna dokumentácia Googlu pre novú generáciu Gemini: pod 1.0 hrozí zacyklenie a degradovaný výstup. GPT sudca ostáva na 0.3. Jedna hodnota v konfigurácii.

**Odporúčam schváliť obe.** Nulové navýšenie nákladov, rubriky/kotvy/prahy sa nemenia.

---

## 7. Dnes nasadené zmeny (commity)

| Commit | Zmena | Efekt |
|---|---|---|
| `2e6a4b86` | dedup pred overenie+skórovanie; logický overovateľ cez register; kvalitové poistky default zapnuté | neplatí sa hodnotenie duplicít; už sa nemôže zopakovať „lokálny beh bez poistiek" (Bedrock incident) |
| `da05f126` | rotácia príkladov per call, rôznorodý výber, anotácie všade, cache hranica presunutá | lepšia diverzita učebných príkladov bez straty cache úspory |
| `2bdc78ee` | 14 kontrastných párov + 10 „nezachrániteľné" anti-vzorov | model vidí „takto nie → takto áno" namiesto holých zákazov |

Testy: 768 zelených po každej zmene. Všetko odoslané na main.

---

## 8. Schválené, čaká na implementáciu

1. **Zjednotenie rebríčka výbercu na tvoju taxonómiu** (bez „vzdelávacej hodnoty", univerzálnosť ako vlajka) — prepis critique promptu.
2. **Verbalized sampling** do generačného promptu (diverzita kandidátov).
3. **MCQ dráha = textová dráha** (nadgenerovanie + critique + výber aj pre MCQ, len iné parametre) — tvoja požiadavka „jedna pipeline, nie dve".
4. **Hodnotiace kolo na gold zásobník** — kandidáti do dier (zábava/šport/jedlo/MCQ/rozmýšľacie vzory), hodnotíš v chate, do zásobníka len 8+.

---

## 9. Otvorené rozhodnutia — odpovedz číslom v chate

| # | Otázka | Odporúčanie |
|---|---|---|
| <span class="badge warn">O1</span> | Fact-sourcing (hlavný strop kvality) ako samostatný issue na ďalšiu session? | áno |
| <span class="badge warn">O2</span> | Opravy sudcov: úvaha→známka (3 šablóny) + Gemini teplota 1.0 (presné znenie v sekcii 6) | schváliť obe |
| <span class="badge warn">O3</span> | Overovanie odpovedateľnosti „naostro": iný model skúsi otázku reálne zodpovedať bez znalosti odpovede (round-trip check) namiesto čistého názoru sudcu — research: odpovedateľnosť je najslabšia dimenzia všetkých QG pipelines | pridať pri MCQ zjednotení |
| <span class="badge warn">O4</span> | Poradie duelov oboma smermi (silnejšia ochrana proti pozičnému biasu, 2× volaní duelov) | odložiť do fázy merania |
| <span class="badge warn">O5</span> | Fáza nákladov na konci: zmerať reálny rozpad (OpenRouter per-request + AWS), otestovať lacnejší variant brány — research „Panel of LLM juries": 3 menší sudcovia z 3 rodín bijú 1 veľkého pri 7× nižšej cene; a rozhodnúť EVAL model (hot-path známkovač odpovedí, dnes gpt-4o-mini) | áno, po vyladení |

---

*Research podklady s citáciami: `docs/research/gen-pipeline-best-practices-2026-08.md` (6 tém: sudcovia, best-of-N, few-shot, per-model prompting, trivia pipelines, chýbajúce kroky).*
