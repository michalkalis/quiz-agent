# #228 — Vlastný balík: vždy plný + menší balík s 10 otázkami

**Triage:** enhancement · ready-for-agent
**Status:** plán 2026-11-05; implementácia nezačatá
**Založené:** 2026-11-04 (founder)
**Súvisí:** #227 — Trubbo Max (závisí od tohto), #182 — custom pack hrateľný od prvej otázky (rampa dávok), #143 — Custom-pack COGS reduction, #225 — rovnaké zadanie = hotové otázky, #229 — kontrola vyhľadávania a duplicít

## Problém (meranie 2026-11-04, produkčné nastavenie, sk, 30 otázok)

| Zadanie | Výsledok | Náklad |
|---|---|---|
| „Harry Potter: knihy aj filmy“ | **24/30** po 8 kolách, ~20 min | ~$2,5 + hlas |
| „Slovenské hrady a legendy, ktoré sa o nich rozprávajú“ | **16/30 → zlyhalo** (pod 80 % = 24) | ~$2,4 bez výsledku |

Hráč, ktorý zaplatí za 30 otázok, dnes bežne dostane 24 a pri úzkej téme nič (vrátenie peňazí po až 3 pokusoch ≈ $7 nákladu). Prečo sa otázky zahadzujú (oba behy spolu):
- **27× veto „nudná a zároveň ťažko odpovedateľná“** (`answerability_surprise_veto`),
- **14× kontrola odpovedateľnosti:** lacný model naslepo odpovedal inak. Pri úzkej téme často preto, že **lacný model tému nepozná**, nie že je otázka nejasná: napr. Omarova studňa (správne Trenčín, model „Bojnice“), Stiborov sluha kopol psa (model „diviak“), požiar Krásnej Hôrky 2012 (model „cigaretový ohorok“ je vlastne blízko pravdy).

## Rozhodnutia foundera (2026-11-05)

> „vygenerovať viac otázok. dávajme radšej viac než menej, aby bola vcelku istota, že prejde tých 30 otázok aj po kontrole. ak ostanú otázky navyše, tak sa môžu dať do korpusu, ak téma nie je moc niche. rozšírenie témy je tiež ok, ale nemalo by to byť v rozpore s užívateľovým zadaním. doplnenie z knižnice tiež ok. len pozor na to, že užívateľ si platí veľa peňazí za custom otázky, takže by mali byť aj kvalitné.“

> Hráč sa o rozšírení ani doplnení nedozvie. „ideálne by sa fakt nemalo dopĺňať, jedine že by zhoda tém bola fakt vysoká.“

> Menší balík s 10 otázkami, „mierne nevýhodnejší“ než súčasný (€8,99 / 30).

Kontroly kvality sa NEMENIA (pravidlo: kvalita otázok sa nesmie znížiť).

## Riešenie (v poradí, v akom sa uplatní)

### 1. Viac otázok od začiatku, prispôsobené úspešnosti
- Pre zákaznícke objednávky po prvom kole zmerať, aká časť otázok prešla kontrolami, a ďalšie kolo pýtať `chýbajúce / úspešnosť` (so stropom), nie pevný počet. Pri HP prešla ~polovica, pri hradoch menej.
- Viac kôl, kým nie je 30 (dnes rampa 1, 2, 4, 8 + 2 kolá navyše, `topup.py:62`), ohraničené **rozpočtom na objednávku** (`order_budget.py`, dnes strop 3× $4,23): navrhujem strop na jeden beh ~$6 a čas ~30 min, oboje v env.
- Prvá otázka ostáva hrateľná hneď (#182), korpusové generovanie sa nesmie zmeniť (test `test_corpus_cli_walk_is_untouched_by_the_ramp`).

### 2. Prehĺbenie v rámci zadania (nie mimo neho)
Keď úspešnosť klesne pod prah, ďalšie kolá dostanú nové uhly **vnútri zadania**: pri „hrady a legendy“ konkrétne hrady, postavy povestí, miesta, nie „slovenská história“ všeobecne. Model navrhne uhly, druhý krok ich overí otázkou „patrí to celé do zadania hráča?“ a čo nepatrí, zahodí.

### 3. Druhý názor pri nesprávnej odpovedi lacného modelu (hypotéza, najprv meranie)
Pri `wrong_answer` nechať silnejší model posúdiť, či je odpoveď lacného modelu **iná platná odpoveď** (otázka je naozaj nejasná → zahodiť) alebo **len neznalosť** (otázka ostáva). Zámer kontroly sa tým nemení. Pred zapnutím: porovnanie na zahodených otázkach z oboch behov + founderov súhlas (zmena modelov len s dátami).

### 4. Doplnenie z knižnice len pri veľmi vysokej zhode
Posledná možnosť: chýbajúce miesta zo **schválených** otázok korpusu v tom istom jazyku, len ak je podobnosť nad vysokým prahom a model potvrdí „presne na zadanie“. Bez oznámenia hráčovi. Nie z otázok, ktoré hráč už hral.

### 5. Ak ani to nestačí
Balík s tým, čo prešlo (nie zlyhanie), a doplnenie na 30 dodatočne, keď ďalšie kolo prejde. Vrátenie peňazí len ak by balík mal pod ~10 otázok.

### 6. Otázky navyše do korpusu
Otázky, ktoré prešli všetkými kontrolami a nevošli do balíka, idú do korpusu ako **čakajúce na schválenie** (do App Store len schválené), ak:
- téma nie je úzka (model + podobnosť s existujúcimi kategóriami),
- zadanie nie je osobné (mená, rodina, firma, „môj“…), kvôli súkromiu nikdy,
- prejdú kontrolou duplicít korpusu.

### 7. Menší balík `pack_10`
- 10 otázok za **€3,49** (€0,35/otázka vs €0,30 pri 30), „mierne nevýhodnejší“. Príjem ~€2,41; náklad odhad ~$1,3–1,6 (zmerať 1 behom pred spustením).
- Server už 10-otázkový balík pozná (`orders.py:91`, `reconcile.py:54`); treba ASC produkt, StoreKit config a výber veľkosti v appke.

## Analytika (v tých istých PR)
Na objednávke: počet kôl, úspešnosť za kolo, počet z prehĺbenia / z knižnice / navyše do korpusu, náklad. Udalosť `pack_size_selected`.

## Testy (prečo)
- Pri nízkej úspešnosti ďalšie kolo pýta viac otázok (inak hráč dostane menej, než zaplatil).
- Prehĺbenie nevyjde mimo zadania (hráč platí za svoju tému).
- Doplnenie z knižnice len nad prahom zhody; inak radšej menej (founder: „ideálne by sa nemalo dopĺňať“).
- Osobné zadanie nikdy nejde do korpusu (súkromie).
- Rozpočet na objednávku zastaví beh (nekonečné kolá by boli strata).
- Korpusové generovanie nezmenené.

## Úlohy
- [ ] 228.1 prispôsobené generovanie + rozpočet (1) + analytika
- [ ] 228.2 prehĺbenie v rámci zadania (2)
- [ ] 228.3 meranie druhého názoru na zahodených otázkach (3) → founder rozhodne
- [ ] 228.4 doplnenie z knižnice + doplnenie dodatočne (4, 5)
- [ ] 228.5 otázky navyše do korpusu (6)
- [ ] 228.6 `pack_10`: meranie nákladu, ASC produkt, appka (7)
- [ ] 228.7 overenie: 5 tém (2 úzke, 2 bežné, 1 osobná) sk/cs/en → vždy 30, kvalita bez zmeny
