# #203 — Nudné otázky: príčina a náhrada (pôvodne „otrepané otázky“)

**Triage:** bug · in-progress
**Založené:** 2026-10-14 (founder z TF: otázka „Ktorá žena v roku 1955 v Alabame odmietla uvoľniť miesto v autobuse…“ = „hrozná otázka … nezaujímavá“; „nezábavnosť otázok je úplne kritická vec“)
**Súvisí:** [kalibrácia 07-09](../research/question-quality-founder-calibration-2026-07-09.md) (founder: otrepané otázky rovno vyradiť, bez prepisovania), [prior art 07-10](../research/question-craft-prior-art-2026-07-10.md) (4.6: rozhoduje otázka, nie známosť faktu), #201 — zábava, na ktorú sa dá odpovedať (kontrola „bežný hráč“ nepredpovedala hodnotenie → preto slepé overenie pred nasadením)

## Cieľ a kedy je hotovo

Zo schválenej zásoby zmiznú otrepané učebnicové otázky a nové sa do nej nedostanú.
**Hotovo** = (1) founder naslepo potvrdí, že kontrola sa zhoduje s jeho vkusom; (2) označené otázky sú v archíve (nič sa nemaže) a zásoba kategórií ostáva nad strážnou hranicou #199; (3) kontrola beží pri generovaní.

## Diagnóza (2026-10-14)

- Otázka `4309b697…` (history, `direct_v1`, claude-fable-5, 2026-10-01): schválená strojovo (`machine:gates-v1`), prešla len overením faktu (0,9) a deterministickými kontrolami znenia. Žiadne hodnotenie zábavy ani otrepanosti sa nepočítalo.
- Od zoštíhlenia #166 sú porotcovia (`JUDGE_GATE`) aj kritika s pravidlom „Overexposed Cliché“ (`BEST_OF_N`) vypnuté: nepredpovedali zábavu (Spearman ≤ 0,21). Nič ich pri otrepaných otázkach nenahradilo. Prompt generovania má len mäkkú vetu „nenechaj dávku stáť na klasikách“.
- Zásoba: 1 465 schválených, 1 212 mimo zábavy. 904 vzniklo jedným hromadným behom 2026-10-01.
- Ručná vzorka 80 otázok: 21 % otrepaných (s hraničnými ~30 %). Ďalej 3 páry takmer duplicitných otázok, jedna pokazená MCQ bez možností v znení a jedna, ktorá prezrádza odpoveď (mimo rozsahu tohto issue).

## Rozhodnutia foundera (2026-10-14)

- **Vyčistiť aj zabrániť.** Kontrolu najprv naslepo overí founder, potom archív + zapojenie do generovania.
- **Len otrepané**, nie „cudzie témy“: svetová téma s prekvapivým uhlom ostáva aj v sk/cs.

## Riešenie

### 203.1 Kontrola „otrepaná otázka“ (vyskúšané, kód odstránený po 203.2)

`app/verification/stock_question.py`: jedno dávkové volanie (20 otázok), Opus 5.5 (`LLM_ROLE_STOCK_QUESTION`). Pri chybe sa otázka ponechá. Kotvy sú founderove hodnotenia z 07-09 (King of Pop, mendelévium, Monopoly, Rio → otrepané; míľa, Point Nemo, Kleopatra, Dumbledore → nie) plus Rosa Parks.
- v1 promptu hodnotila očami kvízového fanúšika → 63 % otrepaných (aj „hroch je príbuzný veľryby“). v2 = očami bežného dospelého, ktorý hrá kvíz raz za čas, „pri pochybnosti nie“ → **273 / 1 212 (23 %)**, sedí s ručnou vzorkou. Rosa Parks označená.
- Kód (kontrola + skript len na čítanie) bol v PR #403 a po neúspešnom slepom overení sa z PR odstránil (je v histórii commitu e48f2d48). Výsledky sú v `docs/testing/runs/stock-questions-2026-10-14/verdicts.json` (v1 v `verdicts-v1-too-strict.json`).

### 203.2 Slepé overenie (čaká na foundera)

30 otázok (15 označených + 15 ponechaných, seed 203, zamiešané): https://claude.ai/artifact/36gGSiEMXVdpZeouTKPDLk. Kľúč je v `blind_key.json`.
Prah: ≥ 12/15 označených founder vyhodí a ≤ 3/15 ponechaných by vyhodil → ide sa ďalej. Inak sa podľa jeho poznámok upraví prompt a overenie sa zopakuje.

