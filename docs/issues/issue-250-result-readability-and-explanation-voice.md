# #250 — Výsledok otázky: prehľadnosť a vysvetlenie nahlas (TF 1.3 b93)

**Triage:** enhancement · in-progress
**Founder:** 2026-11-26, test TF 1.3 (93)
**Nadväzuje:** #248 — výsledok otázky a koniec kvízu (variant A), #243 — hlasová navigácia

## Problém (founder)

1. Výsledok stále neprehľadný: nie je jasné, čo je moja odpoveď a čo správna; váhy písma nesedia; veľa textu. Rešerš iných appiek, viac návrhov, jednoducho a čisto. Farbenie mojej odpovede na zeleno/červeno sa páči.
2. Zelená bodka dole na karte: čo to je, treba to?
3. Vysvetlenie chce počuť na výsledku štandardne; rýchly kvíz ho vypína. „Vypočuj si“ len keď sa nečíta samo; ťuk na text ostáva.

## Kroky

| # | Čo | Stav |
|---|----|------|
| 250.1 | Vysvetlenie nahlas po verdikte (nie v rýchlom kvíze, nie s vypnutým čítaním / bez zvuku); „vypočuj si“ len bez automatického čítania alebo po chybe | appka, PR (tento) |
| 250.2 | Rešerš + návrhy vzhľadu (A nadpis / B štítky / C otázka na karte) a otázka o bodke → stránka /decide | čaká founder |
| 250.3 | Vzhľad podľa rozhodnutia + bodka | [ ] |

## Rešerš (stručne)

Duolingo, Kahoot, Quizlet, Anki, HQ, rozbory na screensdesign.com: pri oboch odpovediach nápis („Tvoja“ / „Správna“), farba vždy s ikonou ✓/✕; výber z možností = celý zoznam s vyznačenou tvojou a správnou; vysvetlenie krátke a menšie, zdroj najtichší.

## Technický smer

- Bodka = testerský odznak „schválená otázka“ (len TestFlight/Debug).
- Vysvetlenie: rovnaká syntéza reči cez server ako „vypočuj si“, sťahuje sa počas verdiktu; odpočet na ďalšiu otázku čaká na koniec čítania; výpadok → poznámka + „vypočuj si“, výsledok ide ďalej.
