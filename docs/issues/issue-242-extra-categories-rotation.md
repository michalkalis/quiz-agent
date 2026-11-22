# #242 — Extra kategórie zadarmo na striedačku

**Triage:** enhancement · needs-info (čaká na odpovede foundera k striedaniu a umiestneniu, potom nezávislá kontrola plánu)
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

- Sedem kategórií je napevno v appke aj na serveri; server appke zoznam neposiela. Staré buildy preto novú kategóriu nikdy neuvidia a nič sa im nepokazí.
- Otázka nesie kategóriu ako voľný text a výber otázok filtruje podľa hocijakého identifikátora, takže server novú kategóriu zvládne bez zmeny výberu.
- Rodinná sekcia (#236 — Rodinná sekcia „S deťmi“) už robí presne tento vzor: katalóg tém na serveri, appka si ho stiahne a ukáže len témy s plnou zásobou. Tento plán ho opakuje pre všeobecný vejár.

## Technický smer (s dôvodom)

1. **Katalóg na serveri, vzor rodinnej sekcie.** Kategória = kľúč s predponou `extra-`, názov v sk/cs/en, voliteľný dátum od a do. Katalóg je v kóde a mení sa cez PR (názvy prejdú kontrolou textov); server sa nasadzuje sám, takže výmena kategórií nepotrebuje vydanie appky.
2. **Jedna nová adresa pre appku** vráti aktuálne kategórie pre jazyk: len tie, ktoré sú v okne dátumov a majú dosť schválených otázok. Staré buildy ju nevolajú.
3. **Vypínač** v nastaveniach zo servera, predvolene vypnuté, kým nie je obsah.
4. **Appka (jedno vydanie):** vejár na Úvode a výber kategórií pridajú za sedem stálych aj kategórie zo servera. Keď server neodpovie, ostane sedem stálych. Uložený výber, ktorý medzitým zo striedania vypadol, sa ticho vráti na „všetky“.
5. **Miešaný kvíz („všetky kategórie“) extra otázky neberie.** Extra kategória sa hrá, len keď si ju hráč vyberie. Dôvod: stála zásoba ostane vyvážená a tematická otázka nikoho neprekvapí.
6. **Generovanie:** kategória sa pri importe nastaví výslovne (ako pri rodinných témach), klasifikátor ju neprepíše. Generuje sa z predplatného Claude, sk a cs natívne, en vlastná sada.
7. **Meranie v tom istom PR:** ktorá extra kategória sa začala hrať a koľko kôl; porovnanie s kolami zo stálych kategórií.

Zavrhnuté: zoznam v prepínačoch v databáze (názvy by obišli kontrolu textov a nemali by históriu); nová tabuľka (zbytočná pre pár riadkov); posielať aj sedem stálych zo servera (väčší zásah do appky bez úžitku teraz).

## Kroky (malé PR, za vypínačom)

- [ ] 242.1 Odpovede foundera: koľko kategórií naraz a ako často sa menia, kde sa ukážu, zoznam prvých kategórií.
- [ ] 242.2 Nezávislá kontrola tohto plánu (`/design-soundness`).
- [ ] 242.3 Server: katalóg, adresa, vypínač, okno dátumov, testy (prázdna zásoba, mimo okna, neznámy jazyk).
- [ ] 242.4 Obsah prvej vlny: na kategóriu 60 schválených otázok na jazyk (šesť kôl bez opakovania); zoznam tém na jedno schválenie, potom bez prerušení.
- [ ] 242.5 Appka: vejár a výber čítajú katalóg, pomalá a zlyhaná odpoveď servera pokrytá testom, meranie.
- [ ] 242.6 Zapnúť vypínač po teste foundera v bete; prvá výmena kategórií podľa zvoleného rytmu.
- [ ] 242.7 Vyhodnotenie po dvoch výmenách: podiel kôl v extra kategóriách, návraty.

## Otvorené

- Rytmus a počet naraz, umiestnenie vo vejári, prvé kategórie: na stránke rozhodnutí.
- „Deti a rodina“: detské témy už má rodinná sekcia. Návrh: do všeobecného vejára dať „Rozprávky a animáky“ pre všetkých, nie druhú detskú sekciu.

## Riziká

- Bez obsahu je funkcia prázdna: päť kategórií × 60 otázok × tri jazyky je asi 900 schválených otázok, najväčšia časť práce.
- Kategória, ktorú hráč rozohral, zmizne pri výmene. Zmierenie: na karte vidieť, dokedy je dostupná.
