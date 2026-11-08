# #231 — Ukrajinčina ako štvrtý jazyk

**Triage:** enhancement · ready-for-agent
**Status:** plán hotový 2026-11-08, rozhodnutia foundera nižšie; ďalej 231.0 overenie rizík
**Founder:** 2026-11-08 „pridaj ukrajinčinu do appky, na všetko, tak ako cz, sk a en“

## Cieľ

Ukrajinčina všade, kde je dnes sk/cs/en: appka, otázky, hlas (čítanie aj povely), hra spolu, web, App Store, nákupy.

**Hotovo, keď:** hráč s ukrajinčinou prejde celú appku po ukrajinsky (texty, otázky, čítanie, povely, odpovede hlasom aj A–Г), hra spolu v miestnosti aj na diaľku funguje s ukrajinským hostiteľom, ukrajinský App Store ukazuje ukrajinský popis, snímky a nákupy, web má /uk/, rodený hovorca schválil texty a vzorku otázok, App Store dostáva len schválené otázky.

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
- **Písmo appky Rethink Sans nemá cyriliku vôbec** (ani v pôvodnom písme na Google Fonts). Bez zmeny by iOS ukrajinské písmená vykreslil iným písmom ako čísla a latinku → treba rozhodnúť (231.4). Kandidáti s cyrilikou a podobným vzhľadom: Onest (navrhnuté na Ukrajine), Manrope. Web používa to isté písmo.
- **Trh:** Ukrajina je samostatný App Store (jazyky ukrajinčina, angličtina, ruština). V SK ~150 tis., v CZ ~395 tis. Ukrajincov s dočasnou ochranou (Eurostat 07/2026, ochrana predĺžená do 03/2027).

## Rozsah práce (relatívne)

| Oblasť | Náročnosť | Poznámka |
|---|---|---|
| Server: jazyk, čísla, radové číslovky, písmená A–Г, spätné hlášky, denná výzva (3 tvary množného čísla) | stredná | ~10 miest so zoznamom sk/cs/en |
| Otázky: preklad + natívne + brány kvality | **veľká** | najväčšia časť; cyrilika v kontrolách, ochrana pred ruštinou |
| Vlastné balíky (zadanie, štýl domu, domáca krajina) | stredná | |
| Appka: 731 textov, písmo, povely, odpovede v cyrilike, snímky | stredná až veľká | párovanie odpovedí je dnes len pre latinku |
| Web, App Store, nákupy, snímky obchodu | malá až stredná | prevažne mechanické + preklad |
| Overenie: rodený hovorca, testy, zariadenie | stredná | závisí od času hovorcu |

Spolu ~10 PR. Riziká v poradí: kvalita a množstvo natívnych otázok, rozpoznávanie povelov a písmen A–Г na zariadení, písmo.

## Úlohy

