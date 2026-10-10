# #194 — Redizajn „Sklo nad kartami“ (verzia 1.1)

**Triage:** feature · planned
**Založené:** 2026-10-08 (founder: post-launch design refresh, „menej generický dizajn, animácie“; vybraný smer Bg)
**Návrhy:** plátno https://claude.ai/artifact/7F7N4oJSqyi4FZ3VVtcJpR (jediný zdroj návrhu pre tento redizajn)
**Research:** nástroje a trendy, 2026-10-08 (zhrnutie v sekcii Kontext)

## Rozhodnutia foundera (2026-10-08)

- Smer **Bg „Sklo nad kartami“** (svetlý): otázka je nepriehľadná karta vo farbe témy, Liquid Glass len na ovládacej vrstve (horná lišta, plávajúci spodný panel, ovládač „Počúvam“ ako doplnok panela, tlačidlá, sheety).
- **Písmo** (zmena 2026-10-09): obsah (text otázky, odpovede, verdikty, skóre) = **Rethink Sans** (OFL), ovládače (tlačidlá, labely, captiony, čipy) = systémové SF Pro. Anton, Inter a IBM Plex Mono z appky odchádzajú.
- **Logo** (zmena 2026-10-09): biely otáznik, ktorého bodka je vlna 4 naklonených kariet, na kobaltovej #2C45F5 (plátno „Kolo 5: logo“). Logo 2 (5 pruhov) vyradené pre podobnosť s ikonou Google Podcasts. Maskot sa zatiaľ nepoužíva.
- **Pen sa pri tomto redizajne nepoužíva.** Tok je plátno → kód. Pen ani jeho súbor sa nemažú ani nearchivujú; o Pen founder rozhodne až po overení nového toku.
- **Redizajn je nový release (1.1) a nesmie zasiahnuť betu 1.0.** Beta žije na vetve `release/1.0`, postup v `.claude/rules/shared.md` › „Beta line vs redesign“.

## Kontext

