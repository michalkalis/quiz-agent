# #231 — Ukrajinčina ako štvrtý jazyk

**Triage:** enhancement · ready-for-agent
**Status:** 2026-11-18 hlas vybraný a nasadený (eleven_v3), písmo Manrope, pravidlá formulácií v štýle domu; skúška štýlu 11 otázok (zadarmo cez predplatné, `docs/testing/runs/uk-style-2026-11-18/`) čaká na rodeného hovorcu; predtým čakalo výber písma (founder) a posúdenie čítania (rodený hovorca) — [stránka](https://claude.ai/artifact/E9tRubgL2ZeVmhh9Z7hXyZ)
**Founder:** 2026-11-08 „pridaj ukrajinčinu do appky, na všetko, tak ako cz, sk a en“

## Cieľ

Ukrajinčina všade, kde je dnes sk/cs/en: appka, otázky, hlas (čítanie aj povely), hra spolu, web, App Store, nákupy.

**Hotovo, keď:** hráč s ukrajinčinou prejde celú appku po ukrajinsky (texty, otázky, čítanie, povely, odpovede hlasom aj 1–4), hra spolu v miestnosti aj na diaľku funguje s ukrajinským hostiteľom, ukrajinský App Store ukazuje ukrajinský popis, snímky a nákupy, web má /uk/, rodený hovorca schválil texty a vzorku otázok, App Store dostáva len schválené otázky.

## Rozhodnutia foundera (2026-11-08)

| Otázka | Voľba |
|---|---|
| Pre koho | **Hlavne Ukrajina** (ukrajinský App Store); Ukrajinci v SK/CZ ako bonus |
| Zdroj otázok | **Mix:** preklad univerzálnych schválených otázok + natívne ukrajinské od začiatku (domáca scéna = Ukrajina) |
| Overenie | **Rodený hovorca, ktorého founder pozná**: texty appky, App Store, web, právne texty, vzorka 50 otázok, test hlasu na mobile; AI kontrola vždy |
| Témy | **História, kultúra, šport áno; vojna od 2014, aktuálna politika a vzťahy s Ruskom nie** (ani ako hrdinské príbehy) |

## Čo už platí (overené 2026-11-08)

- **Rozpoznávanie reči:** Apple diktovanie (to, čo appka používa na povely) má `uk-UA` v zozname podporovaných jazykov (overené na Macu, macOS 27); nový Apple prepis nemá sk/cs ani uk, takže ide rovnaká cesta ako sk/cs. Na iPhone s iOS 26 treba overiť (231.0).
- **Server čítanie a prepis odpovedí:** ElevenLabs model je viacjazyčný a ukrajinčinu podporuje, jeden hlas pre všetky jazyky; prepis odpovedí dostáva kód jazyka. Kvalitu po ukrajinsky treba počuť (231.0).
- **Zoznam jazykov je na serveri** s vypínačom (servírované jazyky, jazyky balíkov) → uk môže ísť naostro až po zapnutí, bez buildu. Nová hodnota jazyka nie je zmena kontraktu pre staré buildy.
- **Hra spolu:** jazyk hry určuje hostiteľ pre všetkých; každý mobil na diaľku číta sám (#230). Nič nové okrem testu.
- **Písmo appky Rethink Sans nemá cyriliku vôbec** (ani v pôvodnom písme na Google Fonts). Bez zmeny by iOS ukrajinské písmená vykreslil iným písmom ako čísla a latinku → treba rozhodnúť (231.4). Kandidáti s cyrilikou a podobným vzhľadom: Onest, Manrope. Web používa to isté písmo.
- **Trh:** Ukrajina je samostatný App Store (jazyky ukrajinčina, angličtina, ruština). V SK ~150 tis., v CZ ~395 tis. Ukrajincov s dočasnou ochranou (Eurostat 07/2026, ochrana predĺžená do 03/2027).

## Rozsah práce (relatívne)

| Oblasť | Náročnosť | Poznámka |
|---|---|---|
| Server: jazyk, čísla, radové číslovky, slová pre možnosti 1–4, spätné hlášky, denná výzva (3 tvary množného čísla) | stredná | ~10 miest so zoznamom sk/cs/en |
| Otázky: preklad + natívne + brány kvality | **veľká** | najväčšia časť; cyrilika v kontrolách, ochrana pred ruštinou |
| Vlastné balíky (zadanie, štýl domu, domáca krajina) | stredná | |
| Appka: 731 textov, písmo, povely, odpovede v cyrilike, snímky | stredná až veľká | párovanie odpovedí je dnes len pre latinku |
| Web, App Store, nákupy, snímky obchodu | malá až stredná | prevažne mechanické + preklad |
| Overenie: rodený hovorca, testy, zariadenie | stredná | závisí od času hovorcu |

Spolu ~10 PR. Riziká v poradí: kvalita a množstvo natívnych otázok, rozpoznávanie povelov a možností 1–4 na zariadení, písmo.

## Úlohy

- [~] **231.0 Overenie rizík pred stavbou** (2026-11-17) — výsledky na nahrávkach z umelého hlasu (ElevenLabs, aktuálny hlas), [stránka na posúdenie](https://claude.ai/artifact/E9tRubgL2ZeVmhh9Z7hXyZ):
  - [x] (a) Apple diktovanie `uk-UA` na Macu (macOS 27, rovnaké nastavenie ako appka): **9/9 povelov** (старт, далі, повтори, пропусти, ще раз, добре, стоп, пауза, додому) aj možnosti один–чотири (prídu ako číslice 1–4). Model sa stiahol sám. Odpovede typu „Канберра“ diktovanie pokazí, ale odpovede prepisuje server. iPhone s iOS 26 a skutočný hlas → 231.11.
  - [x] (b) Čítanie aktuálnym hlasom (rodený hovorca, 2026-11-17): **2 z 5 zle** (1, 5), 2 dobre, 3 a 4 zlý dôraz/intonácia → aktuálny hlas na ukrajinčinu nestačí; ďalej kolo 2 s inými hlasmi a modelmi naslepo.
  - [x] Kolo 2 naslepo (2026-11-18): **hlas 5 = ten istý hlas na modeli eleven_v3 prečítal všetko na jednotku** → ukrajinčina (cyrilika) ide na eleven_v3, sk/cs/en ostávajú na v4 Turbo (PR #841, nasadené). v3 trvá ~3,5 s na otázku namiesto ~1,6 s. Chemické značky po „символ/позначка“ sa čítajú školsky (Fe → ферум).
  - [x] (c) Prepis odpovedí na serveri: produkčný model **9/9 bez chyby** (mená, čísla, veta, один–чотири); záložný Scribe 8/9 (Канберра → latinkou „Canberra“).
  - [x] (d) Písmo: **founder vybral B Manrope** (2026-11-17), len pre ukrajinčinu.
  - Formulácie otázok (rodený hovorca 11-17): ukážky 1 a 2 neprirodzené, kalky „Яке місто є столицею…“ → „Яка столиця…“, „Хто є автором збірки…“ → „Хто написав…“; 3 a 5 v poriadku. **Pilot 231.3 zatiaľ nie**, najprv pravidlá prirodzených formulácií a bezplatná skúška štýlu.
- [x] **231.1 Server základ (vypnutý)** (2026-11-17, PR #821, nasadené) — `uk` v zoznamoch jazykov, čísla, percentá, radové číslovky a roky („у тисяча дев'ятсот шістдесят дев'ятому році“), mesiace, možnosti 1–4, hláskovanie, spätné hlášky, denná výzva (3 tvary množného čísla), oznámenie v `/app-config`. Servírovanie uk vypnuté. Rodený hovorca v 231.10 overí: roky a dátumy, „Знав/Знали“, spätné hlášky.
- [x] **231.2 Otázky: brány kvality pre ukrajinčinu** (2026-11-17, PR #824) — odpovedateľnosť a prirodzenosť s uk, skloňovanie, kontrola ruských písmen a slov, slovník pojmov uk, pravidlo tém (vojna od 2014, politika, Rusko = vyradiť), domáca krajina Ukrajina, štýl domu uk s pravidlami prirodzených formulácií (spätná väzba 11-17). Týždenný beh uk NEspúšťa, len cez `--languages uk`.
- [ ] **231.3 Otázky: pilot** — 25 preložených univerzálnych + 25 natívnych ukrajinských (7/10 domáca scéna = Ukrajina, recept #211) → brány → vzorka 50 na posúdenie rodenému hovorcovi v jednej stránke. Odhad nákladov pred spustením (pilot do ~$5).
- [ ] **231.4 Otázky: plná dávka** — po schválení pilotu cieľ ~1 000+ schválených (aby kategórie nemali diery): preklad univerzálnych en otázok dávkou (rádovo jednotky dolárov) + natívne dávky (rádovo desiatky dolárov) → **suma na súhlas foundera vopred**; uk v týždennom dopĺňaní zábavy (#202). Len schválené do App Store.
- [ ] **231.5 Vlastné balíky po ukrajinsky** — názov jazyka, ochrana pred ruštinou, štýl domu uk, nadpisy; zdroje z ukrajinskej Wikipédie; overiť opätovné použitie balíka (#225) s jazykom uk.
- [ ] **231.6 Appka** — uk v projekte; 731 textov + 2 systémové; vybrané písmo pre cyriliku; povely po ukrajinsky (štart, ok, ďalej, znova, zopakuj, preskoč, stop, pauza, domov; výplňové slová так, ну, добре…), nápovedy a tlačidlá v rozkazovacom tvare; párovanie odpovedí 1–4 (MCQ sa číta číslami „Один… Чотири“ ako sk/cs, nie písmenami) a čísel v cyrilike (dnes len latinka bez diakritiky; pozor: й a ї sa nesmú zlúčiť s и a і); dátumy, mená hráčov, právne odkazy na /uk/; analytika jazyka existuje (overiť). Testy: zrkadlo sk/cs testov povelov, pixelové snímky uk.
- [ ] **231.7 Kontrola textov** — štýl textov pre uk (tykanie „ти“ ako sk/cs, právne texty „ви“, bez pomlčiek), automatická kontrola textov rozšírená o uk (ruské písmená, vykanie), plná kontrola iným modelom ako pri #226.
- [ ] **231.8 Web** — `/uk/` (texty, 3 právne stránky, tematické stránky s ukrajinskými adresami, ukážka hlasu), hreflang a mapa stránok sa doplnia samé.
- [ ] **231.9 App Store a nákupy** — ukrajinský popis, názov, podnadpis, kľúčové slová, What's New, snímky s ukrajinskými nadpismi, názvy nákupov a predplatného, TestFlight texty; dostupnosť v obchode Ukrajina a ceny (Apple prepočíta automaticky, **úprava ceny pre Ukrajinu = rozhodnutie foundera**). Nahrá sa s najbližšou verziou.
- [ ] **231.10 Overenie rodeným hovorcom** — jedna stránka: texty appky (podľa obrazoviek), App Store, web, právne, 50 otázok, ukážky hlasu; pripomienky → opravy.
- [ ] **231.11 Test celku** — simulátor: celý kvíz po ukrajinsky, prepnutie jazyka, vlastný balík, denná výzva; hra spolu: hostiteľ uk + hosť sk v miestnosti aj na diaľku; zariadenie (TestFlight na požiadanie): povely, odpovede hlasom a možnosti 1–4, hovorí rodený hovorca. Potom zapnúť uk na serveri.
- [ ] **231.12 Marketing (neskôr, samostatné rozhodnutie)** — ukrajinské sociálne siete, ASO pre ukrajinský obchod.

## Poradie a závislosti

231.0 → (231.1 ‖ 231.6 ‖ 231.8 ‖ 231.9) → 231.2 → 231.3 → 231.4 ‖ 231.5 → 231.7 → 231.10 → 231.11.
Jazyk ide naostro až po 231.11 vypínačom na serveri; dovtedy sú hotové časti skryté.

## Otvorené

- Cena predplatného a balíkov v ukrajinskom obchode (pri 231.9).
- Písmo pre cyriliku (pri 231.0 d, varianty na výber).
- Kto je rodený hovorca a koľko času mu môže founder vziať (pri 231.3).