**Výsledok (2026-10-14): kontrola NEPREŠLA, nenasadzuje sa.** Z 15 označených founder vyhodil 4, z 14 ponechaných 7 (jedna bez hodnotenia), čiže kontrola je horšia ako náhoda. Celkovo dal vzorke **~2/10**: „veľmi nudné, veľmi fact-based, veľmi ťažké vedieť odpoveď“. Ako problém vidí úzke, špecifické fakty, ktoré bežný človek nemôže vedieť (Titanicove sesterské lode, etiópsky kalendár, Ibn Battúta, Einsteinova Nobelova cena). Otrepanosť nie je hlavný problém, Rosa Parks je skôr výnimka. Founder sa pýta, či sa niečo nepokazilo, keďže nedávno sa generovali dobré otázky → prešetruje sa zmena generovania medzi dobre hodnotenými dávkami (08/09) a dnešnou zásobou (hromadný beh 2026-10-01). Výsledky: `ratings_raw/`.

### 203.3 Archív

Označené otázky → `archived` s poznámkou `#203 stock question`. Návrat je jeden UPDATE. Pred zápisom sa skontroluje zásoba po kategóriách proti hranici #199. Rozšíriť `archive_questions.py` o zoznam id.

### 203.4 Generovanie

Kontrola sa zapojí do `ScoringStage` rovnako ako kontrola „bežný hráč“ z #201 (CLI + worker, aj týždenný job #202), za vypínačom `STOCK_QUESTION_GATE`. Zapne sa po 203.2. Otrepaná otázka vypadne a top-up ju nahradí.


### 203.5 Pokles kvality generovania

