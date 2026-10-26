# Issue #212 — Brány kvality otázok: celá otázka proti zdroju, jazyk pred schválením, prekontrolovanie fondu

**Triage:** enhancement · ready-for-agent

**Review:** /design-soundness 2026-10-25 — 1. kolo UNSOUND 0,55 (hash pri hraní, sťahovanie zdroja, rozklad na tvrdenia bez prior art) → opravené → 2. kolo SOUND 0,8.

**Status:** 2026-10-26 founder schválil plán s rozpočtom **do 50 $** na prvú etapu; potom spolu overíme a ďalšie skupiny otázok pôjdu postupne (podľa nového Max kreditu). Výsledky prekontrolovania najprv ako prehľad, stav otázok sa mení až po founderovom súhlase.

**Created:** 2026-10-25 · Súvisí: #210 (kontrola obsahu pre Instagram našla 18 chýb), #166 (fact-check provider), #211 (kontrola prirodzenosti sk/cs), #203 (gates-v1)

**Podklad:** `docs/research/question-qa-root-cause-2026-10-25.md` (vetva `feat/210-reel-redo`) — 18 potvrdených chýb, príčiny s odkazmi do kódu, rozsah v prod.

## Cieľ a definícia hotového

Schválená otázka (`review_status = approved`, ktorú hrá appka) nemá chybu vo faktoch ani v jazyku v žiadnom poli, ktoré hráč vidí alebo počuje.

Hotové, keď:
1. Všetkých 18 chýb z podkladu nová sada brán (`gates-v2`) zachytí — regresný set v testoch, každá chyba = jeden prípad, ktorý musí padnúť.
2. Žiadna cesta do `approved` neobíde `gates-v2` (import, ručné hodnotenie, vynútený `--review-status`, úprava textu po schválení).
3. Celý schválený fond (1 519 korpus + 644 sk/cs preklady) prešiel `gates-v2`; čo neprešlo, je v `pending_review` s dôvodom, nič nezmazané.
4. Kvalita otázok sa neznížila: prísnejšia latka len vyraďuje, nemení obsah prešlých otázok.

## Príčiny → oprava (zhrnutie podkladu)

| # | Príčina (počet chýb) | Štrukturálna oprava |
|---|---|---|
| P1 | Fact-check vidí len otázku + odpoveď, nikdy vysvetlenie (9) | F1 celá otázka proti zdroju |
| P2 | Jazyková kontrola sk/cs číta len otázku a o schválení nerozhoduje (7) | F4 jazyková brána všetkých polí pred schválením |
| P3 | „ok“ s nízkou istotou prejde; akákoľvek URL je zdroj (4) | F2 zdroj sťahujeme sami + F3 latka a kvalita zdroja |
| P4 | Staré importy bez brány (3) | F6 jediná cesta do approved + prekontrolovanie |
| P5 | Úprava po schválení nič nespustí (1, systémová diera) | F5 schválenie viazané na presný text |

## Štrukturálne opravy

### F1 — Fact-check celej otázky
- Overovač dostane všetko, čo hráč vidí a počuje: otázka, možnosti (MCQ), správna odpoveď, vysvetlenie (to sa číta nahlas).
- Prompt sa mení z „over pár otázka–odpoveď“ na „rozlož na tvrdenia a každé over“ — overený vzor rozkladu na atomické tvrdenia: FActScore (Min et al., EMNLP 2023), SAFE (Wei et al., Google DeepMind 2024), FacTool (Chern et al. 2023). Build-vs-adopt: preberáme vzor (prompt), nie knižnicu — tie sú postavené na dlhé texty a vlastné vyhľadávanie, naša otázka má 3–6 tvrdení a už máme overovač s webom.
- Výstup: tvrdenia so stavom `supported | unsupported | contradicted` + citácia.
- Pravidlo podľa druhu tvrdenia (rieši hlavný zdroj falošných poplachov z FActScore/SAFE — tvrdenia, ktoré zdroj nespomína):
  - **Kontrolovateľné fakty** (čísla, mená, názvy diel, dátumy, miesta, príčiny, superlatívy, tvrdenie v otázke): musia byť `supported` zdrojom alebo dôveryhodným webom; `unsupported` aj `contradicted` = nález (Star Wars, Styles, slon, krokodíl, Maine).
  - **Rámcovanie a kolorit** („je to obľúbená tradícia“): nález len pri `contradicted`.
