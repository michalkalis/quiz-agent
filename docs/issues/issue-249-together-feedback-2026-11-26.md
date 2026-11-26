# #249 — Hra spolu a zdieľanie: poznámky z testu 2026-11-26

**Triage:** enhancement · in-progress (rozhodnuté body sa robia, zvyšok čaká na founderove odpovede)
**Founder:** 2026-11-26, test hry spolu + solo obrazoviek (TF 1.3) · stránka /decide session quiz-agent-cf
**Nadväzuje:** #212 — hra spolu v jednej miestnosti, #230 — hra spolu na diaľku, #232 — zdieľanie kvízu odkazom, #242 — extra kategórie, #205 — denná výzva

## Poznámky foundera (skrátene)

1. „Kategórie z Úvodu“ v okne „Čo hráme“ nie je pre bežného hráča jasné → výber kategórií priamo v okne, zvislý zoznam.
2. Čas na odpoveď v hre spolu je nevýrazný → ako v hre sám alebo pod otázkou; návrhy.
3. V hre spolu sa nedá dať pauza → má sa dať.
4. Hosť (najmä na diaľku) chce počuť otázky a vedieť si čítanie zapnúť/vypnúť.
5. Odpoveď hlasom v hre spolu znova otvoriť, so zapnutím/vypnutím; rozpísaná odpoveď sa pri konci času má odoslať sama.
6. Výber kategórií (mriežka) → jednoduchý zvislý zoznam; štítok „Nové do 22. 12.“ sporný.
7. Pri A až D je málo miesta, zbytočne veľká medzera medzi otázkou a možnosťami.
8. Bežný kvíz sa nedá zdieľať? (bolo ukončené skôr → zdieľanie zámerne chýba)
9. Zdieľanie dennej výzvy príde ako .txt → rešerš, čo posielať.

## Rozhodnuté (robí sa hneď)

- 1, 6 (zoznam), 7, 5b (rozpísaná odpoveď sa pri konci času odošle; server má 2 s rezervu).

## Čaká na foundera (stránka /decide)

`timer` (2), `pause` (3, kto), `guest_audio` (4, predvolené), `voice` (5), `new_badge` (6), `share_daily` (9), `share_early` (8).

## Zistenia

- Čas v hre spolu riadi server (koniec = začiatok + čas na rozmyslenie + navyše); pauza dnes len po odhalení (hostiteľ, „Zostaň“).
- Hosť: čítanie predvolene zapnuté pri odkaze, vypnuté pri QR/wifi; prepína ho len ikonka na karte otázky.
- Hlas v hre spolu nie je postavený (nastavenie hostiteľa existuje len v modeli, nikde sa nepoužíva).
- Denná výzva zdieľa obyčajný text (✅❌ + odkaz) s náhľadom odkazu; .txt robí prijímajúca appka. Rešerš: text + samostatný odkaz s obrázkom so skóre (Open Graph), obrázok ako druhá možnosť pre Stories.

## Kroky

| # | Čo | Stav |
|---|---|---|
| 249.1 | Výber kategórií: zvislý zoznam (solo) + priamo v okne „Čo hráme“ | [ ] |
| 249.2 | A až D: menšia medzera otázka ↔ možnosti | [ ] |
| 249.3 | Hra spolu: rozpísaná odpoveď sa pošle pri konci času | [ ] |
| 249.4 | Podľa odpovedí: čas (2), pauza (3), čítanie u hosťa (4), hlas (5), zdieľanie (8, 9) | [ ] |
