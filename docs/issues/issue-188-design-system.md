# #188 — Jednotný design systém: jeden zdroj pravdy, katalóg na claude.ai, synchronizácia do appky

**Triage:** enhancement · in-progress (founder 2026-09-30: začať)
**Status:** Smer schválený founderom 2026-09-25 (katalóg na claude.ai, Pen ostáva na tvorbu dizajnu, kód = zdroj pravdy). Tracky A–G hotové (A–C 2026-09-30, D 2026-10-01, E + F 2026-10-05, G audit 2026-10-06); ďalej opravy G1–G14 z auditu a B2 (normalizácia zvyšku), obe len cez review pred/po (founder 2026-09-30).
**Research:** [mobile-design-workflow-2026-09-25](../research/mobile-design-workflow-2026-09-25.md)

## Problém

- V appke žijú tri paralelné sady tokenov (`Theme.*`, `Theme.Hangs.*`, fonty v `Font+Theme`) + „legacy aliasy“. Agent si vyberá náhodne → vzhľad sa rozchádza.
- Ručné hodnoty mimo tokenov: 59× veľkosť písma, 23× odsadenie, 9× systémová farba (recon 2026-09-25). Nič to nevynucuje; pravidlá v `ios-swiftui-layout.md` nie sú ani commitnuté.
- Founder nemá jedno miesto, kde vidí „toto je náš vizuál“ a kde môže komentovať alebo navrhnúť zmenu bez terminálu.
- Zmena navrhnutá mimo kódu (Pen, katalóg) sa dnes nemá ako spoľahlivo dostať do appky.

## Rozhodnutia (founder 2026-09-25)

| Téma | Rozhodnutie |
|---|---|
| Kde founder vidí a komentuje dizajn | Design System katalóg na claude.ai (artefakt), nie Figma |
| Kde vzniká nový dizajn | Pen (pen.dev) ostáva |
| Zdroj pravdy | Kód (tokeny + komponenty v SwiftUI) — návrh nižšie |
| Mobbin | Zvážiť neskôr, teraz nie (útrata) |
| Načasovanie | Nič kritické teraz nemeniť; zaradiť po #185 / #186 |

## Zdroj pravdy a tok zmien (návrh)

**Pravidlo: čo je v kóde, to platí. Všetko ostatné je buď pohľad na kód, alebo návrh zmeny.**

| Miesto | Rola | Smer |
|---|---|---|
| **Kód** (jeden súbor tokenov + komponenty) | pravda o tom, čo je v appke | → generuje katalóg aj Pen premenné |
| **Pen** | skicár: nové obrazovky, väčšie zmeny | návrh → PR do kódu |
| **Katalóg na claude.ai** | okno do kódu + schránka zmien (komentáre, úprava hodnoty tokenu) | návrh → PR do kódu |

Tok jednej zmeny:
1. Founder zmení hodnotu alebo napíše komentár v katalógu (alebo agent nakreslí návrh v Pen).
2. Tým vzniká **čakajúca zmena**: katalóg ≠ kód. Katalóg ju zobrazuje v sekcii „Čaká na appku“, aby bolo jasné, že v appke ešte nie je.
3. Synchronizácia (`/design-sync`, track E) porovná katalóg a Pen s kódom, vypíše rozdiely a nevyriešené komentáre a urobí z nich jeden PR do appky.
4. Po merge sa katalóg pregeneruje z kódu, Pen premenné sa zosynchronizujú, komentáre sa uzavrú odkazom na PR → všetky tri miesta sa znova zhodujú.

Kedy beží sync: na začiatku každej UI práce (pravidlo v `.claude/rules/ios.md`) a na požiadanie („synchronizuj dizajn“). Konflikt (katalóg aj kód sa zmenili) → agent sa pýta foundera, nikdy nevyberá sám.

Prečo kód: agent pracuje v kóde, CI ho vie kontrolovať (lint, snapshoty) a zmena sa dá zmerať pixelovým snapshotom. Katalóg aj Pen sú na tom závislé, preto ich nemožno nechať viesť bez kontroly.

## Tracky

