# #220 — App Store marketing (ASO): kľúčové slová, vlastné stránky produktu, udalosti v appke

**Triage:** enhancement · ready-for-agent (220.1–220.3 hneď; zvyšok podľa časovania nižšie)
**Status:** 2026-11-01 founder: robiť ASO, kľúčové slová sk/cs/en, vlastné stránky produktu (CPP) s vlastnými kľúčovými slovami, udalosti v appke (in-app events), testy stránky produktu (PPO).
**Súvisí:** #190 — beta a pripravenosť App Store listingu (zdroj textov, upload) · #217 — verejné vydanie v App Store · #210 — marketing na sociálnych sieťach (odkazy na CPP do bio/reklám) · #212 — Hra spolu · #213 — Prehľad hráča (Wrapped) · [growth research](../research/growth-strategy-2026-10-21.md) · staršia ASO rešerš z PR #148 (`docs/research/app-store-launch-organic-marketing.md`, len v commite 21076d6b, nie v `main`)

## Cieľ

Viac stiahnutí z vyhľadávania v App Store bez platených nástrojov: lepšie názvy, podnadpisy a kľúčové slová v sk, cs a en, samostatné stránky produktu pre rôzne publiká (partia, cesta autom, rodina) a udalosti v appke, ktoré sa ukazujú vo vyhľadávaní a dajú sa nominovať na featuring. Všetko verejné schvaľuje founder v artefakte, nahráva agent cez ASC API.

## Súčasný stav (overené v repo 2026-11-01)