- Ak je odpoveď správna, ale tvrdenie v otázke nepravdivé → nález (prípad Star Wars).
- Kontrola súdržnosti riadku: vysvetlenie nesmie protirečiť vlastnému `source_excerpt` (slon 40 000 vs 150 000).

### F2 — Zdroj si sťahujeme sami
- Build-vs-adopt (preberáme, nestaviame):
  - **Wikipédia** (väčšina zdrojov): MediaWiki API (`action=query&prop=extracts`, `explaintext`, s `revid`) — čistý text bez HTML, pripnutá revízia. Nahrádza aj ručné delenie na vety podľa „. “ (`wikipedia_source.py:140`, rozbilo názov albumu Harryho Stylesa).
  - **Ostatné stránky:** `trafilatura` (open-source extraktor hlavného textu, štandard v NLP pipeline); keď vráti prázdno (JS stránka), záložne predinštalovaný Playwright/Chromium.
- Uloží sa stiahnutý text, `revid`/dátum a hash stránky → opakované behy (dry run vs zápis) sú porovnateľné aj keď sa Wikipédia medzitým zmení.
- Deterministicky sa overí, že `source_excerpt` je v texte (po normalizácii medzier, úvodzoviek, pomlčiek; tolerancia na drobné úpravy cez fuzzy zhodu, hranicu nastaví eval); nezhoda = nález „výňatok nie je zo zdroja“.
- Overovač dostane stiahnutý text ako hlavný dôkaz; webové vyhľadávanie len ako doplnok (zdroj v inom jazyku — Hromnice, alebo tvrdenie mimo stránky).
- **Nedostupný zdroj** (bot-blok, cookie wall, paywall, 404) nie je automaticky pád: overovač skúsi web; ak nájde dôveryhodný zdroj, ktorý tvrdenia nesie, navrhne ho ako nový `source_url` — ten musí prejsť celé F2 + F3 a je označený na kontrolu foundera (model si nesmie schváliť vlastný dôkaz). Ak nie → `pending_review` s dôvodom „chýba overiteľný zdroj“. Dry run (krok 7) ukáže podiel nedostupných ešte pred akýmkoľvek zápisom.

### F3 — Latka istoty a kvalita zdroja
- Schválenie len pri „ok“ s vysokou istotou. Východisko: skóre ≥ 0,9 (stredná 0,7 a nízka 0,5 → `pending_review`); konečnú hranicu nastaví eval (presnosť/záchyt pri každej hranici), nie pevné číslo — istota je vlastný odhad modelu bez kalibrácie.
- Kvalita zdroja: zoznam zakázaných typov (fóra, diskusie, produktové stránky a e‑shopy, `dev`/`staging`/`localhost` hosty, listicle/clickbait) + preferované (Wikipédia, encyklopédie, inštitúcie, úrady, odborné a seriózne spravodajské zdroje — podľa `feedback_source_trust_hierarchy`). Neznámy host ide na klasifikáciu modelom; výsledok sa ukladá s verziou do prehľadného zoznamu v repe (dá sa skontrolovať a opraviť, zlý verdikt neplatí ticho pre všetky otázky).
- Pravidlo „každá otázka musí mať zdroj“ ostáva; nové je, že zdroj musí byť dôveryhodný a musí tvrdenia skutočne niesť.