- [x] **A — Jedna sada tokenov.** Zlúčiť do `Theme.Hangs` (interný namespace ostáva, viď CONTEXT.md), dve vrstvy (základné hodnoty → významové), zmazať staré `Theme.*` a paralelné fonty, commitnúť `ios-swiftui-layout.md` + `ios-swift-conventions.md`. **Vizuálne neutrálne:** existujúce pixelové snapshoty hero obrazoviek musia ostať identické. — **Hotové 2026-09-30:** jediný súbor `Utilities/Theme.swift` (súkromná `Palette` → významové `Colors`/`Shadow`/`Spacing`/`Radius`/`Fonts`); zmazané `Theme.*`, `Font+Theme`, nepoužité `ButtonStyles` (4 štýly, nikde nepoužité) a legacy aliasy + nepoužité farby; výber mikrofónu a mini-kvíz prevedené (rozmery → `Metrics` vo view). Hero pixelové snapshoty identické (iOS 26.5). Pozn. pre G: výber mikrofónu ostáva na systémovom písme (SF), nie Inter.
- [x] **B — Lint na ručné hodnoty v CI** (vzor `scripts/lint-a11y-ids.py`): farby, veľkosť písma, odsadenie, rohy mimo token súborov; výnimka len pomenovaná `Metrics` konštanta. Najprv prečistiť súčasné výskyty, potom zapnúť ako gate. — **Hotové 2026-09-30:** `scripts/lint-design-tokens.py` v iOS CI. Súpis našiel 601 ručných hodnôt (nie ~90 z pôvodného reconu). Founder 2026-09-30 zvolil postupný prechod: 204 odstupov zhodných so sadou + biela na akcente → tokeny (bez zmeny vzhľadu, hero snapshoty identické); zvyšných 386 (138 odstupov mimo stupnice, 228 veľkostí písma, 16 rohov, 4 čierne) je v `scripts/design-token-baseline.txt`, ktorý smie len klesať — nové ručné hodnoty CI hneď zablokuje.
- [ ] **B2 — Normalizácia zvyšku (founder schvaľuje pred/po):** odstupy mimo stupnice zaokrúhliť na tokeny, stupnica písma (~6 pomenovaných veľkostí namiesto ~20), rohy a scrim tokeny; po obrazovkách so screenshotmi pred/po, spolu s G; každá dávka zmenší baseline.
- [x] **C — Súpis komponentov + snapshoty komponentov.** Každý zdieľaný komponent (dnes 14; 4 staré štýly tlačidiel zmazané v A) so stavmi (normálny, stlačený, vypnutý, dlhý SK text, veľké písmo) ako pixelový snapshot, rovnaký runtime ako hero snapshoty. Súpis „kedy použiť ktorý komponent“ v pravidlách pre agenta. — **Hotové 2026-09-30:** `ComponentSnapshotTests` + vzorky v `ComponentSamples+Controls/+Quiz.swift`: 72 stavov 35 používaných komponentov × (tmavý, svetlý, tmavý s veľkým písmom) = 216 snímok (2,1 MB), dva behy po nahratí zhodné. Súpis „kedy ktorý komponent“ = `.claude/rules/ios-components.md`. Mimo: stlačený stav (SwiftUI ho mimo dotyku nevie vynútiť), otvorené menu, animované hlasové žiary. 10 komponentov sa nikde nepoužíva (zoznam v ios-components.md) → kandidáti na zmazanie, samostatný malý PR. Pozn. pre G: dlhý text na hlavnom tlačidle sa pri najväčšom písme oreže „…“ (pri bežnom sa zmenší a zmestí).
- [x] **D — Katalóg na claude.ai** (typ artefaktu Design System), generovaný skriptom z kódu: README (značka, tón, pravidlá použitia), tokeny v oboch témach, každý komponent s popisom a obrázkami zo snapshotov (reálne SwiftUI, nie web napodobenina). Nikdy ručne písaný. — **Hotové 2026-10-01:** katalóg https://claude.ai/artifact/RibRqy3ag5avMkoSNQkhkH (súkromný, typ Design System) generuje `python3 -m scripts.design_catalog.build --out <dir>` z `Theme.swift` (farby v oboch režimoch + base paleta, písma s TTF, odstupy, rohy, tiene, počty použití), z `ios-components.md` + zdrojov komponentov (parametre) a zo snapshotov C (35 komponentov, 72 stavov, svetlý/tmavý + veľké písmo), README + pravidlá textov z `copy-style.md`, obálka z tokenov; publikuje sa podľa `publish-plan.json` (2 dávky, index posledný). Komentáre v `Theme.swift` rozlíšené: `///` = popis tokenu, `// MARK:` = sekcia. Opakované generovanie zatiaľ ručne, automatika = E. 2026-10-05 oprava: komponenty sa v katalógu nenačítavali (stránka niekedy spúšťa náhľady bez prístupu k súborom katalógu) → snímky sú nahrané ako obrázky do úložiska katalógu (`/_blob/…`), mapa `snapshot-blobs.json` je v katalógu aj lokálne a nahrávajú sa len nové snímky. Skutočná príčina (overené na živej stránke): bez `components/bundle.js` stránka púšťa náhľady len v izolovanom režime, ktorý blokuje všetky obrázky → generátor zapisuje prázdny `bundle.js` s menami komponentov; náhľady bežia naplno a obrázky sa načítajú. Pozn. pre G: deštruktívne hlavné tlačidlo („End quiz“) sa od bežného líši len silnejším tieňom.
- [x] **E — `/design-sync` skill:** katalóg (hodnoty tokenov + komentáre) a Pen premenné vs. kód → zoznam čakajúcich zmien → PR; po merge pregenerovať katalóg, uzavrieť komentáre odkazom, aktualizovať sekciu „Čaká na appku“. Pravidlo v `ios.md`: spustiť pred každou UI prácou. — **Hotové 2026-10-05:** `.claude/skills/design-sync/SKILL.md` + `scripts/design_catalog/sync.py` (trojcestné porovnanie: commit, z ktorého bol katalóg vygenerovaný × živý katalóg × kód → návrh / zmena v kóde / konflikt; konflikt vždy rozhoduje founder). Nerozhodnuté návrhy ostávajú v katalógu a sekcia *Waiting for the app* ich vypisuje. Zmena vzhľadu ide len cez schválenie pred/po. CI overí, že sa katalóg dá z kódu postaviť (`build --check` + testy pravidiel). Pravidlo v `ios.md`.
- [x] **F — Pen premenné z tokenov** (cez Pen MCP), aby nové návrhy v Pen začínali z hodnôt, ktoré naozaj platia. — **Hotové 2026-10-05:** `design/quiz-agent.pen` má premenné s menami a hodnotami z kódu: 27 farieb (svetlý + tmavý), 7 odstupov, 7 rohov, 14 štýlov písma (veľkosť + hrúbka), 3 rodiny písma a `tokens-ref` (commit, z ktorého sú hodnoty). Staré mená, ktoré návrhy používajú (`bg-page`, `text-primary`…), sú odkazy na token z kódu, takže návrhy sa držia appky; odstupy v Pen mali mená posunuté o stupeň (`space-md` = 12), 4 riadky balíčkov previazané na token s rovnakou hodnotou. Founder 2026-10-05 schválil: `bg-elevated` → `bgSheet` (tmavý panel ako v appke), `warning-bg` = warning na 12 % ako v appke (Pen pomôcka, token zatiaľ nie je → B2), zmazaných 23 nepoužitých premenných. Overené: zápis zmenil vzhľad len schváleného upozornenia; čítanie z Pen + `sync --pen` = „pen and code agree“. Mimo Pen: tiene (premenná ich neunesie) a súkromná paleta. `/design-sync` číta Pen (`sync --pen`, rovnaké pravidlá návrh / zmena v kóde / konflikt) a zapisuje ho z kódu (`python3 -m scripts.design_catalog.pen`); mapovanie v `scripts/design_catalog/pen.py`, testy pravidiel v `test_sync.py`.
- [x] **G — Hĺbkový UX audit po obrazovkách** (nie povrchný zoznam): každá obrazovka proti checklistu z researchu (2 s pohľad, hlas nikdy nevyžaduje čítanie, zvuk do 3 s, sklo len na navigácii, mierna zlá odpoveď, SK/CS + veľké písmo), konkrétne nálezy so screenshotom → founder vyberá, čo robiť. Mobbin výskum vzorov až po launchi a so súhlasom (útrata). — **Hotové 2026-10-06:** 17 obrazoviek × 7 kombinácií (sk/cs, svetlý/tmavý, veľké a najväčšie písmo) na iPhone 17 Pro Max iOS 26.5 + zvuk a hlas z kódu → 28 nálezov (2 kritické, 13 dôležitých, 13 drobných), stránka so screenshotmi https://claude.ai/artifact/4cyhcnGntf8hZQddK3pJqg. Founder vybral → úlohy G1–G14 nižšie.

