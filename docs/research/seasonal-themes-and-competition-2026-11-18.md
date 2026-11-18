# Sezónne témy a súťaživosť s kamarátmi (rešerš 2026-11-18)

Session: quiz-agent-47 · Founder ask: tematické otázky podľa toho, čo sa deje (teraz Vianoce), a súťaživosť ako v hre Ponor, čo najskôr v appke.
Súvisí: [#205 — Denná výzva: hráč proti davu](../issues/issue-205-daily-challenge.md) · [rešerš 10-15 o porovnaní s ostatnými](gamification-social-comparison-2026-10-15.md) · #232 — zdieľanie kvízu odkazom.

## Východisko: čo už máme

- **Denná výzva (#205) je hotová a je v appke v App Store** (každý build od 1.1 b78, teda aj 1.2 b84 v predaji a b89 v bete). Na serveri je vypnutá (`daily_challenge_enabled: false`, overené na prode 11-18). Zapnutie = prepínač na serveri, **bez nového buildu a bez App Review**.
- Otvorené pred zapnutím: 205.7 text zásad ochrany súkromia (dnes spomína „výsledky dennej výzvy“, ale nie, že iným hráčom ukazujeme súhrnné počty) a neutrálne znenie „Dnes si prvý.“ (pravidlo rodovo neutrálnych textov).
- API dennej výzvy neposiela názov témy. Vianočné otázky v dennej výzve teda pôjdu bez nového buildu, ale nápis „Adventná výzva“ na karte na Home potrebuje nový build (pridať pole sa dá bez rozbitia starších verzií).
- Otázky majú `tags` a generátor má „themed“ pipeline; sada dňa sa vyberá na serveri, takže vybrať v dátumoch 1.–24. 12. otázky s vianočným štítkom je malá zmena na serveri.

## 1. Sezónne témy

**Verdikt: áno, ale ako tenká vrstva nad dennou výzvou, nie nový systém.** Dôkazy sú prax odvetvia, nie merané čísla pre kvízy.

- 90 % zo 100 najzarábajúcejších mobilných hier robí sezónne udalosti ako hlavný nástroj návratu hráčov ([GameRefinery](https://gameindustrylibrary.com/documents/in-game-events-snapshot-2021)); Sensor Tower odporúča práve **adventný kalendár** ako denný rituál ([Sensor Tower](https://sensortower.com/blog/liveops-for-the-holiday-season)).
- Udalosti zvyšujú hlavne krátkodobý návrat, nie dlhodobý ([AppMagic 2025](https://mobidictum.com/appmagic-liveops-report-2025/)), takže má zmysel viazať ich na niečo, čo ostane (denná výzva).
- Trivia Crack robí vianočné kolá a balíky ([Pocket Gamer](https://www.pocketgamer.co.uk/trivia-crack/trivia-crack-franchise-spreads-holiday-cheer-with-new-features-and-surprises/)); Sporcle má adventné kvízy ([Sporcle](https://www.sporcle.com/games/needapausebutton/it-is-not-in-the-url)).
- Vianočných zoznamov otázok je na webe veľa a sú rovnaké; jediná doložená sťažnosť hráčov vianočných kvízov je **opakovanie**: „Same questions over & over at every level.“ ([recenzie](https://justuseapp.com/en/app/1514873844/christmas-game-trivia-quiz/reviews)). Našou výhodou sú overené otázky so zdrojom, natívne sk/cs.
- SK/CZ média robia vianočné kvízy o tradíciách a filmoch ([Startitup](https://www.startitup.sk/?p=1001052), [TN Nova](https://tn.nova.cz/zpravodajstvi/clanek/401590-vrkoc-polac-trezolka-jak-dobre-znate-ceske-vanoce-kviz)); adventný kvíz v appke v SK/CZ sme nenašli.

**Odporúčané formy (poradie):**
1. **Adventná výzva 1.–24. 12.:** denná výzva s vianočnými otázkami (5 denne). Využije hotovú dennú výzvu aj porovnanie s ostatnými.
2. **Karta na Home s vianočným balíkom** pre tých, čo nehrajú denne (bežný kvíz z vianočnej témy).
3. **Jednodňové špeciály:** Mikuláš 6. 12., Silvester 31. 12., Traja králi 6. 1.

**Kalendár do februára 2027:** 1. advent 29. 11. · Mikuláš 6. 12. · Štedrý deň 24. 12. · Silvester 31. 12. · Traja králi 6. 1. · MS v zjazdovom lyžovaní 1.–14. 2. ([FIS](https://fis-ski.com/alpine-skiing/news/2024-25/fis-alpine-world-ski-championships-2027-in-crans-montana-confirmed)) · Valentín 14. 2. · MS v biatlone približne 10.–21. 2. (zdroje sa líšia). Hokejové MS sú až v máji.

**Riziká:** otázky o tradíciách a histórii, nie o aktuálnych správach či výsledkoch (rýchlo zastarajú a ťažko sa overujú); SK a CZ Vianoce sa líšia (Ježiško, kapor, rozprávky), teda natívne sady, nie preklady; 24 dní × 5 otázok × 3 jazyky = ~360 otázok, na budúci rok nové; žiadny obsah za paywallom; náboženstvo podať kultúrne a fakticky.

## 2. Súťaživosť: Ponor a podobné hry

**Ponor** ([ponor.sk](https://ponor.sk/), [TouchIT](https://touchit.sk/hra-ktora-preveri-vasu-slovnu-zasobu-otestujte-sa-v-novej-slovenskej-hre/931034/)) je slovenská verzia anglického Krillion: 7 rovnakých zadaní denne, ~25 s na odpoveď, **body za čo najzriedkavejšiu odpoveď**, hrá sa bez účtu, **vlastná liga s kamarátmi** (prezývka, skóre vidia len členovia ligy), po hre vidíš, ako odpovedali iní, a výsledok zdieľaš. Česká verzia má aj verejný rebríček „Celé Česko“ (len po prihlásení, dnes a týždeň), séria dní, odznaky a platené PONOR+ ([ponorhra.cz](https://ponorhra.cz/sukromie)). Krillion sám ligy nemá ([krillionguide](https://krillionguide.com/en/scoring)), čiže **ligy s kamarátmi sú presne to, čo pridal Ponor**. Ako sa do ligy pridáva (odkaz/kód) sme neoverili.

- NYT Games pridali v apríli 2025 rebríček s kamarátmi (do 100 ľudí) a zámerne **žiadny globálny** ([Variety/AOL](https://www.aol.com/nyt-games-feature-let-fans-130334090.html)).
- Pri Wordle si ľudia sami robili rebríčky s kamarátmi cez Discord a weby ([Leaderboardle](https://www.producthunt.com/products/leaderboardle/launches)), dopyt je jasný.
- Quizduell (100 mil. hráčov) stál na súbojoch s kamarátmi; upadol pre reklamy a poplatok za počet kamarátov ([appgefahren](https://www.appgefahren.de/neues-quizduell-abgesang-auf-ein-populaeres-wissensquiz-293772.html)).
- HQ Trivia zabili boti a podvodníci, keď boli peňažné výhry ([Complex](https://www.complex.com/life/a/cmplxjoshua-espinoza/hq-trivia-shuts-down-after-three-years)); pri Wordle hľadanie odpovedí na Googli po kúpe NYT stúplo takmer trojnásobne ([NBC](https://www.nbcnewyork.com/news/business/money-report/it-seems-like-a-lot-of-you-are-cheating-at-wordle-study/3584772/)).
- Hlasy hráčov: „The global leaderboards are super boring…“ a pochvala rebríčka len s kamarátmi ([Tildes](https://tildes.net/~comp/13d7/leaderboards_arent_just_for_games_a_pep_talk_to_inspire_developers)); skupina prestala zdieľať Wordle, lebo posledný sa hanbil za horší výsledok ([Book Riot](https://bookriot.com/what-wordle-has-taught-us/)).
- Hlasy hráčov Ponoru (Reddit, FB) sme cez vyhľadávanie nenašli; čísla o tom, či lepšie drží hráčov liga, súboj alebo zdieľanie, neexistujú. Poradie nižšie je úsudok, nie meranie.

**Odporúčanie pre Trubbo (máme málo hráčov, globálny rebríček by bol prázdny):**
1. **Liga s kamarátmi nad dennou výzvou:** pozvánka odkazom, prezývka, poradie dnes a za týždeň. Funguje už pre 2 ľudí a každá pozvánka privedie nového hráča.
2. **„Prekonaj ma“ odkaz:** zdieľaný výsledok dennej výzvy nesie moje skóre, kamarát hrá tých istých 5 otázok a vidí porovnanie. Menší krok, nadväzuje na #232 (zdieľanie odkazom).
3. **Body za zriedkavosť** ako v Ponore: kto vedel, čo ostatní nie, dostane viac. Máme to už napoly („najvzácnejší zásah“) a znižuje to hodnotu podvádzania (vygooglená odpoveď je bežná).

**Podvádzanie a malá komunita:** hlasová odpoveď s časovým limitom sťaží googlenie; žiadne peňažné výhry; ukladať čas odpovede a podozrivo rýchle správne odpovede len označiť. Ligu ukázať až pri 2+ členoch, umožniť tichý režim (vidím len svoje poradie), nikdy „posledný“.

## Navrhované poradie (najrýchlejšie k hráčom)

| Krok | Čo | Potrebuje nový build? |
|---|---|---|
| A | Zapnúť dennú výzvu (text súkromia, neutrálne „prvý“, rýchla kontrola na simulátore) | nie |
| B | Adventná výzva 1.–24. 12. (vianočné otázky sk/cs/en, výber podľa dátumu na serveri) | nie (nápis témy na karte áno) |
| C | Liga s kamarátmi + „prekonaj ma“ odkaz | áno, App Review |
