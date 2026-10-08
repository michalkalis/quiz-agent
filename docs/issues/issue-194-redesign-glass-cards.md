# #194 — Redizajn „Sklo nad kartami“ (verzia 1.1)

**Triage:** feature · planned
**Založené:** 2026-10-08 (founder: post-launch design refresh, „menej generický dizajn, animácie“; vybraný smer Bg)
**Návrhy:** plátno https://claude.ai/artifact/7F7N4oJSqyi4FZ3VVtcJpR (jediný zdroj návrhu pre tento redizajn)
**Research:** nástroje a trendy, 2026-10-08 (zhrnutie v sekcii Kontext)

## Rozhodnutia foundera (2026-10-08)

- Smer **Bg „Sklo nad kartami“** (svetlý): otázka je nepriehľadná karta vo farbe témy, Liquid Glass len na ovládacej vrstve (horná lišta, plávajúci spodný panel, ovládač „Počúvam“ ako doplnok panela, tlačidlá, sheety).
- **Písmo: systémové** (SF Pro). Anton, Inter a IBM Plex Mono z appky odchádzajú.
- **Logo: návrh 2 „Zvuková vlna z kariet“** (päť naklonených kariet vo farbách tém tvorí zvukovú vlnu).
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
6. **Beta je oddelená:** kým sa nezačne kód redizajnu, `release/1.0` = `main`. Prepnutie (posledný fast-forward, ruleset pre `release/**`, verzia 1.1 v `main`) je prvý krok fázy B.

## Fázy

### A. Príprava (vzhľad appky sa nemení; smie ísť aj do bety)
- [ ] A1 — logika von zo `SettingsView`, `QuestionView`, `PaywallView`, `ContentView` do view modelov alebo malých typov; testy na presunutú logiku.
- [ ] A2 — pixel snímky chýbajúcich obrazoviek (zoznam v poistke 3), sk/cs/en a veľké písmo ako pri hero snímkach.
- [ ] A3 — dokončiť plátno: kontrola voči appke, tmavý režim, farby kategórií, stavy, ktoré na plátne chýbajú (thinking n/total, prepis na potvrdení, MCQ výsledok, varianty plánu: grace, expired, freeWithCredits).

### B. Základy (prvý kód redizajnu, po prepnutí bety)
- [ ] B0 — prepnutie bety podľa `shared.md` (fast-forward, ruleset, `MARKETING_VERSION` 1.1).
- [ ] B1 — tokeny: paleta Bg (sivý podklad #E8EAEE, atrament #111216, farby kategórií), systémové písmo a typografická stupnica, rohy (sústredné), tiene; lint tokenov ostáva.
- [ ] B2 — komponenty: karta otázky, sklenený spodný panel s doplnkom „Počúvam“, sklenené tlačidlá a sheet, hlavné tlačidlo s odpočtom, pilulky postupu, nálepka odpovede.
- [ ] B3 — pohyb: rozdanie, otočenie, vejár, posun karty, lesk skla; haptika ku kľúčovým momentom; všetko vypnuté pri „Obmedziť pohyb“.
- [ ] B4 — katalóg (#188) pregenerovaný z nových tokenov a komponentov.

### C. Obrazovky (jedno PR na skupinu, obrázky pred a po na schválenie)
- [ ] C1 — Domov: plán vo všetkých 5 variantoch, moje balíčky, rozohrané kolo ako doplnok panela.
- [ ] C2 — Otázka: všetky fázy počúvania, MCQ, písaná odpoveď, čakanie na otázku z balíčka, chybový banner, obrázková otázka.
- [ ] C3 — Potvrdenie odpovede (sklenený sheet, tri vetvy).
- [ ] C4 — Výsledok: správne, nesprávne, preskočené, neurčité; hodnotenie otázky.
- [ ] C5 — Koniec kola a prehľad odpovedí.
- [ ] C6 — Predplatné: online, offline, nákup, úspech, odpočet obnovy.
- [ ] C7 — Úvod (4 strany), mikrofón, zamietnutý mikrofón, prihlásenie.
- [ ] C8 — Nastavenia, moje balíčky, objednávka balíčka (všetky stavy), spätná väzba.
- [ ] C9 — Chybová obrazovka a offline.

### D. Značka
- [ ] D1 — ikona appky z loga 2 cez Icon Composer (Default, Dark, Tinted, Clear), vektory ako PDF.
- [ ] D2 — logo a nápis v appke (úvod, hlavička domova).

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
