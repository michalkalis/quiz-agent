# #230 — Hra spolu na diaľku (cez internet)

**Triage:** enhancement · ready-for-agent
**Founder:** 2026-11-07 · nadväzuje na [#212 — Hra spolu](issue-212-multiplayer-same-room.md)

## Cieľ

Hra spolu funguje aj s hráčmi v inom meste (napr. brat). Hosť sa pripojí odkazom poslaným správou, jeho mobil mu otázku prečíta nahlas sám, rozprávate sa cez vlastný hovor (WhatsApp, FaceTime).

**Hotovo, keď:** hosť pripojený odkazom z inej siete počuje každú otázku zo svojho mobilu, hosť v tej istej miestnosti (wifi zoznam, QR) predvolene nie (nech sa mobily neozývajú naraz), hosť si to vie jedným ťuknutím prepnúť, hostiteľova miestnosť jasne hovorí, že odkaz funguje aj do iného mesta, a bežiaci hovor nikoho nevyhodnotí ako odchod z appky. Staré buildy bez zmeny.

## Rozhodnutia foundera (2026-11-07)

| Otázka | Voľba |
|---|---|
| Ako hosť na diaľku dostane otázku | **Číta každý mobil sám** (hosťov mobil prečíta otázku nahlas) |
| Rozhovor počas hry | **Vlastný hovor mimo appky**; bežiaci hovor sa neráta ako odchod z appky |
| Pozvanie | **Tá istá hra**, žiadny nový režim; v miestnosti výraznejšie „Pošli odkaz“ aj do iného mesta; hostia na diaľku a v miestnosti v jednej hre |

## Čo už funguje (overené v kóde 2026-11-07)

- Pripojenie odkazom nekontroluje sieť, server vedie celú hru → cez internet to ide už dnes.
- Odchod z appky počas akéhokoľvek hovoru (mobilný, FaceTime, WhatsApp cez CallKit) sa nehlási.
- Hosť vidí text otázky; zvuk otázky server dnes púšťa len vlastníkovi session (hostiteľovi).

## Návrh

**Server (230.1).** Hosť smie stiahnuť zvuk aktuálnej otázky svojej miestnosti. Nový endpoint len pridáva, nič nemení: `GET /rooms/{room_id}/question/audio?question_id=…` pre člena miestnosti (hostiteľ aj hosť), len keď je to práve aktuálna otázka a kolo už beží (hosť text tej otázky aj tak vidí, zvuk neprezradí nič navyše). Rovnaký zvuk z cache, ako dostáva hostiteľ, takže hosť na diaľku nestojí nič navyše. Iná otázka ako aktuálna = 409, cudzí = 404 (#144 — session route authorization).

**Appka (230.2).**
- Hosť: prepínač „Čítať nahlas“ na obrazovke otázky (ikona reproduktora). Predvolene zapnutý pri pripojení odkazom, vypnutý pri pripojení zo zoznamu wifi alebo cez QR. Platí pre túto hru.
- Keď hosťov mobil uvidí novú otázku vo fáze čítania alebo odpovedania a čítanie má zapnuté, stiahne zvuk a prečíta ju raz. Vypnutie počas čítania zvuk zastaví.
- Hosť si nastaví zvuk len na prehrávanie, mixovateľný s inými appkami (bez mikrofónu), aby nikdy neprerušil bežiaci hovor.
- Hosťova karta: „Hostiteľ číta otázku“ len keď hosť sám nečíta; keď číta, karta ukazuje jeho čítanie.
- Hostiteľova miestnosť: pri tlačidle zdieľania krátky text, že odkaz funguje aj do iného mesta. Texty sk/cs/en cez copy review.
- Analytika: `room_guest_read_aloud` (zapnuté/vypnuté, cesta pripojenia) pri prepnutí; meranie, či sa hrá na diaľku, dá `room_joined` s `via=link`.

## Riziká a známe obmedzenia

- **Čas:** hostiteľov čas na odpoveď začína, keď dočíta jeho mobil. Hosť na diaľku začne čítať o ~1–2 s neskôr (dopyt na stav každú sekundu + stiahnutie). Pri predvolených 30 s prijateľné; ak to bude vadiť, server môže počkať na čítajúcich hostí.
- **Hovor na reproduktore:** otázka zaznie z oboch mobilov a cez hovor dvakrát. Overiť na zariadení; riešenie slúchadlá alebo vypnúť čítanie u jedného.
- **Zvuk počas hovoru WhatsApp/FaceTime** sa dá overiť len na skutočnom telefóne (simulátor hovor nemá) → test foundera s bratom na najbližšom TestFlight builde.

## Úlohy

- [x] **230.1 Server: zvuk otázky pre hosťa** (2026-11-07, PR #761, nasadené) — endpoint, testy (hosť dostane zvuk, cudzí 404, stará otázka 409, lobby 409), nasadenie.
- [x] **230.2 Appka: hosť číta nahlas + pozvanie na diaľku** — prepínač, predvolba podľa cesty pripojenia, prehrávanie bez prerušenia hovoru, texty, analytika, unit testy RoomViewModel, snímky.
- [ ] **230.3 Test na zariadení** — founder s niekým mimo domu (WhatsApp hovor + hra), s TestFlight buildom na požiadanie.
