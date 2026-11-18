# #231 — Ukrajinčina ako štvrtý jazyk

**Triage:** enhancement · ready-for-agent
**Status:** 2026-11-18 overenie hotové (hlas, písmo, štýl otázok); stavba vo vlnách nižšie, kontrola priamo v appke cez TestFlight — [stránka](https://claude.ai/artifact/E9tRubgL2ZeVmhh9Z7hXyZ)
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

- [x] **231.0 Overenie rizík** (2026-11-17/18, [stránka](https://claude.ai/artifact/E9tRubgL2ZeVmhh9Z7hXyZ)) — Apple diktovanie `uk-UA` 9/9 povelov a один–чотири (Mac; iPhone v 231.11); prepis odpovedí na serveri 9/9; písmo **Manrope** (len uk); hlas: rodený hovorca naslepo vybral **ten istý hlas na eleven_v3** (PR #841), pri stabilite 1.0 znie rovnako pri každej otázke (kolo 4, PR #855); Fe → „ферум“. Formulácie: kalky „є столицею“, „є автором“, dramatické výpočty detailov, nepresná udalosť → pravidlá v štýle domu uk (PR #824, #852); skúška štýlu 11 natívnych otázok zadarmo cez predplatné (`docs/testing/runs/uk-style-2026-11-18/`) dobrá. Známe obmedzenie: ojedinelý zlý prízvuk (му́тні); knižnica na prízvuky ho tiež netrafí → riešiť zoznamom opráv až podľa nálezov v appke.
- [x] **231.1 Server základ (vypnutý)** (2026-11-17, PR #821, nasadené) — `uk` v zoznamoch jazykov, čísla, percentá, radové číslovky a roky („у тисяча дев'ятсот шістдесят дев'ятому році“), mesiace, možnosti 1–4, hláskovanie, spätné hlášky, denná výzva (3 tvary množného čísla), oznámenie v `/app-config`. Servírovanie uk vypnuté. Rodený hovorca v 231.10 overí: roky a dátumy, „Знав/Знали“, spätné hlášky.
- [x] **231.2 Otázky: brány kvality pre ukrajinčinu** (2026-11-17, PR #824) — odpovedateľnosť a prirodzenosť s uk, skloňovanie, kontrola ruských písmen a slov, slovník pojmov uk, pravidlo tém (vojna od 2014, politika, Rusko = vyradiť), domáca krajina Ukrajina, štýl domu uk s pravidlami prirodzených formulácií (spätná väzba 11-17). Týždenný beh uk NEspúšťa, len cez `--languages uk`.
- [—] **231.3 Pilot** — zrušené (founder 2026-11-18: ďalej neiterovať ukážky, kvalita sa skontroluje priamo v appke).
- [ ] **231.4 Otázky: dávka** — natívne ukrajinské otázky na predplatnom (zadarmo, `generate_pack --dry-run`, recept zo skúšky štýlu), 2 na tému, témy polovica ručne a polovica od modelu; cieľ ~600 cez všetky kategórie, 7/10 Ukrajina; duplicity v dávke preč (`run_dups.py`); import so strojovým schválením cez brány. Preklad univerzálnych en otázok len ak natívne nepokryjú kategórie (najprv uk podpora v prekladovom nástroji). Potom uk v týždennom dopĺňaní zábavy (#202) so súhlasom foundera na sumu.
- [ ] **231.5 Vlastné balíky po ukrajinsky** — názov jazyka, ochrana pred ruštinou, štýl domu uk, nadpisy; zdroje z ukrajinskej Wikipédie; overiť opätovné použitie balíka (#225) s jazykom uk.
- [ ] **231.6 Appka** — uk v projekte; 731 textov + 2 systémové; vybrané písmo pre cyriliku; povely po ukrajinsky (štart, ok, ďalej, znova, zopakuj, preskoč, stop, pauza, domov; výplňové slová так, ну, добре…), nápovedy a tlačidlá v rozkazovacom tvare; párovanie odpovedí 1–4 (MCQ sa číta číslami „Один… Чотири“ ako sk/cs, nie písmenami) a čísel v cyrilike (dnes len latinka bez diakritiky; pozor: й a ї sa nesmú zlúčiť s и a і); dátumy, mená hráčov, právne odkazy na /uk/; analytika jazyka existuje (overiť). Testy: zrkadlo sk/cs testov povelov, pixelové snímky uk.
- [ ] **231.7 Kontrola textov** — štýl textov pre uk (tykanie „ти“ ako sk/cs, právne texty „ви“, bez pomlčiek), automatická kontrola textov rozšírená o uk (ruské písmená, vykanie), plná kontrola iným modelom ako pri #226.
- [ ] **231.8 Web** — `/uk/` (texty, 3 právne stránky, tematické stránky s ukrajinskými adresami, ukážka hlasu), hreflang a mapa stránok sa doplnia samé.
- [ ] **231.9 App Store a nákupy** — ukrajinský popis, názov, podnadpis, kľúčové slová, What's New, snímky s ukrajinskými nadpismi, názvy nákupov a predplatného, TestFlight texty; dostupnosť v obchode Ukrajina a ceny (Apple prepočíta automaticky, **úprava ceny pre Ukrajinu = rozhodnutie foundera**). Nahrá sa s najbližšou verziou.
- [ ] **231.10 Overenie rodeným hovorcom** — jedna stránka: texty appky (podľa obrazoviek), App Store, web, právne, 50 otázok, ukážky hlasu; pripomienky → opravy.
- [ ] **231.11 Test celku** — simulátor: celý kvíz po ukrajinsky, prepnutie jazyka, vlastný balík, denná výzva; hra spolu: hostiteľ uk + hosť sk v miestnosti aj na diaľku; zariadenie (TestFlight na požiadanie): povely, odpovede hlasom a možnosti 1–4, hovorí rodený hovorca. Potom zapnúť uk na serveri.
- [ ] **231.12 Marketing (neskôr, samostatné rozhodnutie)** — ukrajinské sociálne siete, ASO pre ukrajinský obchod.

## Poradie (od 2026-11-18)

Founder 2026-11-18: ukážky už neiterovať, stavať všetko a skontrolovať priamo v appke.

1. **Vlna 1 súbežne:** 231.6 appka (najväčšia, jeden iOS worker s vlastným simulátorom) ‖ 231.7 + 231.8 + 231.9 texty, web, App Store (worker bez iOS) ‖ 231.4 dávka otázok na predplatnom (beží na pozadí).
2. **Vlna 2:** 231.5 vlastné balíky; server ukazuje uk len buildom, ktoré ju poznajú (staré buildy nesmú vidieť jazyk bez textov), plus TestFlight.
3. **Kontrola v appke:** TestFlight build na požiadanie foundera → founder a rodený hovorca prejdú appku (231.10 + 231.11), opravy podľa nálezov.
4. **Zapnutie:** uk naostro vypínačom na serveri + App Store texty s najbližšou verziou.

## Otvorené

- Cena predplatného a balíkov v ukrajinskom obchode (pri 231.9).
- Kto je rodený hovorca a koľko času mu môže founder vziať (pri 231.3).