- [ ] **231.0 Overenie rizík pred stavbou** — (a) iPhone iOS 26: diktovanie `uk-UA` dostupné a model sa stiahne; (b) ukážky čítania 5 ukrajinských otázok (aktuálny hlas) → artefakt pre rodeného hovorcu; (c) prepis odpovedí po ukrajinsky cez existujúci porovnávací skript na nahrávkach (bez prehrávania nahlas na Macu); (d) písmo: 2–3 varianty ukrajinských obrazoviek v HTML → founder vyberie. Výsledok: ide/nejde + čo zmeniť.
- [ ] **231.1 Server základ (vypnutý)** — `uk` v spoločnom zozname jazykov a vo všetkých zoznamoch povolených jazykov; čísla, percentá, radové číslovky, mesiace; názvy písmen pre odpovede (A Б В Г, vyslovené „а, бе, ве, ге“, aj „перший/другий…“); spätné hlášky a texty dennej výzvy s tromi tvarmi množného čísla; oznámenie v `/app-config` s uk poľom. Servírovanie uk zostáva vypnuté. Testy pre každé miesto.
- [ ] **231.2 Otázky: brány kvality pre ukrajinčinu** — kontroly odpovedateľnosti a prirodzenosti s uk, skloňovanie (uk je ohybný jazyk ako sk/cs), kontrola miešania s ruštinou (ы, э, ъ, ё a ruské tvary), slovník pojmov uk, pravidlo tém (vojna od 2014, politika, Rusko = vyradiť), domáca krajina = Ukrajina vo filtri lokálnosti.
- [ ] **231.3 Otázky: pilot** — 25 preložených univerzálnych + 25 natívnych ukrajinských (7/10 domáca scéna = Ukrajina, recept #211) → brány → vzorka 50 na posúdenie rodenému hovorcovi v jednej stránke. Odhad nákladov pred spustením (pilot do ~$5).
- [ ] **231.4 Otázky: plná dávka** — po schválení pilotu cieľ ~1 000+ schválených (aby kategórie nemali diery): preklad univerzálnych en otázok dávkou (rádovo jednotky dolárov) + natívne dávky (rádovo desiatky dolárov) → **suma na súhlas foundera vopred**; uk v týždennom dopĺňaní zábavy (#202). Len schválené do App Store.
- [ ] **231.5 Vlastné balíky po ukrajinsky** — názov jazyka, ochrana pred ruštinou, štýl domu uk, nadpisy; zdroje z ukrajinskej Wikipédie; overiť opätovné použitie balíka (#225) s jazykom uk.
- [ ] **231.6 Appka** — uk v projekte; 731 textov + 2 systémové; vybrané písmo pre cyriliku; povely po ukrajinsky (štart, ok, ďalej, znova, zopakuj, preskoč, stop, pauza, domov; výplňové slová так, ну, добре…), nápovedy a tlačidlá v rozkazovacom tvare; párovanie odpovedí A–Г a čísel v cyrilike (dnes len latinka bez diakritiky; pozor: й a ї sa nesmú zlúčiť s и a і); dátumy, mená hráčov, právne odkazy na /uk/; analytika jazyka existuje (overiť). Testy: zrkadlo sk/cs testov povelov, pixelové snímky uk.
- [ ] **231.7 Kontrola textov** — štýl textov pre uk (tykanie „ти“ ako sk/cs, právne texty „ви“, bez pomlčiek), automatická kontrola textov rozšírená o uk (ruské písmená, vykanie), plná kontrola iným modelom ako pri #226.
- [ ] **231.8 Web** — `/uk/` (texty, 3 právne stránky, tematické stránky s ukrajinskými adresami, ukážka hlasu), hreflang a mapa stránok sa doplnia samé.
- [ ] **231.9 App Store a nákupy** — ukrajinský popis, názov, podnadpis, kľúčové slová, What's New, snímky s ukrajinskými nadpismi, názvy nákupov a predplatného, TestFlight texty; dostupnosť v obchode Ukrajina a ceny (Apple prepočíta automaticky, **úprava ceny pre Ukrajinu = rozhodnutie foundera**). Nahrá sa s najbližšou verziou.
- [ ] **231.10 Overenie rodeným hovorcom** — jedna stránka: texty appky (podľa obrazoviek), App Store, web, právne, 50 otázok, ukážky hlasu; pripomienky → opravy.
- [ ] **231.11 Test celku** — simulátor: celý kvíz po ukrajinsky, prepnutie jazyka, vlastný balík, denná výzva; hra spolu: hostiteľ uk + hosť sk v miestnosti aj na diaľku; zariadenie (TestFlight na požiadanie): povely, odpovede hlasom a A–Г, hovorí rodený hovorca. Potom zapnúť uk na serveri.
- [ ] **231.12 Marketing (neskôr, samostatné rozhodnutie)** — ukrajinské sociálne siete, ASO pre ukrajinský obchod.

## Poradie a závislosti

231.0 → (231.1 ‖ 231.6 ‖ 231.8 ‖ 231.9) → 231.2 → 231.3 → 231.4 ‖ 231.5 → 231.7 → 231.10 → 231.11.
Jazyk ide naostro až po 231.11 vypínačom na serveri; dovtedy sú hotové časti skryté.

## Otvorené

- Cena predplatného a balíkov v ukrajinskom obchode (pri 231.9).
- Písmo pre cyriliku (pri 231.0 d, varianty na výber).
- Kto je rodený hovorca a koľko času mu môže founder vziať (pri 231.3).