### G — vybrané opravy (founder 2026-10-06)

Pravidlo pre celý zoznam: **radšej menej zvukovej odozvy ako priveľa.** Nepridávať zvuky pre stavy (spracovanie, čakanie); ak nejaký zvuk, tak veľmi minimalistický. Zmena vzhľadu len cez schválenie pred/po (B2), každá úloha cez PR. Kódy v zátvorke = nález na stránke auditu.

- [x] **G1 (K1)** Obrazovka chyby: krátka hlasová veta + povely „znova“ / „stop“ (sk/cs/en naraz); bez earconu.
- [x] **G2 (K2)** Paywall uprostred kvízu: pred otvorením jedna krátka hlasová veta, žiadny ďalší zvuk (founder: zvuková odozva tu nie je veľmi potrebná → len veta).
- [x] **G3 (D3)** Koniec setu (režim po každej otázke): krátko vysloviť skóre („Hotovo, 7 z 10“) + povely „znova“ / „domov“.
- [x] **G4 (D4+D5)** „Vypočuj si“ prečíta vysvetlenie (dnes prehrá znova verdikt); pri preskočení vysloviť správnu odpoveď.
- [x] **G5 (M4)** Zlá odpoveď a preskočenie: jemný ťuk namiesto chybovej vibrácie.
- [x] **G6 (M10)** Tiché úseky (10 s premýšľania, ticho pred ďalšou otázkou): žiadny nový zvuk (hlas ďalšej otázky a povel „štart“ ich už pokrývajú); founder ponechal len tón „mikrofón zapnutý“, ostatné signály (začiatok reči, prijaté, povel, preskočenie) sú len vibrácia.
- [ ] **G7 (M12)** Mikrofón pýtať v onboardingu aj pri prvej otázke, ak ešte nie je povolený.
- [ ] **G8 (D1)** Text otázky vždy plným kontrastom (dnes ho stlmí vypnuté tlačidlo „prehraj znova“); stlmiť len ikonku.
- [ ] **G9 (D7–D11)** Veľké písmo: **horný limit veľkosti písma** (hlavne kvíz; možnosti MCQ nesmú zakryť zvyšok obrazovky), hero nadpisy na jeden riadok so zmenšením, hodnoty v riadkoch pod názov namiesto delenia slova, jedna horná lišta pre otázku aj výsledok (počítadlo sa neprekrýva), tlačidlá bez „…“ (aj podnet z C).
- [ ] **G10 (D12)** Zrušiť mini-kvíz (zmenšenú verziu kvízovej obrazovky).
- [ ] **G11 (D13+M8)** Stav „čítam / premýšľaj“ čitateľný na pohľad (ako „Počúvam…“); odpočet a „Spracúvam…“ len na jednom mieste.
- [ ] **G12 (M3+M7)** Farby: jedna farba nadpisov sekcií, jedna farba hodnôt, ružová len hlavná akcia; výber mikrofónu na písmo a farby appky.
- [ ] **G13 (M1+M2)** Deštruktívny variant hlavného tlačidla zmazať (nepoužíva sa) alebo mu dať odlišný vzhľad; logo: pribaliť polotučný mono rez alebo prepnúť na stredný.
- [ ] **G14 (M5, M6, M9, M13)** Kontrast „PRESKOČENÉ“ v svetlom režime; stav balíka všade „Pripravuje sa“ / „Připravuje se“; čitateľné vypnuté „Pokračuj“ v svetlom režime; čísla na konci setu (úspešnosť vs „z 10“, neutrálna nula, text podľa skóre).

Zamietnuté: **D2** (zvuk pri spracovaní a čakaní: „skôr otravuje“), **D6** (povely pauza / stop / ukonči kvíz), **M11** (písaná odpoveď sa nevyslovuje; necítiť vibrácie v aute je v poriadku).

Poradie: A → B → C → D → E → F; G nezávisle, kedykoľvek. Malý PR navyše: zmazať 10 nepoužitých komponentov (zoznam v `ios-components.md`).

## Hotovo, keď

- V kóde je jedna sada tokenov, lint v CI je zelený a stráži ju.
- Katalóg na claude.ai ukazuje všetky tokeny a komponenty so skutočnými SwiftUI obrázkami a zhoduje sa s kódom.
- Founderova zmena v katalógu sa cez `/design-sync` dostane do PR a po merge katalóg ukazuje „Čaká na appku: 0“.