- Appka: ~30 obrazoviek a sheetov, ~12k riadkov view kódu, 16 zdieľaných komponentov, tokeny v jednom súbore `Utilities/Theme.swift` (#188 — jednotný design systém). Min. iOS 26.0, takže natívne `glassEffect` API je k dispozícii bez záložnej vetvy.
- Stav kvízu prúdi z enumu `QuizState` (10 stavov) a odvodených čistých enumov (`QuestionListenPhase`, `VoiceFeedbackPhase`, `AnswerConfirmationView.Branch`). Obrazovky väčšinou len vykresľujú, preto redizajn môže ostať vo view vrstve.
- Research 2026-10-08: generátory (Stitch, Figma Make, v0) dávajú generický výsledok; funguje „jedna metafora → 3 smery → kritika“. Animácie: natívne SwiftUI (PhaseAnimator, KeyframeAnimator, MeshGradient, symbol effects); Rive len pre prípadného maskota.

## Poistky proti regresiám

1. **Len view vrstva.** PR redizajnu nemení `QuizViewModel*`, koordinátory nahrávania a povelov, služby ani modely. Výnimka je fáza A1 (presun logiky von z view), vždy bez zmeny správania a s testom.
2. **Najprv vytiahnuť logiku zo štyroch zmiešaných súborov:** `SettingsView` (prihlásenie, scéna, ~599–656), `QuestionView` (auto-scroll, 11 úloh, ~611), `PaywallView` (časovač, nákupné úlohy, ~671), `ContentView` (smerovanie, sheety, `ErrorView`).
3. **Snímky pred zmenou:** doplniť pixel snímky obrazoviek, ktoré ich nemajú (Settings, Onboarding, Completion, SetRecap, AnswerConfirmation, objednávka balíčka, prihlásenie, chyba), aby každé PR malo porovnanie pred a po.
4. **Testovacie identifikátory sa nemenia** (`lint-a11y-ids.py`). ViewInspector testy sa upravujú len tam, kde sa zmenila stavba obrazovky, nie správanie.
5. **Po každej fáze:** cielené testy dotknutých obrazoviek, seedované sekvencie stavov (#186 — stabilizácia stavov kvízu), RS sweep pred koncom fázy C. Nové pixel snímky sa nahrávajú len po schválení foundera (obrázky pred a po v PR).
6. **Beta je oddelená:** prepnutie urobené 2026-10-08 ešte pred fázou A (founder: redizajn nesmie zasiahnuť betu ani prípravou): `release/1.0` zmrazená na e691530c, ruleset pre `release/**`, verzia 1.1 v `main`.

## Fázy

- [x] B0 — prepnutie bety podľa `shared.md` (2026-10-08, presunuté pred fázu A).

### A. Príprava (vzhľad appky sa nemení; len v `main`, nie v bete)
- [x] A1 (#293, #297, #300, #301) — logika von zo `SettingsView`, `QuestionView`, `PaywallView`, `ContentView` do view modelov alebo malých typov; testy na presunutú logiku.
- [x] A2 (#295, len tmavé) — pixel snímky chýbajúcich obrazoviek (zoznam v poistke 3), sk/cs/en a veľké písmo ako pri hero snímkach.
- [x] A3 — dokončiť plátno: kontrola voči appke, tmavý režim, farby kategórií, stavy, ktoré na plátne chýbajú (thinking n/total, prepis na potvrdení, MCQ výsledok, varianty plánu: grace, expired, freeWithCredits).

### B. Základy (prvý kód nového vzhľadu)
- [x] B1 (#306) — tokeny: paleta Bg (sivý podklad #E8EAEE, atrament #111216, farby kategórií), systémové písmo a typografická stupnica, rohy (sústredné), tiene; lint tokenov ostáva.
- [x] B2 (#306) — komponenty: karta otázky, sklenený spodný panel s doplnkom „Počúvam“, sklenené tlačidlá a sheet, hlavné tlačidlo s odpočtom, pilulky postupu, nálepka odpovede.
  - Zlúčené 2026-10-09: paleta Bg svetlá aj tmavá, farby 7 kategórií + vlastné balíčky, SF cez iOS textové štýly (Dynamic Type ostáva; display 28/40/52), hlavné tlačidlo atrament s odpočtom, sklo na ovládačoch (koliesko, ✕, Písať, Preskoč, lišta Počúvam), pilulky postupu atrament, nesprávna odpoveď neutrálna; nové `HangsDeckCard` + `HangsAnswerSticker` (do obrazoviek vo fáze C). Svetlé snímky obrazoviek pribudli. Sklo sa v testových snímkach nevykreslí, overené na simulátore.
- [x] B3 (#316, #322) — pohyb: rozdanie, otočenie, vejár, posun karty, lesk skla; haptika ku kľúčovým momentom; všetko vypnuté pri „Obmedziť pohyb“.
- [~] B4 — katalóg (#188) pregenerovaný z nových tokenov a komponentov (generátor už pozná nové názvy tokenov, #306; republikovanie po fáze C).

### Postup od 2026-10-09
- **Founder 2026-10-09:** medzivýsledky neschvaľuje, chce vidieť až finálnu verziu. PR redizajnu sa zlučujú po nezávislom review + zelenom CI; na konci jedna stránka pred/po (svetlý aj tmavý) celej appky. Produktové otázky sa kladú počas práce.
- Fáza C beží v dvoch paralelných linkách (jedno PR na skupinu): kvíz C2 → C3 → C4 → C5 (+ B3 pohyb) na simulátore iPhone 18 Pro; ostatné C1, C6, C7, C8, C9 na iPhone 17e. Kvízová linka vlastní zdieľané kvízové komponenty a tlačidlá, druhá linka len svoje obrazovky.
- Po fáze C: D2 logo v appke, B4 republikovanie katalógu, E1 plná sada testov + RS-01 až RS-21, potom finálne pred/po pre foundera.

### C. Obrazovky (jedno PR na skupinu, obrázky pred a po na schválenie)
- [x] C1 (#310) — Domov: plán vo všetkých 5 variantoch, moje balíčky (rozohrané kolo vynechané z 1.1, founder 2026-10-09).
- [x] C2 (#316, #329) — Otázka: všetky fázy počúvania, MCQ, písaná odpoveď, čakanie na otázku z balíčka, chybový banner, obrázková otázka.
- [x] C3 (#317) — Potvrdenie odpovede (sklenený sheet, tri vetvy).
- [x] C4 (#322) — Výsledok: správne, nesprávne, preskočené, neurčité; hodnotenie otázky.
- [x] C5 (#333) — Koniec kola a prehľad odpovedí na jednej obrazovke; hlavné „Hraj znova“, „Prehraj súhrn“ pri zozname (founder 2026-10-10).
- [x] C6 (#311) — Predplatné: online, offline, nákup, úspech, odpočet obnovy.
- [x] C7 (#312) — Úvod (4 strany), mikrofón, zamietnutý mikrofón, prihlásenie.
- [x] C8 (#314) — Nastavenia, moje balíčky (+ „Vytvor balík“), objednávka balíčka (+ náhľad témy), spätná väzba.
- [x] C9 (#315) — Chybová obrazovka a offline.

### D. Značka
- [x] D1 (#309) — ikona appky z loga 2 cez Icon Composer (Default, Dark, Tinted, Clear); vrstvy SVG, lebo actool PDF vrstvy z ikony vypustí (pravidlo PDF platí pre `.xcassets`).
- [x] D2 — logo (otáznik s vlnou kariet) a nápis „trubbo“ v Rethink Sans ExtraBold v appke; ikonu appky prerobil #319.

### E. Overenie
- [ ] E1 — plná sada `HangsTests` + RS-01 až RS-21 na simulátore iOS 27.
- [ ] E2 — interný TestFlight build z `main` na požiadanie foundera, test v aute.

**Rozsah:** približne 15 až 20 PR (A ~3, B ~4, C 9, D 1–2, E 1).

## Tok návrhu

Plátno je návrh, kód je pravda. Founder komentuje priamo na plátne; agent pred každým PR fázy C prečíta komentáre k dotknutým obrazovkám. Rozdiel medzi plátnom a appkou rieši PR, nikdy ručná úprava katalógu.

## Rozhodnutia foundera, 2. kolo (2026-10-08)

- **Tmavý režim áno:** Bg dostane tmavú verziu (kreslí sa na plátne po kontrole návrhov voči appke).
- **Farby kategórií** (6 kategórií z taxonómie `CATEGORY_TAXONOMY`): geography-world kobaltová #2C45F5 (biely text), history mandarínková #FF6B2C (tmavý text), science-nature mätová #3FE0AE (tmavý), movies-music ružová #E8317F (biely), sports žltá #FFD23F (tmavý), food-everyday fialová #7A5CFF (biely); vlastné balíčky atrament #111216 (biely); mix / všetky = viacfarebný pruh.
- **Kontrola návrhov voči appke** pred začiatkom kódu: každá obrazovka na plátne obsahuje všetko, čo appka dnes ukazuje, a nič vymyslené bez schválenia.

## Rozhodnutia foundera, 3. kolo (2026-10-08)

- **Obsah má prednosť** pred dekoráciou: obrazovka nikdy nedá obsahu menej miesta než dnešná beta (napr. MCQ možnosti kompaktné, odpovede sú krátke).
- **Jednoduchšie a decentnejšie:** základ vzhľadu je verzia upravená skillmi jakubkrehel/skills (5 veľkostí písma, 3 hrúbky, jedna plná akcia na obrazovku, jemné obrysy namiesto tieňov, kontrast ≥ 4,5 : 1). Skilly better-colors a better-ui slúžia ako kontrolný zoznam pri každom PR fázy B a C.
- **Menej animácií:** pohyb len tam, kde nesie význam (stav počúvania, odpočet, príchod karty), žiadne slučkové dekorácie.
- **Kritické miesta bety sa nesmú rozbiť:** záväzný zoznam [redesign-194-critical-spots.md](../design/redesign-194-critical-spots.md). Napr. na výsledku ostávajú obe pauzy (founder 2026-10-07).
- **Kategórií je 7:** k šiestim pribúda Zábava (`entertainment`, reálna kategória s otázkami); `CATEGORY_TAXONOMY` v `admin.py` je zastaraná (6 id).
- Referenčné obrazovky pre implementáciu = stránka „Finálny smer vs. beta“ na plátne (návrh vedľa snímky dnešnej bety).

## Rozhodnutia foundera, 4. kolo (2026-10-08)

- **Texty z bety sa nemenia** (sú vyladené); nový text len tam, kde nový prvok nemá v appke obdobu, a so schválením.
- **Povely ukazovať všade, kde fungujú** (vypínajú sa v Nastaveniach), aj na konci kola („znova“, „domov“).
- **Otázka ako v bete:** dole tri tlačidlá, hore pauza. **Výsledok ako v bete:** hore pauza, dole „Ďalej“ s odpočtom + „ZOSTAŇ“; pri nesprávnej odpovedi vidno **tvoju aj správnu** odpoveď.
- **Koniec kola spája skóre a zoznam odpovedí** (dnes `CompletionView` + `SetRecapView`) do jednej obrazovky.
- **Tlačidlo „Štart“ → „Odpovedz“** (cs „Odpověz“, en „Answer“) s ikonou mikrofónu; hlasový povel ostáva „štart“, „odpovedz“ ako synonymum až po teste v aute (všetky 3 jazyky naraz).
- **Spodný panel (tab bar) teraz nie;** nápad na neskôr: kvíz cez celú obrazovku bez panela.
- **Zábava = limetková #A3E635** (tmavý text).
- Tmavé hodnoty (návrh, stránka „Tmavý režim“): pozadie #0F1014, karty #1C1D23, vnútorné prvky #2A2C35, text #F2F3F5 / #A3A7B2, hlavné tlačidlo svetlé #F2F3F5; kategórie mierne stmavené (napr. ružová #D42A72, fialová #7052F5), aby biely text mal ≥ 4,5 : 1. Ružová a fialová potrebujú stmaviť aj vo svetlom režime.
