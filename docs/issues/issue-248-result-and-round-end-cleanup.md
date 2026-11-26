# #248 — Výsledok otázky a koniec kvízu: upratať (TF 1.3 b92)

**Triage:** enhancement · in-progress (kód hotový 2026-11-26, čaká TF build a rozhodnutie o odmene)
**Founder:** 2026-11-25, test TF 1.3 (92) + rozhodnutia na stránke /decide (session quiz-agent-85)
**Nadväzuje:** #243 — hlasová navigácia (decisions 2026-11-24), #205 — denná výzva

## Problém (founder)

- Výsledok otázky je preplnený, prvky spolu nesúvisia: kategória, „Vedľa“ v rohu, „SPRÁVNA ODPOVEĎ“, preškrtnutá „tvoja odpoveď“, „Prvý výsledok dňa.“.
- Po dočítaní otázky dlhá pauza pred „Premýšľaj“, a hlasová výzva po každej otázke otravuje.
- Koniec kvízu: hlas povie skóre a „Znova, alebo domov?“, čo nedáva zmysel; chýba tlačidlo na ďalší kvíz (po dennej výzve „znova“ nedáva zmysel).

## Rozhodnutia (founder 2026-11-25, doslovne skrátené)

1. **Výsledok otázky = variant A „verdikt ako nadpis“**, s textami:
   - verdikt „Nesprávne“ (namiesto „Vedľa“); pri správnej odpovedi „Správne“ (agent: symetria, founder to nemenil výslovne).
   - nad veľkou odpoveďou „Správna odpoveď“.
   - pod ňou „Tvoja odpoveď“: zlá → preškrtnutá; správna, ale inak napísaná → nepreškrtnutá; správna a rovnaká → riadok sa nezobrazí.
   - kategória preč; „Zobraz otázku“ + „zdroj“ v tichom riadku dole.
2. **Štatistiky / gamifikácia** ukazovať až pri dostatku odpovedí a hráčov; „Prvý výsledok dňa.“ nikdy (vyzerá, že appku nikto nepoužíva). Celú gamifikáciu treba premyslieť neskôr (248.6).
3. **Výzva na premýšľanie:** „Premýšľaj, máš 10 sekúnd.“ po prvej otázke, „Premýšľaj.“ po ďalších; „Odpovedaj.“ vždy pred automatickým zapnutím mikrofónu, nie keď hráč sám ťukne na Odpovedaj alebo povie povel.
4. **Koniec kvízu = variant B „Minimum“:** skóre ako nadpis, dlaždice, jeden riadok odmeny, „Ďalší kvíz“ hlavné tlačidlo, „Úvod“ vedľajšie, zdieľanie ako ikona v hornej lište na mieste podľa HIG.
5. **Hlas na konci:** „Máš správne 1 z 5 odpovedí.“ (nie len „1 z 5“; rodovo neutrálne), odmena „Za odmenu máš dnes 10 otázok navyše.“, ponuka „Chceš hrať ďalší kvíz? Povedz: ďalší. Alebo otvoriť úvodnú obrazovku? Povedz: domov.“ Povel **„ďalší“** (nie „ďalší kvíz“, nie „znova“).
6. **„Ďalší kvíz“** = hneď ďalší kvíz s rovnakým nastavením (po dennej výzve posledný bežný kvíz).

Otvorené (founder): kedy a koľko odmeny za dennú výzvu (aj pri zlom skóre? 4–5 správnych → 5 / 10 otázok?), „zistiť, ako to robia iné appky“ → 248.5 (rešerš odmien).

## Kroky

| # | Čo | Kde | Stav |
|---|----|-----|------|
| 248.0 | Pauza pred „Premýšľaj“: výzva hneď po otázke, mikrofón na povely až po nej | appka | hotové, PR #985 (pauza pred „Premýšľaj“) |
| 248.1 | Hlas: dlhá výzva len pri 1. otázke; „Odpovedaj.“ len pred automatickým mikrofónom; veta na konci + povel „ďalší“ (sk/cs/en/uk) | appka | hotové, PR #990 (hlasové vety a povel „ďalší“) |
| 248.2 | Výsledok otázky podľa A (texty vyššie, bez kategórie, bez štatistík) + hlasová veta „Nesprávne. Správna odpoveď: …“ | appka | hotové, PR #989 (výsledok otázky) |
| 248.3 | Koniec kvízu podľa B: denná výzva aj bežný kvíz; „Ďalší kvíz“, zdieľanie v hornej lište | appka | hotové, PR #991 (koniec kvízu; týždenná tabuľka kamarátov ostáva, len pozvánka preč) |
| 248.4 | Server: porovnanie s ostatnými len pri dostatku hráčov, nikdy „Prvý výsledok dňa.“ | server | hotové, PR #987 (prah 20 hráčov), v produkcii 2026-11-25 |
| 248.5 | Rešerš: odmeny za dennú výzvu podľa skóre v iných appkách → návrh foundrovi | rešerš | rešerš hotová (odporúčanie: základ 10 + bonus 5 za 4–5 správnych), čaká rozhodnutie foundera |
| 248.6 | Gamifikácia ako celok premyslieť (štatistiky, porovnania, kedy ich ukázať) | neskôr | [ ] |

## Technický smer (stručne)

- **248.0:** po dočítaní otázky sa poslucháč povelov nezapína, keď hneď nasleduje výzva; zapne ho výzva po sebe. Ak výzva nezaznie (stlmené), zapne ho okno premýšľania.
- **248.1:** vety konca kvízu skladá appka (hlas cez server TTS ako doteraz); povel na konci = existujúci povel „next“ s tvarom „ďalší“ / „další“ / „next“ / uk; návrh „Ďalší kvíz“ spúšťa to isté ako dnes „znova“ (denná výzva → bežný kvíz, inak nové kolo s rovnakým nastavením).
- **248.4:** prah na serveri (agent: aspoň 20 iných hráčov danej otázky / dňa), pod ním server porovnanie nepošle; staré buildy pole už dnes berú ako voliteľné → bez zmeny API tvaru.
- Starý build (TF b92, App Store 1.2) ostáva funkčný: mení sa len text a to, kedy server pošle voliteľné pole.

**Rešerš 248.5:** [daily-reward-by-score-2026-11-25.md](../research/daily-reward-by-score-2026-11-25.md)

## Overenie

- Každá zmena: test, ktorý bez nej zlyhá; snímky obrazoviek prenahrané zámerne (sk/cs/en/uk).
- Na konci: TestFlight build na požiadanie foundera, test v aute.
