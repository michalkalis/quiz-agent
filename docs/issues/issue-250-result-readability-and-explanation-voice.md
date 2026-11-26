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
| 250.2 | Rešerš + návrhy vzhľadu (A nadpis / B štítky / C otázka na karte) a otázka o bodke → stránka /decide | hotové, rozhodnuté 2026-11-26 |
| 250.3 | Vzhľad A + bodka schválenej otázky na výsledku preč | appka, PR |

## Rozhodnutia (founder 2026-11-26)

1. **Variant A „tvoja odpoveď ako nadpis“:** malý verdikt hore; tvoja odpoveď najväčšia, zelená pri správnej, preškrtnutá červená pri nesprávnej; pod ňou „Správna odpoveď“ menším. Správna, ale inak vyslovená → pod ňou malým „presne: …“. Preskočená → správna odpoveď ako nadpis.
2. **Výber z možností** rovnako ako otvorená otázka (nie zoznam A–D).
3. **Bodka „schválené“** na výsledku preč; odznak ostáva len pri otázkach na kontrolu (s textom).

## Rešerš (stručne)

Duolingo, Kahoot, Quizlet, Anki, HQ, rozbory na screensdesign.com: pri oboch odpovediach nápis („Tvoja“ / „Správna“), farba vždy s ikonou ✓/✕; výber z možností = celý zoznam s vyznačenou tvojou a správnou; vysvetlenie krátke a menšie, zdroj najtichší.

## Technický smer

- Bodka = testerský odznak „schválená otázka“ (len TestFlight/Debug).
- Vysvetlenie: rovnaká syntéza reči cez server ako „vypočuj si“, sťahuje sa počas verdiktu; odpočet na ďalšiu otázku čaká na koniec čítania; výpadok → poznámka + „vypočuj si“, výsledok ide ďalej.