Zistené (2026-10-14): 25 z 30 hodnotených otázok pochádza z hromadného behu 2026-10-01. Dávku s hodnotením 9,15 (2026-09-03) vyrobil prompt `v2_cot` (vzory zábavných otázok + „Boring Detector“). Commit 56fba3fb (2026-09-02, PR #71) prepol hromadné behy na `direct_v1`, ktorý výslovne dovoľuje „jednoduchú priamu otázku na fakt“. Od #177 (2026-09-10) schvaľuje stroj (88 % schválených), ktorý zábavnosť nemeria. Prompty sa od 08-18 nemenili.

**Rozhodnutia foundera (2026-10-14):** slepé porovnanie `v2_cot` vs `direct_v1`; októbrovú dávku riešiť až keď bude jasná oprava (prípadne ju prehnať kontrolou); každý ďalší hromadný beh pred zverejnením → slepá vzorka ~20 otázok, do hry len pri priemere ≥ 7/10.

Slepé porovnanie: Opus 5.5 pripnutý, nastavenie ako ostrá prevádzka (`fresh_pins.py` + `--no-judges`), rovnaké 4 témy z behu 10-01, 6 otázok na tému a rameno, `--dry-run`. A = `v2_cot` (23 prešlo bránami), B = `direct_v1` (24). Na hodnotenie 12 + 12: https://claude.ai/artifact/XKvYqK8iAYrykwWeQwH31K. Run adresár: `docs/testing/runs/prompt-ab-2026-10-14/`.

**Výsledok (2026-10-14, 12 + 12):** A (`v2_cot`) zábava ⌀ 7,4, šanca 12/12 · B (`direct_v1`) ⌀ 7,3, šanca 10/12; v oboch 6× hodnotenie ≥ 8. **Zadanie nie je príčina**, rozdiel je v šume. Founder: „možno trochu lepšie celkovo, ale stále nič extra … je to proste nudný kvíz“. Najvyššie (9): prekvapivé otočenie bežnej skúsenosti (kovová vs drevená lyžica, dochádzanie z Európy do Ázie v Istanbule, wasabi je chren). Najnižšie (5–6): roky a trvanie ríš, Rusko (2× „nemám rád“), neznáme historické postavy (Mansa Musa, Bukefalos), porovnania s očakávanou odpoveďou (Briti a čaj).


### 203.6 Zadanie podľa vkusu + domáce otázky + hra (founder 2026-10-14)

Founder zvolil tri smery: domáce sk/cs otázky, zadanie podľa jeho vkusu a výskum, prečo je to nudná hra.
- Vkus: `founder_ratings_all.json` (507 hodnotených otázok, 194 s ≥ 9, 62 s ≤ 5) → `taste-2026-10-14/taste_brief.txt` (len slot `--prompt`, jadro promptu bez zmeny).
- Slepé hodnotenie 30 otázok: T = vkus en, S = vkus + domáce sk, N = recept natívnych sk z 10-08, X = 6 nehodnotených `direct_v1` en ako kotva. https://claude.ai/artifact/QMM2TsFpBN3wEBqQJf2LGv
- Výskum hry: `docs/research/quiz-game-fun-2026-10-14.md`. Top 5: stávka v každom kole, odhalenie odpovede ako moment („trafilo len 23 %“), hra pre viacerých v aute, moderátor s osobnosťou, rôzne formáty v kole.

**Výsledok (2026-10-14, 30 otázok):** T (vkus en) ⌀ 8,4 · S (vkus + domáce sk) ⌀ 8,1 · N (recept sk z 10-08) ⌀ 7,5 · X (dnešný `direct_v1` en, kotva) ⌀ 8,3. Žiadna otázka ≤ 5. Kotva X dostala minule 7,3 a teraz 8,3, takže founderova stupnica sa medzi kolami posúva. **Vkus v en nad dnešný recept nepreukázaný (T ≈ X); v sk zadanie podľa vkusu porazilo recept z 10-08 (8,1 vs 7,5): menej rokov a „školských“ otázok.**
**Hlavné zistenie dňa:** čerstvo generované otázky (Opus 5.5) dostávajú 7,3 až 8,4 pri akomkoľvek zadaní, kým vzorka zo zásoby (25/30 z behu 2026-10-01, Fable 5 cez predplatné, 15 otázok na jednu širokú tému) dostala ~2/10. Problém je teda hromadný beh 10-01, nie súčasné generovanie. Cena: ~9 centov za otázku (malé dávky, väčšinu tvorí overovanie).

**Hra (founder 2026-10-14):** z výskumu sa mu páči bod 2, porovnanie s ostatnými hráčmi („túto trafilo len 23 %“), „možno najskôr zo všetkých, ale nie teraz“. Ostatné body zatiaľ nie.

### 203.7 Plný korpus 200/jazyk cez predplatné

- **Pilot (2026-10-14):** `general-pilot-2026-10-14/`, predplatné, 5 úzkych tém × 4 → en 18, sk 20, cs 20. Slepé hodnotenie 30 (E/K/C po 8 + 6 kotiev A = nehodnotené T/S z `taste-2026-10-14`): https://claude.ai/artifact/7EgUpVsJSJmvggLLdNbRQx
- **Výsledok pilotu:** en ⌀ 7,9 · sk ⌀ 8,5 · cs ⌀ 7,6 · kotva A ⌀ 6,7 (ráno 8,1–8,4 → stupnica dnes prísnejšia). Brána ≥ 7 splnená. Founder slovne: „ok, dá sa, nadšený nie som; stále príliš kvízovito nudné, chýba variabilita a väčší zdroj zábavnosti.“
- Zistenia: 4-otázkové dávky padali celé pri 3/4 → `--floor-fraction 0`. Duplicity v rámci behu (8 párov v 58, aj naprieč jazykmi) → krok v recepte (zoznam `run_dups.py` + Sonnet nájde páry; embedding medzi jazykmi nestačí).
- **Skúška pestrosti (2026-10-14):** `variety-pilot-2026-10-14/`, `variety_brief.txt` = vkus + tvary (hádanka, fakt/výmysel, dokonči vetu, „čo sa stane, keď“) + zábavné témy. Slepo 21 pestrých vs 9 kontrolných z pilotu: https://claude.ai/artifact/2XP3studeaSAFfRGww4tLX
  - Výsledok: pestré en 4,6 · sk 5,2 · cs 5,9 vs kontrola ⌀ 7,6. **Hádanky = 1/10 (všetkých 7)**, founder: „detinský a primitívny formát, klišé nezmysel“ → nikdy. Bez hádaniek pestré ⌀ ~7,2 ≈ kontrola, žiadny zisk.
  - Poznámky: „fakt alebo výmysel“ je len pravda/nepravda, pomenovanie nič nepridáva; opakovane „nejasne položená otázka“; klišé floskuly („ktorú s radosťou praská každé dieťa“) vadia; ľahko predpovedateľné odpovede pravda/nepravda nudia; znalosť zo ZŠ (Bratislava) slabá.
  - Founder: zvyšovanie zábavnosti rieši session quiz-agent-43 → odovzdané.
- **Plný beh pripravený:** `general-corpus-2026-10-14/run_arm.sh`, 45 tém × 4 = 180/jazyk + 20 z pilotu; pokračuje po limite predplatného. Spustiť až po ⌀ ≥ 7: `GATEWAY=session ./run_arm.sh E en taste_brief.txt` (K sk, C cs).

### 203.8 Témy vymyslí model (founder 2026-10-14, do pilotu 203.7)

Founder: otázky sa „točia okolo niekoľkých tém“ a široký rozhľad modelov sa nevyužíva.
**Meranie prod zásoby (2026-10-14, 1 303 schválených en, sk/cs z 93 % preklady):** konkrétne témy sa neopakujú (297 rôznych, žiadna nad 1,2 %, najčastejší pojem Paríž 1,6 %). Opakujú sa okruhy a rámec: prírodné vedy + dejepis 50 %, „krajina“ v 11 % otázok, „slávny“ 82×, typ „priamy fakt“ 39 %, prevaha Európy a USA. 78 % zásoby je z jedného behu 10-01 (jeden model a zadanie, jeden „hlas“). Natívne sk/cs sú z ~50 % zábava.
**Príčina:** témy píše človek alebo školský zoznam kategórií a model každú vyplní najznámejšími faktami. Nič neťahá do šírky: dedup vyhodí len takmer rovnakú otázku, mapa podtém #170 (`COVERAGE_STEERING`) je vypnutá, len en a školská; pamäť „už pokryté“ má len týždenná zábava #202.

**Rameno M v pilote 203.7** (vedľa ručných tém H, rovnaké nastavenie podľa receptu):
1. Opus 5.5 navrhne ~150 úzkych tém na jazyk zo všetkých oblastí života (remeslá, povolania, predmety okolo nás, jazyk, telo, zvyky, technika, kuriozity…), nie školské predmety. Dostane zoznam tém, ktoré už v zásobe sú (pole `topic` z prod), a nechute z `taste_brief.txt`; tie vynechá.
   Founderove tipy (2026-10-14, príklady, nie úplný zoznam): techno a rave scéna, bežné činnosti, Red Bull a extrémne športy. Teda subkultúry, scény, záľuby a veci, ktoré ľudia naozaj robia, ktoré v zásobe chýbajú. „Nečakaná téma, ale nie úplne náhodný fakt“: téma prekvapí, otázka je o niečom, k čomu má človek vzťah.
2. Z návrhu sa náhodne vyberie, na tému **2 otázky** (nie 4), aby sa pilot rozložil na čo najviac tém.
3. Slepá vzorka 20 na jazyk = 10 H + 10 M zamiešané v jednom kole (stupnica sa medzi kolami posúva). Founder nehodnotí viac ako doteraz.
4. M vyhrá, ak jeho ⌀ ≥ H a ≥ 7 → plný beh 200/jazyk ide z tém od modelu. Pri remíze rozhodne founder.

Žiadny filter ani hodnotiteľ zábavy: mení sa len zdroj tém.

## Stav

- [x] 203.1 kontrola + beh nad zásobou
- [x] 203.2 slepé overenie founderom: kontrola nepredpovedá jeho hodnotenie, zásoba ~2/10
- [x] 203.5 pokles kvality: príčina = hromadný beh 10-01, nie zadanie
- [x] 203.6 zadanie podľa vkusu + recept `docs/setup/general-corpus-recipe.md`
- [~] 203.7 200 natívnych otázok na jazyk cez predplatné (pilot + slepá vzorka ≥ 7), potom founder rozhodne o archíve dávky 10-01
- [ ] 203.8 pilot porovná ručné témy (H) s témami od modelu (M); H = `general-pilot-2026-10-14` hotové
- [—] 203.3 / 203.4 archív a zapojenie kontroly otrepaných otázok: zrušené (kontrola nepredpovedá hodnotenie)