- Zdroj textov: `apps/ios-app/Hangs/fastlane/metadata/{sk,cs,en-GB,en-US}/*.txt`, upload `asc-store-upload.yml` (steps=listing, dry run → apply) cez `scripts/asc_store_upload.py` (417 riadkov, CPP ani eventy nepozná). Primárny jazyk appky v ASC = en-GB; kategória ENTERTAINMENT (kvôli CarPlay, #97).
- **Názov** všade len „Trubbo“ (24 zo 30 znakov nevyužitých, názov má vo vyhľadávaní najväčšiu váhu).
- **Podnadpis:** sk „Hlasový vedomostný kvíz“, cs „Hlasový vědomostní kvíz“, en „Hands-free voice trivia quiz“.
- **Kľúčové slová:** sk 83/100 B, cs 85/100 B, en-GB a en-US 94/100 B. Limit je v **bajtoch**, nie znakoch: každé á, č, ž, ô, ř zje 2 B.
- **en-US = en-GB, slovo od slova.** USA indexuje en-US (en-GB ako primárny jazyk podľa ASO firiem tiež [W]), takže 100 B sa tam zbytočne opakuje.
- sk/cs obsahujú „trivia“, ktoré už je v en-GB podnadpise, a en-GB sa indexuje aj v SK a CZ obchode (pozri pravidlá) → duplicita.
- Universal links: `applinks:trubbo.app`, appka dnes spracuje len `/join` (pozvánka do Hry spolu). Pre CPP a eventy chýbajú ďalšie cieľové miesta (napr. Hra spolu ako hostiteľ, Profil/prehľad, sada otázok).
- Appka ešte nebola schválená (1.1 čaká v review, #209), verejné vydanie je #217 (dátum neurčený).

## Overené pravidlá (Apple docs, 2026-11-01)

| Téma | Pravidlo | Zdroj |
|---|---|---|
| Jazyky v SK/CZ obchode | Slovensko: English (U.K.) + Slovak. Česko: English (U.K.) + Czech. Čeština sa v SK **neindexuje** (opravuje tvrdenie zo staršej rešerše PR #148). Že sa indexujú oba jazyky obchodu, potvrdzujú len ASO firmy [W]. | [Apple: App Store localizations](https://developer.apple.com/help/app-store-connect/reference/app-store-localizations/), [AppTweak](https://www.apptweak.com/en/aso-blog/how-to-benefit-from-cross-localization-on-the-app-store) |
| Kľúčové slová | Do 100 bajtov na lokalizáciu, každé slovo > 2 znaky, neopakovať názov appky ani firmy, žiadne názvy iných áp a firiem. Mení sa len s novou verziou (promo text kedykoľvek, 170 znakov). | [Apple: Platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information) |
| CPP | Do 70 stránok; vlastné screenshoty, promo text, videá, voliteľne deep link (iOS 18+). Kľúčové slová sa **vyberajú z kľúčových slov poslednej schválenej verzie** (nepridávajú nové, len presmerujú hľadanie na danú stránku), per lokalizácia, každá kombinácia len na jednej stránke; limit počtu neuvedený. Stránka sa dá vytvoriť, až keď má appka stav Ready for Distribution aspoň v jednej krajine. Review samostatne, bez novej verzie. Metriky po 5 prvých stiahnutiach. | [Apple: CPP](https://developer.apple.com/app-store/custom-product-pages/), [Apple: configure CPP](https://developer.apple.com/help/app-store-connect/create-custom-product-pages/configure-multiple-product-page-versions/) |
| In-app events | Názov ≤ 30 znakov, krátky popis ≤ 50, dlhý ≤ 120; odznak Challenge, Competition, Live Event, Major Update, New Season, Premiere, Special Event. Trvanie ≤ 31 dní, propagácia ≤ 14 dní vopred, ≤ 10 zverejnených a ≤ 15 schválených naraz. Bez cien, bez „najlepší/#1“, bez CAPS. Zlé kandidáty: opakované denné úlohy, zľavy bez nového obsahu, všeobecná reklama appky. Karta 16:9 (min 1920×1080), detail 9:16 (min 1080×1920), čo najmenej textu a loga. Kým appka nebola schválená, event musí ísť **v tom istom podaní ako prvá verzia**; potom samostatne. | [Apple: In-App Events](https://developer.apple.com/app-store/in-app-events/), [Apple: Submit an In-App Event](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-event) |
| PPO | ≤ 3 varianty proti originálu, len ikona, screenshoty, videá; 1 test naraz, ≤ 90 dní, nemení sa po spustení; cieľ ≥ 90 % istota; alternatívne ikony musia byť v binárke; bez ikon review nezávisle od verzie. | [Apple: Product Page Optimization](https://developer.apple.com/app-store/product-page-optimization/) |
| Featuring | Nominácia App Launch / App Enhancements / New Content, aspoň 3 týždne vopred; dá sa priložiť schválený event. | [Apple: Nominate your app](https://developer.apple.com/help/app-store-connect/manage-featuring-nominations/nominate-your-app-for-featuring) |
| ASC API | Všetko vie agent sám: kľúčové slová (`appStoreVersionLocalizations`), CPP + priradenie kľúčových slov (`appCustomProductPageLocalizations/{id}/relationships/searchKeywords`, API 4.1+), eventy (`appEvents`, `appEventLocalizations`, médiá), PPO (`/v2/appStoreVersionExperiments`), nominácie (`POST /v1/nominations`). Presné schémy overiť v 220.6 dry runom. | [CPP keywords](https://developer.apple.com/documentation/appstoreconnectapi/post-v1-appcustomproductpagelocalizations-_id_-relationships-searchkeywords), [App events](https://developer.apple.com/documentation/appstoreconnectapi/app-events), [Experiments v2](https://developer.apple.com/documentation/appstoreconnectapi/app-store-version-experiments), [Nominations](https://developer.apple.com/documentation/appstoreconnectapi/featuring-nominations) |

[W] = len ASO firmy alebo neoficiálne, overiť meraním po vydaní.

## Ako prioritizovať kľúčové slová bez platených nástrojov

Skutočné objemy hľadaní lacno nezistíme. Skóre na slovo = **relevancia × popularita ÷ konkurencia**, každé 1 až 3:

1. **Relevancia:** opisuje, čo Trubbo naozaj robí (hlasový kvíz, otázky nahlas, partia, rodina, cesta). Bez sľubov, ktoré appka nespĺňa.
2. **Popularita (náhrady):** (a) našepkávač App Store na iPhone s SK/CZ účtom: slovo sa ukáže po 2–3 písmenách = hľadané; (b) Apple Ads „search popularity“ pri návrhu kampane, bez minutia peňazí (treba účet, 220.2); (c) Google Trends sk/cz len ako slabý signál.
3. **Konkurencia:** iTunes Search API (`itunes.apple.com/search?country=sk|cz`) top 10 výsledkov: počet hodnotení a koľko áp má slovo v názve. Ukážka 11-01: „kvíz“ SK vedie „Všeobecný Vedomostný Kvíz“ (1 246 hodnotení), CZ „Všeobecné Znalostní Kvíz“ (1 713) → dosiahnuteľné; „hospodský kvíz“ má len pár slabých áp → lacné; **„otázky“ vracia hlavne párty hry typu „Nikdy jsem“** → iný úmysel, nízka priorita.
4. **Po vydaní rozhoduje meranie:** App Analytics (zdroj App Store Search), poradie pre top slová cez iTunes Search API raz týždenne, úprava s každou verziou.

Pravidlá zostavy: v rámci lokalizácie žiadne slovo dvakrát (názov + podnadpis + kľúčové slová sa kombinujú), čiarky bez medzier, jednotné aj množné číslo len ak sa obe hľadajú (pre sk/cs stemming Apple nepoznáme, tvary testovať), žiadne značky (Milionár, Riskuj, AZ-kvíz, názvy konkurenčných áp), en-GB píše anglické slová, ktoré hľadajú aj Slováci a Česi (quiz, trivia, pub quiz), lebo slúži UK aj SK/CZ.

Kandidáti na štart (nie finál, doplní 220.2):
- **sk:** kvíz, vedomostný, hlasový, otázky a odpovede, hospodský kvíz, pub kvíz, test vedomostí, všeobecný prehľad, hádanky, spoločenská hra, hra pre partiu, hra do auta, rodina, deti, zemepis, história.
- **cs:** kvíz, vědomostní, znalostní, hospodský kvíz, test znalostí, všeobecný přehled, hádanky, společenská hra, hra do auta, na cesty, rodina, děti, zeměpis, historie.
- **en-GB / en-US (rozdielne sady):** trivia, quiz night, pub quiz, general knowledge, family game, party game, car games, road trip, multiplayer, voice game, hands free, audio quiz, kids quiz, brain teaser.

## Pred verejným vydaním vs po ňom

| Pred #217 (hneď) | Až keď je appka Ready for Distribution |
|---|---|
| audit, výskum, nové názvy/podnadpisy/kľúčové slová (idú s verziou pre #217) | CPP (vytvorenie, kľúčové slová, review) |
| deep linky v appke pre CPP a eventy (idú do buildu) | PPO testy (treba návštevnosť) |
| obsah CPP (screenshoty, promo texty) a kalendár eventov s médiami | eventy podávané samostatne |
| prvý event (napr. Hra spolu) priložiť k podaniu verzie pre #217, ak 1.1 dovtedy neschvália | meranie a úpravy kľúčových slov s každou verziou |
| nominácia na featuring App Launch ≥ 3 týždne pred dátumom #217 | nominácie New Content pri sezónnych sadách |

## Podúlohy

- [ ] **220.1 Audit a východiskový stav** · agent
  Čo: tabuľka polí per lokalizácia (znaky aj bajty, duplicity, nevyužité miesto), živý stav v ASC cez `asc-audit`, poradie Trubbo pre ~30 slov v SK/CZ/UK/US obchode (pred vydaním 0, slúži ako nula).
  Prečo: bez nulového bodu nezmeriame efekt.
  Hotové: tabuľka v `docs/research/aso-keywords-2026-11.md`, nálezy zo „Súčasného stavu“ potvrdené proti živému ASC.

- [ ] **220.2 Výskum kľúčových slov** · agent (Apple Ads účet: founder)
  Čo: kandidáti sk/cs/en zo súčasných textov, konkurencie (iTunes Search API), našepkávača a otázok v appke (kategórie); skóre podľa metódy vyššie. Apple Ads popularitu doplniť, len ak founder založí účet (otázka 3).
  Prečo: 100 B je málo, poradie slov rozhoduje.
  Hotové: zoradená tabuľka so skóre a dôvodom v tom istom research súbore, CZ dostupnosť Apple Ads overená.

- [ ] **220.3 Návrh metadát** · agent
  Čo: názov (≤ 30), podnadpis (≤ 30), kľúčové slová (≤ 100 B) pre sk, cs, en-GB, en-US; en-US iná sada ako en-GB. Pravidlá: copy-style, bez pomlčiek ako interpunkcie, bez výplne, „hráš hlasom“ (nie „moderuje sám“), auto len ako jedno z použití, každý jazyk prirodzene.
  Prečo: názov a podnadpis majú najväčšiu váhu, kľúčové slová sa s nimi kombinujú.
  Hotové: návrh prejde kontrolou bajtov a duplicít (skript v scratchpade) a CI copy-review.

- [ ] **220.4 Schválenie v artefakte** · agent pripraví, founder schváli
  Čo: jeden claude.ai artefakt „ASO návrhy“: pred/po per jazyk s počtom bajtov a dôvodom, mapa CPP (publikum, screenshoty, promo text, kľúčové slová), kalendár eventov s textami a náhľadmi médií. Founder komentuje priamo v artefakte, agent zapracuje a znova zverejní.
  Prečo: founder robí review v artefaktoch, nie v súboroch (memory `feedback_review_in_artifacts`).
  Hotové: founder napíše „schválené“ ku každej sekcii; odkaz zapísaný sem.

- [ ] **220.5 Nahratie metadát** · agent
  Čo: PR so zmenou `fastlane/metadata/*/{name,subtitle,keywords}.txt` → po zlúčení `asc-store-upload` steps=listing dry run → apply → znova dry run, na najbližšej editovateľnej verzii (ideálne verzia pre #217). Review, ktoré beží, nerušiť.
  Hotové: druhý dry run bez PATCH, živé ASC = repo.

- [ ] **220.6 Nástroj pre CPP, eventy a PPO** · agent
  Čo: nový skript `scripts/asc_marketing.py` (pôvodný má už 417 riadkov) s krokmi `cpp`, `events`, `experiment`, vstupy v `apps/ios-app/Hangs/fastlane/marketing/` (texty per lokalizácia, médiá, kľúčové slová na stránku), napojený na `asc-store-upload.yml`; podanie na review cez review submissions. Dry run ako pri listingu.
  Prečo: agent nahráva sám po schválení, bez klikania v ASC.
  Hotové: dry run vypíše plán zmien pre testovaciu CPP aj event; testy na skladanie požiadaviek.

- [ ] **220.7 Deep linky pre CPP a eventy** · agent (iOS)
  Čo: rozšíriť universal links `trubbo.app` (dnes len `/join`) o cieľové miesta, ktoré CPP a eventy potrebujú (napr. Hra spolu ako hostiteľ, Profil/prehľad, konkrétna sada); analytická udalosť „otvorené z odkazu“ so zdrojom v tom istom PR.
  Prečo: CPP aj event vedú hráča rovno k obsahu, ktorý sľubujú; bez merania nevieme, ktorá stránka funguje.
  Hotové: PR zlúčený, odkazy otestované na simulátore, ide s buildom pre #217.

- [ ] **220.8 Vlastné stránky produktu (CPP)** · agent, founder schvaľuje v 220.4
  Čo: 3 stránky (predvolene Hra spolu, Na cestu autom, Rodina a deti), každá s vlastnými prvými dvoma screenshotmi, promo textom a kľúčovými slovami z verzie (unikátne na stránku), deep link z 220.7. Odkazy na stránky použiť v #210 (bio, reklamy).
  Kedy: obsah hneď, vytvorenie až keď je appka Ready for Distribution.
  Hotové: stránky schválené a viditeľné vo vyhľadávaní, metriky v App Analytics.

- [ ] **220.9 Udalosti v appke (in-app events)** · agent, founder schvaľuje v 220.4
  Čo: kalendár na 3 mesiace. Kandidáti: spustenie Hry spolu (Premiere/Major Update, s #217), vianočná sada otázok (New Season, december; len ak sada naozaj existuje), „Tvoj rok v Trubbo“ (ročný prehľad #213, Special Event, prelom decembra a januára), neskôr spustenie dennej výzvy (Major Update). Mesačný prehľad nie ako event každý mesiac (Apple neberie opakované úlohy). Médiá bez textu a loga, 16:9 aj 9:16.
  Prečo: eventy sa ukazujú vo vyhľadávaní, na stránke produktu a dajú sa priložiť k nominácii.
  Hotové: prvý event schválený; každý ďalší podaný ≥ 14 dní pred začiatkom.

- [ ] **220.10 Nominácia na featuring** · agent pripraví text, founder schváli
  Čo: App Launch nominácia pre #217 (hlas, natívne sk/cs, Hra spolu, prístupnosť), cez API alebo Playwright (founder sa len prihlási), ≥ 3 týždne pred dátumom vydania; neskôr New Content pri sezónnych sadách s priloženým eventom.
  Hotové: nominácia odoslaná, dátum zapísaný sem.

- [ ] **220.11 Test stránky produktu (PPO)** · agent, founder schvaľuje varianty
  Čo: po vydaní, keď App Analytics ukáže dosť zobrazení: najprv test prvého screenshotu (bez ikon, review bez verzie), 2 varianty, en-GB + sk. SK/CZ návštevnosť je malá, 90 % istotu možno nedosiahneme: po 90 dňoch bez výsledku test ukončiť a nič nemeniť.
  Hotové: test spustený, výsledok zapísaný, víťaz použitý alebo zamietnutý.

- [ ] **220.12 Meranie a úpravy** · agent
  Čo: mesačne App Analytics (search vs browse, konverzia per CPP, eventy), poradie top slov; slová, ktoré po 2 verziách neprinesú nič, vymeniť.
  Hotové: krátky záznam v research súbore po každom mesiaci, zmeny cez 220.3 až 220.5.

## Otázky pre foundera

1. **Názov v obchode:** pridať k „Trubbo“ popis, napr. „Trubbo: Hlasový kvíz“ (sk/cs) a „Trubbo: Voice Trivia Quiz“ (en)? Na ploche iPhonu ostane „Trubbo“. *Odporúčam áno, názov je najsilnejšie pole a dnes je takmer prázdny.*
2. **Publiká pre CPP:** stačia na začiatok 3 (Hra spolu, Na cestu autom, Rodina a deti)? *Odporúčam áno, ďalšie až podľa dát.*
3. **Apple Ads účet bez útraty:** založíš firemný účet Apple Ads len kvôli popularite kľúčových slov (bez kampane, bez platby)? *Odporúčam áno; postup dám krok za krokom, kľúče ani heslá do chatu.*
4. **Sezónne sady pre eventy:** event musí mať skutočný nový obsah. Vyrobiť na december vianočnú sadu otázok (sk/cs/en, bežný generovací postup a schvaľovanie)? *Odporúčam áno, jedna sada; inak prvé eventy len Hra spolu a „Tvoj rok v Trubbo“.*
