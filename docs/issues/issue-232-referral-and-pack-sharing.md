# #232 — Zahraj si môj kvíz: zdieľanie kvízu odkazom

**Triage:** enhancement · ready-for-agent
**Status:** rozsah zmenený 2026-11-11 (najprv zdieľanie kvízu, odmena za pozvanie neskôr); design-soundness 2 kolá zapracované (posledný nález: vlastné pravidlo pre balík); ďalej 232.0 overenie
**Founder:** 2026-11-09 „viac propagovať zdieľanie appky za nejaký benefit“; 2026-11-11 „pozvanie kamaráta musí fungovať bez kopírovania kódu“, vybral „zdieľať kvíz odkazom“; 2026-11-12 nápad „zahrám si kolo, pošlem odkaz na to isté kolo partii a porovnáme výsledky“ (zlúčený sem z TODO)
**Návrh a prieskum:** https://claude.ai/artifact/FT91hmcTC6Xhczf7TpJnmQ (session quiz-agent-20)

## Cieľ

Hráč po kvíze pošle odkaz „zahraj si môj kvíz“. Kamarát dostane presne tie isté otázky, aj keď si appku musí najprv stiahnuť, a nemusí nič kopírovať ani písať. Na konci vidí, ako dopadol oproti odosielateľovi a ostatným, ktorí ten kvíz hrali.

**Hotovo, keď:**
- odkaz sa dá poslať po bežnom kole, po dennej výzve aj pri vlastnom balíku;
- kamarát s appkou ťukne na odkaz a hneď hrá;
- kamarát bez appky ťukne na odkaz, stiahne appku a po prvom spustení ťukne na jedno tlačidlo, ktoré ho pustí do toho istého kvízu;
- po dohraní vidia odosielateľ aj kamaráti porovnanie výsledkov;
- hotový vlastný balík sa dá hrať aj v hre spolu;
- všetko je za vypínačom na serveri, analytické udalosti sú v tom istom PR a test na zariadení prešiel.

## Rozhodnutia foundera

| Otázka | Voľba |
|---|---|
| Prvý krok (11-11) | **Zdieľať akýkoľvek kvíz odkazom**, bez odmeny. Dáta: 7 hráčov za 30 dní, žiadny ostrý nákup vlastného balíka, takže samotné zdieľanie balíka by nemal kto použiť. |
| Bez kódu (11-11) | Kamarát nič nekopíruje ani nepíše |
| Porovnanie (11-12) | Každý si kvíz zahrá, kedy chce, a výsledky sa porovnajú. Nie naživo, na to je hra spolu. |
| Poslaný balík (11-12) | Kamarát si ho **zahrá raz** ako výzvu, neuloží sa mu (odkaz sa dá posielať ďalej, trvalá kópia by brala predaj balíkov) |
| Balík v hre spolu (11-09) | Áno. Hra spolu je od 11-12 zapnutá aj v App Store buildoch. |
| Odmena za pozvanie (11-09/10) | **Neskôr**, na to isté prepojenie. Platí: len pozývajúci, balík 10 otázok po prvom dohranom kvíze kamaráta, strop 3 na Apple účet, mobil kamaráta označený cez DeviceCheck. Pozri „Neskôr“. |

## Čo už platí (overené 2026-11-12)

