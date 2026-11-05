# #228 — Vlastný balík: vždy plný + menší balík s 10 otázkami

**Triage:** enhancement · ready-for-agent
**Status:** 228.1 nasadené 2026-11-05 (PR #742); zvyšok čaká
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

> Výklad témy (11-05): „ak by boli len tieto konkrétne slová zadané (hrady a zámky), tak to neznamená hrady a zámky len na Slovensku za to, že je to slovenčina. ale primárne asi slovenské a môžu sa rozšíriť o zahraničné.“

> Kontrola odpovedateľnosti (11-05): „na toto mega pozor. určite by bolo lepšie použiť lepší model, lebo celkovo náklady na vygenerovanie sú drahé, takže lepšie by bolo, keby viac otázok prešlo.“

Kontroly kvality sa NEMENIA (pravidlo: kvalita otázok sa nesmie znížiť).

## Riešenie (v poradí, v akom sa uplatní)

### 1. Viac otázok od začiatku, prispôsobené úspešnosti
- Pre zákaznícke objednávky po prvom kole zmerať, aká časť otázok prešla kontrolami, a ďalšie kolo pýtať `chýbajúce / úspešnosť` (so stropom), nie pevný počet. Pri HP prešla ~polovica, pri hradoch menej.
- Viac kôl, kým nie je 30 (dnes rampa 1, 2, 4, 8 + 2 kolá navyše, `topup.py:62`), ohraničené **rozpočtom na objednávku** (`order_budget.py`, dnes strop 3× $4,23): navrhujem strop na jeden beh ~$6 a čas ~30 min, oboje v env.
- Prvá otázka ostáva hrateľná hneď (#182), korpusové generovanie sa nesmie zmeniť (test `test_corpus_cli_walk_is_untouched_by_the_ramp`).

### 2. Prehĺbenie v rámci zadania (nie mimo neho)
Keď úspešnosť klesne pod prah, ďalšie kolá dostanú nové uhly **vnútri zadania**: pri „hrady a legendy“ konkrétne hrady, postavy povestí, miesta, nie „slovenská história“ všeobecne. Model navrhne uhly, druhý krok ich overí otázkou „patrí to celé do zadania hráča?“ a čo nepatrí, zahodí.

**Jazyk nie je hranica témy:** všeobecné zadanie bez krajiny („hrady a zámky“) v slovenčine = hlavne slovenské, doplnené zahraničnými (približne dve tretiny domácich, zvyšok zo sveta). Ak zadanie krajinu alebo miesto menuje, platí presne to. Rovnako pre cs (české) a en (bez domácej preferencie).

### 3. Lepší model na kontrolu odpovedateľnosti (founder: „mega pozor“)
Dnes kontrolu robí lacný `deepseek-v4-flash`, ktorý úzke slovenské témy nepozná a zahodí aj dobré otázky. Zámer kontroly ostáva: zahodiť otázky, ktoré sú **nejasné** (viac správnych odpovedí, chýba kontext), nie tie, ktoré lacný model **nevie**.
- **Výmena za silnejší model** z inej rodiny ako generátor (generátor je Claude Opus 5.5; kontrolór z tej istej rodiny by mohol súhlasiť sám so sebou). Kandidáti: GPT, Gemini 3.1 Pro, DeepSeek V4 (nie flash), GLM-5. Pri ~45 kontrolách na balík je rozdiel v cene centy, zatiaľ čo zahodená otázka stojí ~$0,07 výroby.
- Doplnkovo: pri `wrong_answer` druhý krok, ktorý posúdi, či je odpoveď kontrolóra **iná platná odpoveď** (zahodiť) alebo **neznalosť** (ponechať).
- **Meranie pred výmenou:** súbor otázok so známym výsledkom: zahodené otázky z meraní 2026-11-04 (dobré, ktoré model nevedel) + otázky, ktoré sú naozaj nejasné (zo zahodených v korpuse). Nový model musí nechať prejsť viac dobrých a **nesmie** pustiť viac nejasných. Výsledok founderovi, výmena až potom.

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
- [x] 228.1 prispôsobené generovanie + rozpočet (1) + analytika — PR #742, nasadené 11-05. Naostro (prod nastavenie, sk): Harry Potter 30/30 (predtým 24), ~$3,00 bez hlasu, 26 min; slovenské hrady 30/30 (predtým 16, zlyhanie), ~$4,25 bez hlasu, 31 min. Úzka téma je drahšia, ako počítala ekonomika Max ($3,5 na balík) → prepočítať v 227.0. Výber 10 | 30 na obrazovke: variant B (#227).
- [ ] 228.2 prehĺbenie v rámci zadania (2)
- [ ] 228.3 lepší model na kontrolu odpovedateľnosti (3): porovnanie na zahodených otázkach z meraní (presnosť pri nejasných otázkach sa nesmie zhoršiť), potom výmena; founder smer schválil 11-05
- [ ] 228.4 doplnenie z knižnice + doplnenie dodatočne (4, 5)
- [ ] 228.5 otázky navyše do korpusu (6)
- [ ] 228.6 `pack_10`: meranie nákladu, ASC produkt, appka (7)
- [ ] 228.7 overenie: 5 tém (2 úzke, 2 bežné, 1 osobná) sk/cs/en → vždy 30, kvalita bez zmeny