### F4 — Jazyková brána sk/cs pred schválením
- Kontrola prirodzenosti/gramatiky (#211, model `NATURALNESS` = Opus 5.5, bez zmeny) číta otázku, odpoveď, možnosti aj vysvetlenie.
- Jej verdikt je súčasť schvaľovacieho pravidla (`machine_approval.py`); v importéri beží **pred** rozhodnutím o schválení, nie po ňom.
- Deterministická hygiena textu: odtrhnuté zvyšky na konci vety (P+R „ďalej MHD“), zhoda pádu odpovede s otázkou („Aké budú?“ → odpoveď v 1. páde), zdvojené medzery, nedokončené vety.
- Preklady sk/cs anglických otázok prechádzajú rovnakou jazykovou bránou; fakty sa overujú na EN rodičovi; navyše deterministická kontrola, že čísla, roky, jednotky a vlastné mená v preklade sedia s EN rodičom (preklad môže priniesť vlastnú chybu).

### F5 — Schválenie viazané na presný text
- Pri schválení sa uloží odtlačok (hash) presného textu viditeľných polí (otázka, možnosti, odpoveď, vysvetlenie — tak, ako ich hráč dostane; pre sk/cs preklad jeho vlastné polia) + verzia brán.
- **Vynútenie na strane zápisu, nie pri hraní:** všetky zmeny textu idú cez jednu funkciu v repozitári otázok, ktorá prepočíta odtlačok a pri zmene zhodí otázku do `pending_review`; poistka v databáze (trigger na textových stĺpcoch), aby to neobišiel ani priamy SQL zápis. Ak sa zmení EN rodič, jeho preklady idú tiež do `pending_review`.
- Každá zmena stavu/textu sa premietne aj do kópie vo vyhľadávači otázok (Chroma) v tej istej operácii; inak by sa stiahnutá otázka hrala ďalej.
- Appka a jej vyhľadávanie otázok ostávajú bez zmeny (filtrujú len `approved`) — žiadna práca navyše pri hraní, žiadna zmena API.
- `check_naturalness.py --apply`, autofix a štýl domu prechádzajú touto funkciou.

### F6 — Jediná cesta do `approved`
- `GATE_VERSION = machine:gates-v2`.
- Zrušiť vynútený `--review-status approved` v importéri (alebo ho podmieniť prejdením brán).
- Founderovo hodnotenie zábavnosti sa ukladá zvlášť; samo nenastaví `approved` bez brán.
- Model fact-checku pripnutý: v session behu sa už ticho nemení na `session:sonnet`. Zmena modelu len s eval dátami a súhlasom foundera.
- Audit: `reviewed_at` po riadkoch, nie jeden čas za celý import.

## Model a náklady

**Modely (bez zmeny bez súhlasu):** fact-check ostáva na schválenom `gpt-5-mini` + web (#166, 7/7 na referenčnom sete); jazyková brána ostáva na Opus 5.5. Nový je len rozsah (celá otázka) a stiahnutý zdroj.

**Podmienka pred prekontrolovaním:** eval nových brán na sete 18 chýb + ~40 čistých schválených otázok (kontrola falošných poplachov). Ak `gpt-5-mini` s novým promptom nezachytí aspoň 17/18 faktických+zdrojových chýb, prinesiem founderovi porovnanie s Opus 5.5 / Sonnet 5 a rozhodnutie o modeli — nie tichú výmenu.

**Odhad nákladov (prekontrolovanie celého fondu):**

| Krok | Počet | Cena / ks (odhad) | Spolu |
|---|---|---|---|
| Fact-check celej otázky (gpt-5-mini + stiahnutý text; web len ako doplnok) | 1 519 korpus (preklady dedia EN výsledok) | 3–8 ¢ (horná hranica = web pri každej) | 45–120 $ |
| Jazyková brána sk/cs, všetky polia (Opus 5.5, dávky po ~10) | 823 natívnych + 644 prekladov = 1 467 | 1–2 ¢ | 15–30 $ |
| Klasifikácia neznámych hostov zdroja | ~300 hostov | <1 ¢ | <3 $ |
| Eval (18 chýb + 40 čistých, 2–3 kolá) | ~170 behov | 5–10 ¢ | ~15 $ |
| Rezerva na opakovanie po oprave promptu | — | — | ~30 $ |
| **Spolu** | | | **~110–200 $** |

Stiahnutie zdrojových stránok je zadarmo (priame HTTP). Prevádzka nových otázok: +1–3 ¢ na otázku oproti dnešku. Čísla sa spresnia po evale; ak by prekročili 250 $, zastavím a pýtam sa.

## Rozpočet po etapách (founder 2026-10-26)

- **Etapa 1 (strop 50 $):** brány F1–F6 v kóde, eval (~15 $), skúšobné prebehnutie bez zápisu na 145 starých EN (~8 $), 96 prepísaných (~6 $) a 316 s nízkou istotou (~20 $). Ak by sa strop blížil, poradie je 145 → 96 → 316 a zastavím pred prekročením.
- **Ďalšie etapy:** zvyšok fondu a preklady po skupinách, každá s vlastným súhlasom foundera a odhadom.

## Čo sa stane s otázkou, ktorá neprejde

- Presun `approved → pending_review`, **nikdy zmazanie**. Do metadát sa uloží dôvod (zoznam nálezov, verzia brán, dátum), takže sa dá vrátiť.
- Ak neprejde EN rodič, idú do `pending_review` aj jeho sk/cs preklady.
- Appka ju hneď prestane hrať (hrá len `approved`).
- Fronta opráv:
  1. Automatická oprava len tam, kde je to bezpečné: jazykové chyby (prepis s rovnakým obsahom) a vysvetlenie prepísané výlučne zo stiahnutého zdroja → znova celé `gates-v2` → späť do `approved`.
  2. Faktická chyba v otázke/odpovedi alebo slabý zdroj bez náhrady → ostáva v `pending_review` (nová otázka sa negeneruje automaticky).
- Pred hromadnou zmenou stavu report: koľko padne podľa jazyka/kategórie. Ak by niektorý jazyk alebo kategória klesla pod úroveň, ktorá ovplyvní hranie (napr. opakovanie otázok), ukážem to founderovi pred zápisom.

## Poradie krokov

Každý krok = vlastné PR podľa `.claude/rules/shared.md`. Nič v prod pred súhlasom foundera s týmto plánom.

1. **Regresný set** — 18 chýb z podkladu + 30 záznamov `hold` z druhého kola ručnej kontroly #210 (`apps/social-studio/batches/content-review.json` na `feat/210-reel-redo`), 2 vyradené z podkladu ako kontrola falošných poplachov ako testovacie dáta; testy, ktoré dnes prejdú a majú padnúť.
2. **F2 sťahovanie zdroja + overenie výňatku + kvalita zdroja (F3 časť zdroj)** — deterministické, lacné, bez modelu.
3. **F1 fact-check celej otázky + latka 0,9 (F3)** — nový prompt, eval na regresnom sete + 40 čistých. Brána: ≥ 17/18, falošné poplachy ≤ 10 %.
4. **F4 jazyková brána všetkých polí pred schválením + hygiena textu.**
5. **F5 odtlačok textu (zápis + DB trigger) + F6 jediná cesta do approved, `gates-v2`** — appka a API bez zmeny.
6. **Deploy quiz-pack-api** (brány pre nové otázky) — po kroku 5.
7. **Prekontrolovanie, len čítanie (dry run)** v poradí rizika: 145 starých EN bez brány → 316 s nízkou istotou → 96 prepísaných po schválení (+9 stále označených) → zvyšok korpusu → 644 prekladov. Výsledok: report počtov a nálezov, žiadny zápis.
8. **Prehľad founderovi, po súhlase zápis stavov** po skupinách v rovnakom poradí: `approved → pending_review` s dôvodom; po každej skupine kontrola, že množina otázok, ktoré vyhľadávač vracia, sedí s `approved` v databáze.
9. **Fronta opráv** — bezpečné automatické opravy, znova brány, späť do approved; zvyšok report founderovi.
10. Uzavretie: TODO, INDEX, pamäť.

## Riziká

- **Falošné poplachy** vyradia dobré otázky → eval s čistými otázkami, report pred zápisom, nič sa nemaže.
- **Zdroje sa menia/miznú** (Wikipédia sa upraví) → pri overení sa uloží stiahnutý výňatok a dátum; nedostupný zdroj = hľadať náhradu, nie automatický pád celého fondu (dry run ukáže koľko).
- **Úbytok otázok v sk/cs** → report podľa jazyka pred zápisom (krok 7).
- **Cena** nad odhad → strop 250 $, potom stop.

## Rozhodnutia foundera

- 2026-10-26: plán schválený, celý odhad (110–200 $) „mega náklad“ → etapa 1 do 50 $, ďalej postupne.
- 2026-10-26: neprešlé otázky najprv ako prehľad, zápis až po súhlase.
