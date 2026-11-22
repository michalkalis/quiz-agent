# #242 — Extra kategórie zadarmo na striedačku

**Triage:** enhancement · ready-for-agent
**Status:** plán (2026-11-22)
**Session:** quiz-agent-fd · 2026-11-22

## Cieľ

K siedmim stálym kategóriám pribudnú nové tematické kategórie. Sú zadarmo a pravidelne sa obmieňajú, takže hráč má dôvod pozrieť sa, čo je nové. Nič sa nepredáva a nič sa nezamyká.

Rešerš: [paid-extra-categories-2026-11-22.md](../research/paid-extra-categories-2026-11-22.md) (34 769 vstupov).

## Rozhodnutia foundera (2026-11-22)

- Platené kategórie zatiaľ nie: „zatial nepridavat platene. uz je toho vela na platenie“.
- „pridajme nove kategorie, mozme ich obmienat pravidelne.“
- Prvá vlna tém: desaťročia a hudba, deti a rodina, Slovensko a Česko, fanúšikovské svety pod naším opisným názvom (Čarodejnícka škola, superhrdinovia), subkultúry a scény. Sviatky nie (rieši ich #241 — Vianoce 2026: otázky a príspevky).

## Čo z rešerše platí aj bez predaja

- Opakovanie otázok je tretia najčastejšia sťažnosť na obsah (330). Kategória sa ukáže až s plnou zásobou a po vyčerpaní sa hráčovi povie, že je prejdená, namiesto opakovania.
- Slabá kvalita kategórie škodí viac ako jej absencia (445 sťažností). Rovnaké brány kvality ako pri bežných otázkach, žiadna skratka.
- Názvy značiek v názve kategórie sú riziko pri Apple. Všeobecný vejár používa opisné názvy; značky ostávajú len v rodinnej sekcii, kde ich founder schválil ako holý text.

## Ako to funguje dnes

- Sedem kategórií je napevno v appke aj na serveri; server appke zoznam neposiela. Staré buildy novú kategóriu vo výbere neponúknu.
- „Všetky kategórie“ je prázdny zoznam a výber otázok vtedy kategóriu nefiltruje vôbec. Otázka s novou kategóriou by sa teda bez ďalšieho zásahu dostala do miešaného kvízu všetkých buildov, do dennej výzvy, na web, do zdieľaných kvízov a do štatistík hráča.
- Otázka nesie kategóriu ako voľný text a výber otázok filtruje podľa hocijakého identifikátora, takže server novú kategóriu zvládne bez zmeny výberu.
- Rodinná sekcia (#236 — Rodinná sekcia „S deťmi“) má katalóg tém na serveri, appka si ho stiahne a ukáže len témy s plnou zásobou. Od ostatných otázok ju však oddeľuje vekové pásmo, nie kľúč témy. Tento plán preberá katalóg, oddelenie si musí postaviť sám.

## Technický smer (s dôvodom)

1. **Katalóg na serveri, vzor rodinnej sekcie.** Kategória = kľúč s predponou `extra-`, názov v sk/cs/en, voliteľný dátum od a do. Katalóg je v kóde a mení sa cez PR (názvy prejdú kontrolou textov); server sa nasadzuje sám, takže výmena kategórií nepotrebuje vydanie appky.
2. **Jedna nová adresa pre appku** vráti aktuálne kategórie pre jazyk: len tie, ktoré sú v okne dátumov a majú dosť schválených otázok. Staré buildy ju nevolajú.
3. **Vypínač** v nastaveniach zo servera, predvolene vypnuté, kým nie je obsah.
4. **Appka (jedno vydanie):** vejár na Úvode a výber kategórií pridajú za sedem stálych aj kategórie zo servera. Keď server neodpovie, ostane sedem stálych. Uložený výber extra kategórie sa pri štarte appky zachová a zahodí sa až po úspešnom načítaní katalógu, v ktorom už nie je; potom sa ticho vráti na „všetky“. Extra karta má farbu z pevnej palety podľa poradia, vzhľad podľa odpovede foundera.
5. **Extra otázky sú oddelené od všetkého ostatného, výslovne.** Hrajú sa, len keď si kategóriu hráč vyberie. Úložisko otázok dostane nový filter „kategória nezačína na `extra-`, alebo je prázdna“ (obyčajné „nerovná sa“ by vyhodilo aj otázky bez kategórie). Použije sa vždy, keď hráč kategóriu nevybral, a tiež v: kandidátoch dennej výzvy, počte dostupných otázok, zdieľaných kvízoch, exporte na web, štatistikách hráča a v prehľade pokrytia pri generovaní. Stráži to test oddelenia podľa vzoru testu vekových pásiem. Dôvod: stála zásoba ostane vyvážená a staré buildy extra otázku nikdy nedostanú.
   - **Prejdená kategória sa neopakuje.** Kolo v extra kategórii, kde hráč už všetko počul, server odmietne s vlastným kódom (ako pri prejdenom balíku), appka ukáže „túto kategóriu máš prejdenú“ a ponuku začať odznova pre extra kategórie neukazuje.
   - **Zásoba sa počíta podľa kanála buildu**, rovnako ako pri rodinných témach: beta vidí aj otázky čakajúce na schválenie, App Store len schválené. Katalóg aj kontrola pred štartom počítajú tým istým spôsobom.
6. **Generovanie:** kategória sa pri importe nastaví výslovne (ako pri rodinných témach), klasifikátor ju neprepíše. Generuje sa z predplatného Claude, sk a cs natívne, en vlastná sada.
7. **Meranie v tom istom PR:** ktorá extra kategória sa začala hrať a koľko kôl; porovnanie s kolami zo stálych kategórií.

Zavrhnuté: zoznam v prepínačoch v databáze (názvy by obišli kontrolu textov a nemali by históriu); nová tabuľka (zbytočná pre pár riadkov); posielať aj sedem stálych zo servera (väčší zásah do appky bez úžitku teraz).

## Kroky (malé PR, za vypínačom)

- [x] 242.1 Odpovede foundera (2026-11-22): tri extra kategórie naraz, raz za mesiac sa vymenia; ukážu sa v tom istom rade za stálymi kategóriami, s označením „nové“ a dátumom, dokedy platia; prvé kategórie: Čarodejnícka škola, Superhrdinovia, Techno a klubová scéna, Rozprávky a animáky (na začiatku bežia tri, štvrtá pribudne pri prvej výmene); detské témy ostávajú v rodinnej sekcii.
- [x] 242.2 Nezávislá kontrola tohto plánu (`/design-soundness`, 2026-11-22): dva nálezy (extra otázky by pretiekli do miešaného kvízu; prejdená kategória by sa opakovala) a tri pripomienky zapracované v bodoch 4 a 5.
- [x] 242.3 Server hotové (PR #948 — oddelenie filtra, PR tento — katalóg): adresa `GET /api/v1/categories/extra?language=` vráti `{key, name, until}`; vypínač `extra_categories_enabled` (predvolene vypnutý, v `/app-config`); okno dátumov v UTC, kategória bez okna sa nikdy neukáže; zobrazí sa až od 60 hrateľných otázok v jazyku (v bete sa rátajú aj nekontrolované). Kódy: 409 `extra_category_exhausted` (prejdená kategória, bez ponuky na reset histórie; aj v predkontrole dostupnosti), 400 `extra_category_invalid` (kľúč mimo okna alebo vypínač vypnutý).
- [~] 242.4 Obsah prvej vlny: na kategóriu 60 schválených otázok na jazyk (šesť kôl bez opakovania). Founder schválil témy 2026-11-22, pripravuje sa bez prerušení:
  - **Harry Potter** (founder: „to by som sa nebal a napisal rovno“; kategória nesie skutočný názov, opisná záloha „Čarodejnícka škola“ len ak by namietal Apple): postavy a fakulty, kúzla a elixíry, čarovné tvory, miesta a predmety, metlobal, filmy a herci, ako vznikali knihy, preklady a mená po slovensky a česky.
  - **Superhrdinovia** (konkrétne mená a názvy): pôvod hrdinov a schopnosti, zloduchovia, filmy a herci, tímy, história komiksu, kostýmy a vozidlá, rekordy z kín, animované seriály.
  - **Techno a klubová scéna** (founder: „skor take zaujimavosti nez nejake fakty“): kde to vzniklo, legendárne kluby, festivaly, stroje a zvuky, žánre, DJ-i a skladby, rave 90. rokov, scéna na Slovensku a v Česku.
  - **Rozprávky a animáky** (konkrétne mená a názvy): veľké animované filmy, japonská animácia, večerníčky a československé rozprávky, klasické rozprávky a ich pôvod, pesničky, hlasy a dabing, ako sa robí animácia, vianočné rozprávky.
  - Extra otázky sa smú používať aj v príspevkoch na sociálne siete (founder 2026-11-22).
- [x] 242.5 Appka (PR feat/242-ios-extra-categories): vejár a výber čítajú katalóg za stálymi kategóriami so značkou „nové“ a „do dátumu“; pomalá a zlyhaná odpoveď servera = len stále kategórie (testy); uložený `extra-*` výber prežije spustenie, zahodí sa len po úspešnom načítaní bez neho alebo po `extra_category_invalid`; `extra_category_exhausted` = pokojná správa bez ponuky na reset; udalosť `extra_category_quiz_started` (aj v zozname udalostí servera).
- [ ] 242.6 Zapnúť vypínač po teste foundera v bete; prvá výmena kategórií podľa zvoleného rytmu.
- [ ] 242.7 Vyhodnotenie po dvoch výmenách: podiel kôl v extra kategóriách, návraty.

## Ako vymeniť kategórie

Katalóg je v kóde (`apps/quiz-agent/app/extra_categories.py`). Výmena = v PR upraviť dátumy `starts` a `until` pri kategóriách (do `until` vrátane, čas UTC), zlúčiť, a server sa nasadí; appka si zoznam načíta sama. Kategória sa ukáže, len keď má v danom jazyku aspoň 60 hrateľných otázok, inak ostane skrytá aj v okne. Bez dátumov sa kategória nikdy neukáže.

## Otvorené

- Zatiaľ nič. Odpovede z 242.1 sú zapracované v krokoch vyššie.

## Riziká

- Bez obsahu je funkcia prázdna: päť kategórií × 60 otázok × tri jazyky je asi 900 schválených otázok, najväčšia časť práce.
- Kategória, ktorú hráč rozohral, zmizne pri výmene. Zmierenie: na karte vidieť, dokedy je dostupná.
