# #235 — Testy mimo bezproblémového priebehu (pomalá sieť, výpadky, prerušenia)

**Triage:** enhancement · ready-for-agent
**Status:** 2026-11-15 hotové 235.1 (prepínač zlej siete v testoch, PR #802) a 235.3 (navigácia ako pravidlo: náhodné sledy overujú, že hráč má vždy cestu von; bez opravy z PR #799 chybu nájdu sami); ďalej 235.2 (tabuľka tok × podmienka); dve chyby z buildu 87 opravené vopred (PR #798 pád pri prvom spustení, PR #799 zmiznutá spodná lišta)
**Founder:** 2026-11-15 „aby neboli testy len na happy paths, ale zahrnovali aj edge cases, pomalé pripojenie a podobne“

## Prečo

Founder na TestFlight builde 87 (Trubbo Beta) našiel dve chyby, ktoré žiadny test nezachytil:

| Chyba | Prečo ju testy nevideli | Oprava |
|---|---|---|
| Pád pri prvom spustení po inštalácii (kontrola schránky na odkaz kvízu) | každý test nahradil volanie systému atrapou, skutočné volanie nikdy nebežalo | PR #798 |
| Pri pomalom štarte kvízu a prepnutí na Spolu zmizla spodná lišta, appku bolo treba zabiť | žiadny test nedrží požiadavku rozpracovanú, kým hráč robí niečo iné | PR #799 |

Obe sú ukážkou toho istého: testov je veľa (appka ~2 000, server ~2 900), ale merajú hlavne priebeh, keď všetko odpovie hneď a správne.

## Stav dnes (prieskum 2026-11-15)

Dobré:
- logika kvízu v appke: opakovanie, vypršanie času, súbehy pri odpovedi, hovor počas nahrávania, náhodné sledy udalostí (`HangsTests/QuizSequence/`);
- server: výpadky poskytovateľov (AI, hlas), opakované požiadavky, nákupy a overenie platieb.

Diery:
1. Testy celých obrazoviek (33 regresných scenárov) bežia proti atrape servera, ktorá odpovie okamžite a nikdy nezlyhá. Medzistavy (načítava sa, čaká sa) nie sú pozorovateľné.
2. Atrapa siete v testoch logiky vie vrátiť chybu, ale nie oneskorenie, výpadok uprostred ani neúplnú odpoveď (`HangsTests/Support/StubURLProtocol.swift`). Podržať požiadavku vedia len 4 volania (`MockNetworkService`), štart kvízu medzi nimi nie je.
3. Miesta, kde appka chybu potichu zahodí: načítanie pri štarte (`AppState.swift:245,268`), porovnanie pri zdieľanom kvíze (`QuizViewModel+SharedQuiz.swift:32`), odchod z hry spolu (`RoomViewModel.swift:300-317`), hovorené výzvy (`QuizViewModel+SpokenPrompts.swift:54,130`).
4. Mimo kvízu takmer nič pre zlé podmienky: Home, Spolu, zdieľaný kvíz, Profil, nákupy na úrovni obrazovky.
5. Volania systému (schránka, mikrofón, obchod) sú v testoch skoro vždy nahradené; skutočná cesta beží prvýkrát až na telefóne.
6. Server: spojenie prerušené uprostred hlasovej odpovede, skutočne súbežné akcie v hre spolu, vypršanie rozohranej hry, pomalý (nie spadnutý) poskytovateľ hlasu. Testy `packages/shared` v CI nebežia.

## Pravidlo, ktoré testy strážia

V každom toku a pri každej zlej podmienke hráč vidí buď, že sa niečo deje, alebo zrozumiteľnú chybu s cestou von. Nikdy:
- nekonečné čakanie bez možnosti odísť,
- obrazovka bez navigácie,
- tiché nič (akcia sa nestala a appka mlčí),
- dvojité strhnutie platby alebo kvóty.

## Riešenie

### 235.1 — Zlá sieť ako prepínač v testoch (základ)
- Atrapa siete dostane profily: pomalé, veľmi pomalé (vyprší čas), bez pripojenia, výpadok uprostred, chyba servera, poškodená odpoveď.
- V testoch logiky bez skutočného čakania (cez vložené hodiny, ktoré už testy používajú) a s možnosťou podržať ľubovoľné volanie, nielen dnešné 4.
- V testoch obrazoviek cez spúšťací parameter, aby regresné scenáre vedeli bežať proti pomalému alebo padajúcemu serveru.
- Hotové, keď: test z PR #799 ide prepísať bez ručného zásahu do atrapy a jeden regresný scenár beží v profile „pomalé“.

### 235.2 — Tabuľka tok × podmienka (testy logiky)
Toky: štart appky a Home · spustenie kvízu · odpoveď (hlas, text, výber) · čítanie nahlas · nákup a obnova · balík na mieru · hra spolu · zdieľaný odkaz · denná výzva · Profil.
Podmienky: profily z 235.1 + hráč medzitým odíde (iná záložka, späť, pozadie) + odpoveď príde po odchode.
- Každá bunka má test alebo zapísaný dôvod, prečo nie je potrebná.
- Tiché zahodenie chyby z bodu 3 sa pri tom opraví alebo vedome ponechá s dôvodom; viditeľná zmena pre hráča ide cez foundera.
- Hotové, keď: tabuľka je v tomto súbore vyplnená a žiadna bunka nie je prázdna.

### 235.3 — Navigácia ako pravidlo
- Test, ktorý pre náhodné sledy (ťuknutia na záložky, štart, zrušenie, chyba, pozadie) overuje: vždy je viditeľná lišta alebo tlačidlo späť či zavrieť. Rozšírenie existujúceho `QuizSequence` o záložky a hru spolu.
- Hotové, keď: test bez opravy z PR #799 chybu sám nájde.

### 235.4 — Skutočné volania systému aspoň raz
- Zoznam volaní, ktoré testy vždy nahrádzajú (schránka, zdieľanie, oprávnenia, obchod, zvuk), a ku každému jeden test so skutočným volaním na simulátore, ak to simulátor dovolí.
- Hotové, keď: zoznam je v súbore a každé volanie má test alebo poznámku „len na zariadení“.

### 235.5 — Regresné scenáre pre zlé podmienky
Asi 8 nových scenárov (čísla RS pridelí `docs/testing/regression-scenarios.md`): pomalý štart appky · výpadok počas odpovede · pomalý štart kvízu a prepnutie záložky · zlyhaný nákup · zrušený nákup · hostiteľ stratí sieť v hre spolu · hosť sa vráti z pozadia · zdieľaný odkaz počas rozohraného kvízu.

### 235.6 — Server
- Spojenie prerušené uprostred hlasovej odpovede a čítania: hra ostane konzistentná, nič sa nezapočíta dvakrát.
- Súbežné akcie v hre spolu naozaj naraz (dvaja hostia sa pripoja, dvaja odpovedia).
- Vypršanie rozohranej hry a pokračovanie po nasadení servera.
- Pomalý poskytovateľ hlasu sa zmestí do časového limitu odpovede.
- Automatické skúšanie nezmyselných vstupov proti popisu API.
- `packages/shared` testy do CI.

### 235.7 — Pravidlo do procesu
- Každá chyba z testovania: najprv test, ktorý ju zachytí, potom oprava (už platí ako Rule #2, tu sa vynucuje v kontrole PR).
- Nová funkcia so sieťovým volaním musí mať test pre pomalú sieť a chybu; pokyn pre nezávislú kontrolu PR.

## Poradie a závislosti

235.1 → (235.2, 235.3, 235.5 závisia od neho) · 235.4, 235.6, 235.7 sú nezávislé a môžu ísť súbežne. Každý bod je samostatný PR.

## Riziká

- **Čas CI:** kontrola appky dnes trvá 42 až 60 minút. Väčšina nových testov ide na úroveň logiky (sekundy); scenáre z 235.5 pridajú odhadom 5 až 8 minút. Ak to prekročí únosnú mieru, zlé podmienky pobežia ako samostatná úloha len pri zmenách appky.
- **Nestabilné testy:** žiadne skutočné čakanie, len vložené hodiny a podržané volania; test s pevným časom čakania sa neprijíma.
- **Čo simulátor nezachytí:** skutočný slabý signál, auto cez Bluetooth, reálny hovor. Ostáva krátky ručný zoznam pred vydaním (súčasť 235.5).

## Tabuľka pokrytia

235.2, prvá polovica (2026-11-17). ✓ = existujúci test, ✓✓ = nový test (súbory `HangsTests/*ConditionTests.swift`), n-a = netreba (dôvod), F = čaká na foundera (zoznam nižšie).

| Tok | Pomalé | Vyprší čas | Bez siete | Výpadok uprostred | Chyba servera | Poškodená odpoveď | Hráč odíde | Odpoveď po odchode |
|---|---|---|---|---|---|---|---|---|
| Štart appky a Home | ✓✓ prepínače, kvóta nečaká na nákupy | ✓✓ kvóta končí na Skúsiť znova | ✓✓ · F1 | ✓✓ | ✓✓ | ✓✓ | ✓ balíky (`MyPacksViewModelTests`) | n-a: údaje celej appky, neskorá odpoveď len obnoví |
| Spustenie kvízu | ✓ `SlowQuizStartTabTests` | ✓✓ jeden pokus, chyba po 30 s | ✓✓ opakuje do 24 s, potom chyba | ✓✓ tá istá relácia | ✓ `QuizViewModelTests` | ✓✓ hneď chyba | ✓ Zrušiť, záložka, pozadie (`NavigationSequenceTests`) | ✓ `SlowQuizStartTabTests` |
| Odpoveď (hlas, text, výber, preskočiť) | ✓ `SubmissionStallTests` | ✓ `SubmissionStallTests`, `MCQSubmitInterruptTests` | ✓ `SubmitRetryTests` | ✓✓ rovnaká otázka, žiadne dvojité strhnutie | ✓ `QuizViewModelTests`, `QuizSequence` | ✓✓ chyba so Skúsiť znova, poslané raz | ✓ pozadie (`SubmissionStallTests`) | ✓✓ ostane Home, nový štart neprevezme chybu |
| Čítanie nahlas | ✓✓ otázka sa číta, dá sa odpovedať | ✓✓ veta pri chybe max 3 s · F2 | ✓✓ · F2 F3 | n-a: tá istá vetva ako bez siete | ✓✓ | ✓✓ (prehrávanie: ✓ `QuizViewModelTTSSpyTests`) | ✓✓ Home pred vetou o skóre | ✓✓ oprava: neskorý zvuk otázky už nehrá |
| Denná výzva | ✓✓ karta ponúka hru | ✓ `DailyChallengeViewModelTests` | ✓ `DailyChallengeViewModelTests` | n-a: rozohratú výzvu server vráti (`DailyChallengeViewModelTests`) | ✓ `QuizViewModelDailyChallengeTests` | n-a: tá istá vetva ako chyba | ✓ `QuizViewModelDailyChallengeTests` | ✓✓ starý jazyk neprepíše kartu |
| Profil (štatistiky, prehľad, Moje balíky) | ✓✓ načítava sa, potom karty | ✓ jedna vetva pre všetky chyby (`ProfileViewModelTests`, `MyPacksViewModelTests`) | ✓ | ✓ | ✓ | ✓ | ✓ `MyPacksViewModelTests` · F4 | ✓✓ karty starého účtu sa neukážu |

Spolu 48 buniek: 20 ✓, 24 ✓✓, 4 n-a. Hodnotenie a nahlásenie otázky (`QuizViewModel.rateQuestion`/`flagQuestion`) nevolá žiadna obrazovka; hodnotiaci panel chybu ukáže (`QuestionRatingViewModelTests`).

Druhá polovica (nákup a obnova, balík na mieru, hra spolu, zdieľaný odkaz): _doplní 235.2 druhá polovica._

**Opravené:** keď hráč počas sťahovania zvuku otázky ťukol na nahrávanie, vybral možnosť alebo stlmil, zvuk po príchode aj tak prečítal otázku (do mikrofónu alebo cez výsledok).

### Na rozhodnutie foundera

- **F1 Overenie nákupov po prihlásení zlyhá potichu** (`AppState.swift:245`). Hráč nevidí nič; nákup sa ukáže pri ďalšom návrate do appky. Možnosti: nechať tak · krátka poznámka v Nastaveniach „Nákup overíme znova“.
- **F2 Hovorená veta (chyba, kvóta, skóre) sa pri zlyhaní hlasovej služby vynechá** (`QuizViewModel+SpokenPrompts.swift`). Obrazovka s tlačidlami a hlasové povely ostanú, len je ticho. Možnosti: nechať tak · prehrať krátku vetu uloženú v appke.
- **F3 „Vypočuť“ (vysvetlenie, zhrnutie sady) pri zlyhaní neurobí nič a nič nepovie.** Možnosti: nechať tak · krátky text „Teraz sa to nedá prečítať“.
- **F4 Zobrazenie prehľadu sa serveru nepošle, ak zlyhá** (`markRecapSeen`). Hráčovi sa prehľad pri ďalšom spustení môže ukázať znova ako nový. Možnosti: nechať tak · poslať znova pri ďalšom otvorení Profilu.
