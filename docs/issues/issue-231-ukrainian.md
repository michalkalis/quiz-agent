# #231 — Ukrajinčina ako štvrtý jazyk

**Triage:** enhancement · ready-for-agent
**Status:** 2026-11-19 postavené a nezávisle skontrolované (server, otázky, appka, texty); uk je na serveri vypnutá; ďalší krok = TestFlight build na požiadanie foundera a kontrola rodeným hovorcom v appke (231.10, 231.11) — [stránka overenia](https://claude.ai/artifact/E9tRubgL2ZeVmhh9Z7hXyZ)
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
- [~] **231.4 Otázky: dávka** — natívne ukrajinské otázky na predplatnom (zadarmo, `generate_pack --dry-run`, recept zo skúšky štýlu), 2 na tému, témy polovica ručne a polovica od modelu; prvá dávka ~200 z mesačného API kreditu k predplatnému (founder 2026-11-18), zvyšok do ~600 po kontrole v appke; cez všetky kategórie, 7/10 Ukrajina; duplicity v dávke preč (`run_dups.py`); import so strojovým schválením cez brány. Preklad univerzálnych en otázok len ak natívne nepokryjú kategórie (najprv uk podpora v prekladovom nástroji). Potom uk v týždennom dopĺňaní zábavy (#202) so súhlasom foundera na sumu.
  - [x] Dávka 1 (2026-11-18, `docs/testing/runs/uk-corpus-2026-11-18/`): 100 tém × 2, z API kreditu (~$18), 197 otázok, 11 rovnakých faktov preč → **186 v prode** (185 strojovo schválených, 1 len TestFlight), všetky so zdrojom, 0 ruských písmen. Kategórie nevyvážené (general 71, geografia 6, zábava 6) → dávka 2 doplní slabé kategórie po kontrole v appke.
  - [x] Oprava dávky 1 po nezávislej kontrole (2026-11-18, `corrections-2026-11-18.md` + `apply_corrections.py` v tom istom priečinku): 4 vyradené (rovnaký fakt alebo odpoveď prezradená inou otázkou), 6 nových zdrojov namiesto ruských alebo nesediacich, ruské tvary preč z uznávaných odpovedí, drobné opravy textu; potom všetky uk riadky znova cez sprísnené brány. **Stav v prode: 150 schválených, 32 čaká na človeka (len TestFlight), 4 vyradené.** Z 32 čakajúcich: 22 neprešlo kontrolou prirodzenosti (brána ich predtým aj tak schválila), 6 zadržal filter tém (rok od 2014, „парламент“, „облоги“ = zväčša falošné poplachy na posúdenie), 2 rekord bez roku, 2 úmyselne (odpoveď je holé písmeno «Ї»; autentický podpis s ъ). Schválené podľa kategórií: general 48, história 24, jedlo 20, veda 20, film a hudba 16, šport 12, zábava 6, geografia 4.
- [x] **231.5 Vlastné balíky po ukrajinsky** (2026-11-18, PR #903) — cyrilika v párovaní faktov a tém (predtým len latinka), ukrajinský balík necituje ruské stránky, opätovné použitie balíka (#225) drží jazyk a berie oba ukrajinské apostrofy. Skúška zadarmo cez predplatné (2 balíky × 10 otázok, cesta objednávky bez zápisu do DB): všetky so zdrojom, 0 ruských písmen; kuchyňa 7/10 ukrajinské zdroje, vesmír anglické (NASA, ESA). Objednávky uk ostávajú vypnuté (`PACK_ORDER_LANGUAGES`). Na posúdenie pred zapnutím: kontrola témy pred platbou nepozná ukrajinské pravidlo tém (pozri Otvorené); detské balíky 4–6 majú príklady v zadaní len sk/cs; kontrola odpovedateľnosti občas vyradí dobrú odpoveď pri skloňovaní jedného slova (rovnako sk/cs).
- [x] **231.6 Appka** (2026-11-19, PR #862, #860) — všetky texty appky po ukrajinsky (vrátane systémových), cyrilika v písme **Manrope** (len uk, ostatné jazyky bez zmeny), povely: «Старт», «Підтверди» / «Добре», «Далі», «Ще раз», «Повтори», «Пропусти», «Стоп», «Пауза», «Додому»; krátke slová («так», «добре», «ні») platia len samostatne a slovo podobné povelu («Правильно», «Сто») ostáva odpoveďou; odpovede 1–4 a čísla v cyrilike (й a ї sa nezlučujú s и a і); právne odkazy na /uk/; pixelové snímky uk pre všetky obrazovky vrátane rodinného režimu, pozreté. Tvary množného čísla (1 питання, 5 питань, 21 питання) stráži test nad skutočnými textami. Známe: systémové tlačidlo Sign in with Apple je po anglicky, kým iPhone nie je v ukrajinčine; pri najväčšom písme sa dlhé slová delia («пита-ння»).
- [x] **231.7 Kontrola textov** (PR #857, #896) — štýl textov pre uk (tykanie „ти“ ako sk/cs, právne texty „ви“, bez pomlčiek), automatická kontrola textov rozšírená o uk (ruské písmená, vykanie), plná kontrola iným modelom ako pri #226. Od PR #896 automatická kontrola v CI naozaj číta aj uk hodnoty (predtým len sk/cs/en) a padá na ruských písmenách a slovách.
- [~] **231.8 Web** (PR #859, **pozastavené do spustenia**, web sa nasadí pri merge) — `/uk/` (texty, 3 právne stránky, tematické stránky s ukrajinskými adresami, ukážka hlasu), hreflang a mapa stránok sa doplnia samé. Po kontrole textov: jednotné slová s appkou («підписка», «безплатно»), prázdna stránka „nové tento týždeň“ sa pre uk nevytvára, kým nemá otázky, počty otázok v správnom tvare. 2026-11-19 zosúladené s main (stránky o súkromí vrátane partie v dennej výzve) a ukrajinčina doplnená na stránky zdieľaného kvízu a pozvánky do hry.
- [~] **231.9 App Store a nákupy** (texty v PR #859, pozastavené) — ukrajinský popis, názov, podnadpis, kľúčové slová, What's New, snímky s ukrajinskými nadpismi, názvy nákupov a predplatného, TestFlight texty; dostupnosť v obchode Ukrajina a ceny (Apple prepočíta automaticky, **úprava ceny pre Ukrajinu = rozhodnutie foundera**). Nahrá sa s najbližšou verziou.
- [ ] **231.10 Overenie rodeným hovorcom v appke** — prejde TestFlight build po ukrajinsky: texty appky, otázky počas hrania, čítanie; k tomu App Store texty, web a právne texty na jednej stránke; pripomienky → opravy.
- [ ] **231.11 Test celku** — simulátor: celý kvíz po ukrajinsky, prepnutie jazyka, vlastný balík, denná výzva; hra spolu: hostiteľ uk + hosť sk v miestnosti aj na diaľku; zariadenie (TestFlight na požiadanie): povely, odpovede hlasom a možnosti 1–4, hovorí rodený hovorca. Potom zapnúť uk na serveri.
- [ ] **231.12 Marketing (neskôr, samostatné rozhodnutie)** — ukrajinské sociálne siete, ASO pre ukrajinský obchod.

## Nezávislá kontrola (2026-11-18 večer)

Štyri nezávislé čítania (server, otázky a dávka 1, kód appky, ukrajinské texty) celej práce na #231. Čo našli a čo sa s tým stalo:

| Nález | Oprava |
|---|---|
| Ukrajinská hra by dostávala anglické otázky preložené strojom za behu, bez brán | PR #898: uk sa hrá **len z otázok napísaných po ukrajinsky**; keď dôjdu, hra sa skončí ako pri každej vyčerpanej zásobe |
| uk sa dala vyžiadať napriek vypínaču (hra, objednávka balíka, verejný zoznam nových otázok na webe) | PR #898: server uk odmieta, kým nie je v zozname; nasadené a overené |
| Filter tém prepúšťal vojnu a politiku inými slovami a zároveň zahadzoval dejiny pred 2014 | PR #901: tri stupne (čisté / čaká na človeka / vyradené); nejasné veci čakajú na človeka |
| Ruština sa hľadala len podľa 4 písmen a ~20 slov | PR #901: ruské slová, tvary mien, ruské zdroje (.ru, RT…) |
| Otázka s neúspešnou kontrolou prirodzenosti ostala schválená | PR #901: pre uk je úspešná kontrola podmienkou schválenia |
| Čítanie nahlas: písmená možností C/D, „2,5“, „1-го“, rímske storočia, „7 з 10“ v zlom páde, roky „р.“ | PR #902 (zoznam viet na vypočutie nižšie) |
| Povely: «Правильно» spustilo „znova“, «Сто» spustilo „stop“ | PR #862 |
| Texty: systémové Nastavenia sú «Параметри», dve slová pre predplatné a zadarmo, kostrbaté vety | PR #860, #859 |
| Automatická kontrola textov ukrajinčinu vôbec nečítala | PR #896 |
| Stránky o súkromí uvádzali starý hosting (všetky jazyky) | PR #891 |

Staré buildy z App Store (1.1, 1.2) ukrajinčinu v zozname jazykov neukážu (overené v kóde oboch značiek) → zapnutie = prepnutie vypínača na serveri, netreba bránu podľa buildu.

**Na vypočutie rodeným hovorcom v appke:** «А… Бе… Це… Де…» (možnosti pri číselných odpovediach), «дві цілих п'ять десятих метра», «у тисяча дев'ятсот дев'яностих роках», «у дев'ятнадцятому столітті», «з тисяча дев'ятсот тридцять дев'ятого по тисяча дев'ятсот сорок п'ятий рік», «Це знали лише два із дев'яти», «Правильних відповідей: сім з десяти», «Лише один відсоток це знав».

**Neopravené, vedome:** rod číslovky pred podstatným menom («один книга», rovnako sk/cs); «до н. е.» sa číta po písmenách; hlas sa vyberá podľa písma textu, nie jazyka hry; v sk/cs spustí «sto» povel „stop“ (rovnaká diera ako bola v uk, samostatná oprava); cyrilika u hráča so slovenským rozhraním (hosť v ukrajinskej miestnosti) sa vykreslí systémovým písmom; nepoužívaný kód na párovanie odpovedí v appke (`MCQTranscriptMatcher`) na vyčistenie.

## Poradie (od 2026-11-18)

Founder 2026-11-18: ukážky už neiterovať, stavať všetko a skontrolovať priamo v appke.

1. **Vlna 1 súbežne:** 231.6 appka (najväčšia, jeden iOS worker s vlastným simulátorom) ‖ 231.7 + 231.8 + 231.9 texty, web, App Store (worker bez iOS) ‖ 231.4 dávka otázok na predplatnom (beží na pozadí).
2. **Vlna 2:** 231.5 vlastné balíky; server ukazuje uk len buildom, ktoré ju poznajú (staré buildy nesmú vidieť jazyk bez textov), plus TestFlight.
3. **Kontrola v appke:** TestFlight build na požiadanie foundera → founder a rodený hovorca prejdú appku (231.10 + 231.11), opravy podľa nálezov.
4. **Zapnutie:** uk naostro vypínačom na serveri + App Store texty s najbližšou verziou.

## Otvorené

- Cena predplatného a balíkov v ukrajinskom obchode (pri 231.9).
- Koľko času môže rodený hovorca venovať kontrole v appke (pri 231.10).
- Má ukrajinský hráč smieť objednať vlastný balík na tému vojny alebo politiky? Dnes to kontrola pred platbou pustí; pravidlo tém platí len pre naše otázky.
- Tlačidlo a povel na ďalšiu otázku: dnes «Пропусти» (overené diktovaním); pravidlo z #224 by pre sk/cs/en znamenalo «Наступне» (funguje ako synonymum). Posúdi rodený hovorca.
- 32 otázok čakajúcich na človeka: schváli ich rodený hovorca v appke, alebo ich prepíšeme v dávke 2?
- Právne odkazy v appke pre uk vedú na trubbo.app/uk/…, ktoré budú živé až po merge PR #859 (web). Pred TestFlight kontrolou buď web pustiť, alebo počítať s tým, že odkazy nefungujú. Dnes otvoria v Safari stránku „nenašlo sa“ (en/sk/cs), appka nespadne.
- Zásoba pre ukrajinskú hru je 150 schválených otázok (geografia 4, zábava 6) a hrá sa len z nich; keď dôjdu, hra sa skončí. Dávka 2 má prísť až po kontrole v appke: stačí to na kontrolu, pred zapnutím naostro treba doplniť.
