# #235 — Testy mimo bezproblémového priebehu (pomalá sieť, výpadky, prerušenia)

**Triage:** enhancement · ready-for-agent
**Status:** 2026-11-15 plán; dve chyby z buildu 87 opravené vopred (PR #798, PR #799); ďalej 235.1
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

Vyplní sa v 235.2.
