# #188 — Jednotný design systém: jeden zdroj pravdy, katalóg na claude.ai, synchronizácia do appky

**Triage:** enhancement · needs-triage (founder 2026-09-25: založiť issue; nič kritické teraz nemeniť)
**Status:** Smer schválený founderom 2026-09-25 (katalóg na claude.ai, Pencil ostáva na tvorbu dizajnu, kód = zdroj pravdy). Čaká na zaradenie po #185 / #186.
**Research:** [mobile-design-workflow-2026-09-25](../research/mobile-design-workflow-2026-09-25.md)

## Problém

- V appke žijú tri paralelné sady tokenov (`Theme.*`, `Theme.Hangs.*`, fonty v `Font+Theme`) + „legacy aliasy“. Agent si vyberá náhodne → vzhľad sa rozchádza.
- Ručné hodnoty mimo tokenov: 59× veľkosť písma, 23× odsadenie, 9× systémová farba (recon 2026-09-25). Nič to nevynucuje; pravidlá v `ios-swiftui-layout.md` nie sú ani commitnuté.
- Founder nemá jedno miesto, kde vidí „toto je náš vizuál“ a kde môže komentovať alebo navrhnúť zmenu bez terminálu.
- Zmena navrhnutá mimo kódu (Pencil, katalóg) sa dnes nemá ako spoľahlivo dostať do appky.

## Rozhodnutia (founder 2026-09-25)

| Téma | Rozhodnutie |
|---|---|
| Kde founder vidí a komentuje dizajn | Design System katalóg na claude.ai (artefakt), nie Figma |
| Kde vzniká nový dizajn | Pencil (pen.dev) ostáva |
| Zdroj pravdy | Kód (tokeny + komponenty v SwiftUI) — návrh nižšie |
| Mobbin | Zvážiť neskôr, teraz nie (útrata) |
| Načasovanie | Nič kritické teraz nemeniť; zaradiť po #185 / #186 |

## Zdroj pravdy a tok zmien (návrh)

**Pravidlo: čo je v kóde, to platí. Všetko ostatné je buď pohľad na kód, alebo návrh zmeny.**

| Miesto | Rola | Smer |
|---|---|---|
| **Kód** (jeden súbor tokenov + komponenty) | pravda o tom, čo je v appke | → generuje katalóg aj Pencil premenné |
| **Pencil** | skicár: nové obrazovky, väčšie zmeny | návrh → PR do kódu |
| **Katalóg na claude.ai** | okno do kódu + schránka zmien (komentáre, úprava hodnoty tokenu) | návrh → PR do kódu |

Tok jednej zmeny:
1. Founder zmení hodnotu alebo napíše komentár v katalógu (alebo agent nakreslí návrh v Penciliu).
2. Tým vzniká **čakajúca zmena**: katalóg ≠ kód. Katalóg ju zobrazuje v sekcii „Čaká na appku“, aby bolo jasné, že v appke ešte nie je.
3. Synchronizácia (`/design-sync`, track E) porovná katalóg a Pencil s kódom, vypíše rozdiely a nevyriešené komentáre a urobí z nich jeden PR do appky.
4. Po merge sa katalóg pregeneruje z kódu, Pencil premenné sa zosynchronizujú, komentáre sa uzavrú odkazom na PR → všetky tri miesta sa znova zhodujú.

Kedy beží sync: na začiatku každej UI práce (pravidlo v `.claude/rules/ios.md`) a na požiadanie („synchronizuj dizajn“). Konflikt (katalóg aj kód sa zmenili) → agent sa pýta foundera, nikdy nevyberá sám.

Prečo kód: agent pracuje v kóde, CI ho vie kontrolovať (lint, snapshoty) a zmena sa dá zmerať pixelovým snapshotom. Katalóg aj Pencil sú na tom závislé, preto ich nemožno nechať viesť bez kontroly.

## Tracky

- [ ] **A — Jedna sada tokenov.** Zlúčiť do `Theme.Hangs` (interný namespace ostáva, viď CONTEXT.md), dve vrstvy (základné hodnoty → významové), zmazať staré `Theme.*` a paralelné fonty, commitnúť `ios-swiftui-layout.md` + `ios-swift-conventions.md`. **Vizuálne neutrálne:** existujúce pixelové snapshoty hero obrazoviek musia ostať identické.
- [ ] **B — Lint na ručné hodnoty v CI** (vzor `scripts/lint-a11y-ids.py`): farby, veľkosť písma, odsadenie, rohy mimo token súborov; výnimka len pomenovaná `Metrics` konštanta. Najprv prečistiť súčasné výskyty, potom zapnúť ako gate.
- [ ] **C — Súpis komponentov + snapshoty komponentov.** Každý zdieľaný komponent (dnes 14 + 4 štýly tlačidiel) so stavmi (normálny, stlačený, vypnutý, dlhý SK text, veľké písmo) ako pixelový snapshot, rovnaký runtime ako hero snapshoty. Súpis „kedy použiť ktorý komponent“ v pravidlách pre agenta.
- [ ] **D — Katalóg na claude.ai** (typ artefaktu Design System), generovaný skriptom z kódu: README (značka, tón, pravidlá použitia), tokeny v oboch témach, každý komponent s popisom a obrázkami zo snapshotov (reálne SwiftUI, nie web napodobenina). Nikdy ručne písaný.
- [ ] **E — `/design-sync` skill:** katalóg (hodnoty tokenov + komentáre) a Pencil premenné vs. kód → zoznam čakajúcich zmien → PR; po merge pregenerovať katalóg, uzavrieť komentáre odkazom, aktualizovať sekciu „Čaká na appku“. Pravidlo v `ios.md`: spustiť pred každou UI prácou.
- [ ] **F — Pencil premenné z tokenov** (cez Pencil MCP), aby nové návrhy v Penciliu začínali z hodnôt, ktoré naozaj platia.
- [ ] **G — Hĺbkový UX audit po obrazovkách** (nie povrchný zoznam): každá obrazovka proti checklistu z researchu (2 s pohľad, hlas nikdy nevyžaduje čítanie, zvuk do 3 s, sklo len na navigácii, mierna zlá odpoveď, SK/CS + veľké písmo), konkrétne nálezy so screenshotom → founder vyberá, čo robiť. Mobbin výskum vzorov až po launchi a so súhlasom (útrata).

Poradie: A → B → C → D → E → F; G nezávisle, kedykoľvek.

## Hotovo, keď

- V kóde je jedna sada tokenov, lint v CI je zelený a stráži ju.
- Katalóg na claude.ai ukazuje všetky tokeny a komponenty so skutočnými SwiftUI obrázkami a zhoduje sa s kódom.
- Founderova zmena v katalógu sa cez `/design-sync` dostane do PR a po merge katalóg ukazuje „Čaká na appku: 0“.