- **App Store odkaz s parametrom appka po inštalácii neprečíta.** Kampaňový parameter Apple ukazuje len v súhrnných štatistikách. Prenos treba spraviť vlastnou stránkou ([Apple](https://developer.apple.com/help/app-store-connect-analytics/acquisition/campaign-links/)).
- **Pevný zoznam otázok** už server vie: denná výzva tak púšťa svojich 5 otázok v danom poradí a preskočí chýbajúce. Pri zakladaní bežnej relácie sa zoznam otázok zatiaľ zadať nedá.
- **Denná výzva:** 5 otázok pre jazyk a deň, rovnaké pre všetkých, jeden pokus na hráča, starší deň sa hrať nedá. Porovnanie s ostatnými hráčmi už má („lepší ako X % z N“). Dnes sa zdieľa len text výsledku bez odkazu.
- **Bežné kolo** vyberá otázky priebežne a náhodne, takže kolo sa po dohraní nedá zopakovať, kým si server nezapamätá, čo padlo. Preklady sk/cs majú rovnaké ID ako originál, ale preklad za behu nemusí vyjsť dvakrát rovnako.
- **Vlastný balík** smie hrať len vlastník (cudzí balík vráti „nenájdené“). Kópiu hotového balíka pre iného vlastníka server vie spraviť okamžite (#225).
- **Limit zadarmo:** dennú výzvu a balík limit nepočíta, bežné kolo áno. Miestnosť dnes odmieta balík aj dennú výzvu.
- **Odkazy a web:** pozvánky do hry spolu idú cez trubbo.app/join?t=… ako univerzálny odkaz. Web je statický (GitHub Pages), takže nová stránka má rovnaký tvar: play.html a trubbo.app/play?s=TOKEN.

## Návrh riešenia

**Zdieľaný kvíz na serveri.** Po dohratí kvízu (alebo pri balíku) appka požiada o odkaz. Server uloží záznam so zoznamom otázok v poradí, jazykom, druhom (kolo, denná výzva, balík), odosielateľom a jeho výsledkom a vráti krátky náhodný token. Záznam neobsahuje nič, čo by odhalilo odpovede, a vzniká až na požiadanie, nie pri každom kole.
- **Zoznam otázok zostaví server sám** z odosielateľovej vlastnej relácie, teda z otázok, ktoré naozaj dostal, s kontrolou, že relácia je jeho. Nikdy ho nepreberá od appky, inak by sa cez zdieľanie dal obísť limit zadarmo.
- **Pri ukladaní** prejdú len otázky, ktoré by mohol dostať ktokoľvek: schválené, bez obrázka, nie z balíka a pri sk/cs so schváleným uloženým prekladom (rovnaké pravidlo ako výber dennej výzvy). Tak kamarát vidí to isté znenie ako odosielateľ a hráč z TestFlightu cez odkaz nepošle neschválenú otázku do App Store buildu.
- **Pri hraní** sa zoznam znova prefiltruje pravidlami kamaráta (stav schválenia podľa jeho buildu, medzitým vyradené otázky). Pevný zoznam dennej výzvy dnes tieto filtre obchádza, lebo jej otázky sú prefiltrované vopred. Pre zdieľané kolo to platiť nemôže.
- **Zdieľaný balík má vlastné pravidlo**, lebo otázky balíka sa nikdy neschvaľujú do korpusu a filter schválenia by ho vyprázdnil. Platí: len otázky toho istého balíka a bez vyradených a expirovaných (rovnaké pravidlo ako kópia balíka #225).

**Kamarát hrá:**
- **Kolo:** nová relácia s pevným zoznamom otázok zo záznamu, v jazyku záznamu.
- **Denná výzva:** v ten istý deň a jazyk odkaz kamarátovi spustí jeho vlastnú dennú výzvu (otázky sú rovnaké a ráta sa mu pokus). Neskôr sa tých 5 otázok hrá ako bežné zdieľané kolo.
- **Balík: zahrá si ho raz** (founder 2026-11-12). Kamarát hrá tie isté otázky ako výzvu, ale balík sa mu neuloží a nedostane kópiu, takže predaj balíkov to nepoškodí. Relácia z tokenu smie čítať len otázky uložené v zázname a len z tohto balíka. Bežná kontrola vlastníctva balíka pre ostatné relácie sa nemení. „Raz“ sa stráži už pri založení relácie z tokenu, na osobu (zariadenie aj účet ako jedna osoba), nielen jedným výsledkom. Zdieľať sa dá len hotový balík.
- **Limit zadarmo** zdieľaný kvíz nepočíta (ako denná výzva). Korpusové otázky nás nestoja takmer nič, takže limit tu nie je ochrana nákladov a zbytočne by kamarátovi zavrel dvere. Predpoklad agenta, founder môže zmeniť.

**Porovnanie výsledkov.**
- Každý dohraný zdieľaný kvíz zapíše výsledok k záznamu, **jeden na človeka**. Zariadenie aj účet sa rátajú ako jedna osoba (rovnaké ako pri #225), takže opakované hranie poradie neskreslí.
- Na konci kamarát vidí poradie: odosielateľ, on a ostatní, kto to hral (meno z hry spolu, inak „Hráč 1, 2…“).
- Odosielateľ vidí to isté pri kvíze vo svojej histórii.
- Bez notifikácií.

**Prenos cez inštaláciu bez kódu:**
1. Odkaz trubbo.app/play?s=TOKEN otvorí appku, ak ju kamarát má (univerzálny odkaz).
2. Ak ju nemá, otvorí sa naša stránka play.html v sk/cs/en s témou kvízu a tlačidlom „Stiahnuť z App Store“. Ťuknutie na tlačidlo uloží odkaz do schránky a otvorí App Store. Zápis do schránky prehliadač povolí, lebo ide o ťuknutie používateľa.
3. Pri prvom spustení appka bez opýtania zistí, či je v schránke pravdepodobne odkaz (Apple na to má funkciu, ktorá neukazuje upozornenie). Ak áno, ukáže systémové tlačidlo Apple „Vložiť“ s textom „Máš kvíz od kamaráta?“. To tlačidlo upozornenie nevyvolá. Appka prijme len odkaz na trubbo.app/play.
4. Záloha: stránka aj appka povedia „ťukni na odkaz ešte raz“, a ten už otvorí appku.

Bez kódu, bez SDK, bez porovnávania IP adries (nespoľahlivé na mobilných dátach a podľa Apple je to sledovanie odtlačkom zariadenia).

**Kde sa ponúkne.**
- Tlačidlo „Pošli kamarátovi“ na konci kola.
- Na konci dennej výzvy, kde nahradí dnešný text bez odkazu: text ostane, pribudne k nemu odkaz.
- Pri vlastnom balíku.
- Nič nevyskakuje samo.

**Balík v hre spolu.** Dnes jedna vlastnosť relácie znamená naraz „nepočíta sa do limitu“ aj „len sólo“. Rozdelí sa na dve, aby zdieľané kvízy (bez limitu) nezdedili zákaz hry spolu omylom. Potom denná výzva ostáva len sólo a **hotový** vlastný balík sa povolí. Balík, ktorý sa ešte vyrába, sa vybrať nedá, takže hra spolu nemusí čakať na otázky. Hostia dostávajú otázky v tom istom tvare ako dnes.

**Súkromie.** Len systémové okno zdieľania. Appka nikomu nepíše a nečíta kontakty (Apple 5.1.2, GDPR). Token je náhodný, nedá sa uhádnuť a ukáže len tému kvízu a mená hráčov z porovnania.

**Kompatibilita a vypínač.**
- Prepínač v app-config na serveri, predvolene vypnutý, kým founder neotestuje.
- Nové endpointy a voliteľné polia sú len doplnky.
- V existujúcich odpovediach nepribudne žiadna nová hodnota zoznamu, aby prešla kontrola kompatibility starých buildov.

## Úlohy

- [ ] **232.0 Overenie** na reálnom iPhone:
  - zápis do schránky z našej stránky v Safari aj vo vnútorných prehliadačoch (Messenger, Instagram; WhatsApp otvára Safari?);
  - zistenie odkazu v schránke bez upozornenia a systémové tlačidlo Vložiť po čerstvej inštalácii z TestFlightu;
  - univerzálny odkaz /play vedľa /join;
  - stálosť uloženého prekladu pre sk/cs otázky v zdieľanom kole.
- [ ] **232.1 Server: zdieľaný kvíz**
  - Záznam a token.
  - Relácia z tokenu (kolo, denná výzva, balík raz bez kópie), filtre pri uložení aj hraní, bez limitu zadarmo.
  - Výsledky a poradie.
  - Verejný endpoint s témou pre web.
  - Vypínač.
  - Udalosti: kvíz zdieľaný, odkaz otvorený (appka alebo web), vložený zo schránky, zdieľaný kvíz dohraný.
- [ ] **232.2 Server: balík v hre spolu** — miestnosť prijme hotový balík. Udalosť: miestnosť s balíkom.
- [ ] **232.3 Web**
  - play.html v sk/cs/en (téma, tlačidlo App Store so zápisom do schránky, „ťukni ešte raz“).
  - Rozšírenie súboru pre univerzálne odkazy.
- [ ] **232.4 Appka**
  - „Pošli kamarátovi“ (koniec kola, denná výzva, balík).
  - Otvorenie odkazu.
  - Tlačidlo „Máš kvíz od kamaráta?“ pri prvom spustení.
  - Obrazovka porovnania.
  - Výber hotového balíka v hre spolu.
  - Texty sk/cs/en cez xcstrings.
  - Pixel snímky.
- [ ] **232.5 Texty na schválenie** — správa pri zdieľaní, web a appka v artefakte. Podľa copy-style: rodovo neutrálne, nie ako AI, bez cien.
- [ ] **232.6 Test foundera** na TestFlight builde (keď si ho vyžiada): dva reálne iPhony, kamarát s appkou aj s čerstvou inštaláciou, kolo, denná výzva, balík, balík v hre spolu. Potom zapnúť vypínač.

## Neskôr: odmena za pozvanie (rozhodnuté, nerobí sa teraz)

- Na to isté prepojenie: zdieľaný odkaz už nesie odosielateľa.
- Pozývajúci dostane balík 10 otázok, keď nový kamarát dohrá prvý kvíz (sólo alebo ako hosť v hre spolu). Pozvaný nedostane nič (Apple 3.2.2). Strop sú 3 balíky na Apple účet, odmenu treba prevziať prihlásením cez Apple. Mobil kamaráta sa označí cez Apple DeviceCheck, takže odmenu spustí len raz aj po reinštalácii ([Apple](https://developer.apple.com/documentation/devicecheck/dcdevice) to uvádza priamo na promo ponuky).
- Z kontroly riešenia (design-soundness SOUND 0,85, 2026-11-10):
  - koniec hry v miestnosti rátať každému účastníkovi;
  - strop overovať pri prevzatí a zlúčení účtov;
  - objednávky referral- potrebujú vlastnú vetvu oprávnenia;
  - founder vytvorí kľúč DeviceCheck.
- Začať, keď bude dosť hráčov, aby sa dalo zmerať, či zdieľanie samo funguje (udalosti z 232.1).
