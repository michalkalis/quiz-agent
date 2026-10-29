# #212 — Hra spolu (multiplayer v jednej miestnosti)

**Triage:** enhancement · ready-for-agent
**Founder:** 2026-10-23 až 10-28 · rešerš [multiplayer-same-room-2026-10-23.md](../research/multiplayer-same-room-2026-10-23.md) · návrhy obrazoviek https://claude.ai/artifact/9FH1tX3o5TRtBnnyFzcUV7

## Cieľ

Jeden mobil hrá ako hostiteľ, ostatní sa pripoja so svojimi mobilmi s Trubbom. Všetci odpovedajú naraz, aj hostiteľ. Odpovede sa ukážu po každej otázke alebo po celom kole, na konci je poradie. Pripojenie bez písania kódov.

**Hotovo, keď:** hostiteľ a aspoň 3 hostia odohrajú celé kolo (otázky A až D aj voľné odpovede), hosť nájde hru sám v tej istej wifi alebo cez QR či odkaz, poradie sedí, odpovede každého hráča sú v jeho štatistikách, hostiteľ na konci vidí, kto počas otázky odišiel z appky, a meriame vznik hier, pripojenia hostí a nové inštalácie z hry spolu. Celé za prepínačom na serveri, kým founder nepovie inak.

## Rozhodnutia foundera

| Kedy | Rozhodnutie |
|---|---|
| 10-23 | Hostiteľ + hostia na vlastných mobiloch, všetci odpovedajú, odhalenie po otázke, poradie na konci. Offline netreba. |
| 10-28 | Vstup **A**: tlačidlo Spolu vedľa Štartu na záložke Hrať (lišta Hrať + Profil z #213 — player recap and Profile tab). |
| 10-28 | Pripojenie: hosť nájde hru **sám v tej istej wifi alebo cez Bluetooth**, ďalej priblíženie mobilov, QR, odkaz správou. |
| 10-28 | Odhalenie po otázke **alebo** po celom kole (voľba hostiteľa). |
| 10-28 | **Bez App Clipu.** Hostia si stiahnu appku. |
| 10-28 | **M1:** platí hostiteľ, každá otázka sa ráta raz do jeho limitu, bez výnimky na prvú hru. Hostia nikdy. Hra spolu nie je zvlášť platená, ide aj vo freemium. Poriadne merať (nábor nových hráčov). |
| 10-28 | Nielen A až D: aj **voľné odpovede**. Hostia píšu, čas len o pár sekúnd dlhší ako pri hlasovej odpovedi. |
| 10-28 | Hlas hostiteľa ostáva (číta nahlas, napr. cez BT reproduktor). Hostia hlas nemajú. Hlasové povely v hre spolu predvolene vypnuté. |
| 10-28 | Odchod z appky počas otázky (okrem hovoru) = podvádzanie, netrestá sa. Vidí ho **len hostiteľ, až na konci hry**. Druhé zariadenie nie je náš problém. |
| 10-28 | Hra spolu sa nehrá v aute. |
| 10-28 | Nastavenia v hre spolu sú iné ako solo. Umiestnenie rieši #213, zoznam a predvoľby tento plán. |

## Ako to funguje

**Miestnosť je quiz session na serveri** s `mode="multiplayer"` a zoznamom `participants` (modely už existujú, neaktívne). Hostiteľov mobil ju vedie ako dnes: berie otázky, číta ich nahlas, posúva kolo. Hostia sú účastníci s vlastným `subject_id`. Session žije v Postgres, takže to funguje aj na viacerých strojoch. Odpovedanie má však **vlastný tok miestnosti**: solo tok po odpovedi hneď vyhodnotí a posunie na ďalšiu otázku a pamätá si len jedno posledné vyhodnotenie. V miestnosti sa odpovede ukladajú za každého hráča a otázku, otázka sa uzavrie, vyhodnotí a až potom hostiteľ posunie ďalej.

**Stav naživo cez krátke dopytovanie.** Server dnes nemá WebSocket ani SSE. Každý mobil sa pýta na malý endpoint stavu miestnosti zhruba raz za sekundu, s číslom verzie (keď sa nič nezmenilo, odpoveď je prázdna). Je to najjednoduchšie, funguje to cez viac strojov bez ďalšej infraštruktúry a pri 10 hráčoch je to zanedbateľná záťaž. SSE neskôr, ak meranie ukáže oneskorenie.

**Pripojenie, v poradí dôležitosti:**
1. **Tá istá wifi, bez povolení:** server pozná verejnú IP adresu, z ktorej prišiel hostiteľ. Hosť na tej istej wifi má rovnakú IPv4 adresu, pri IPv6 má každý mobil vlastnú, ale rovnaký prefix /64 siete. Server sa preto pozerá na obe rodiny: IPv4 presne, IPv6 podľa /64 (Fly dáva appke IPv4 aj IPv6, [docs](https://fly.io/docs/networking/services/), a iOS pri dual stacku volí IPv6). Appka pri zakladaní aj hľadaní pošle jeden malý dopyt na adresu len s IPv4 a jeden len s IPv6, aby server poznal obe. Appka hosťa po ťuknutí na Spolu dostane zoznam otvorených miestností z jeho IP („Michalova hra“, farba, počet hráčov). Žiadne povolenie lokálnej siete, žiadny Bluetooth prompt. Ponúka sa len, keď je mobil na wifi (na mobilných dátach zdieľa IP veľa cudzích ľudí). Miestnosť v zozname len kým čaká na štart, najdlhšie 30 min.
2. **QR na hostiteľovom mobile + odkaz správou:** univerzálny odkaz s nevyhádnuteľným tokenom miestnosti. Kto appku nemá, skončí v App Store. Po inštalácii hry nájde cez bod 1 (sme v tej istej miestnosti), takže stratený odkaz pri inštalácii nevadí. Platí len na wifi: hosť na mobilných dátach po inštalácii naskenuje QR ešte raz (vedome prijaté, odložený odkaz nerobíme).
3. **Bluetooth a priblíženie mobilov:** až 212.6. Bluetooth aj miestna sieť pýtajú povolenie, ktoré ľudia často zamietnu. Bod 1 pokrýva ten istý prípad bez promptu. Founder to chce, preto ostáva v pláne, ale po overení, že bod 1 nestačí.

Hosť z verejného zoznamu sa pripojí hneď, hostiteľ ho vidí v miestnosti a vie ho jedným ťuknutím vyhodiť.

**Otázky.** Mix ako solo (A až D aj voľné). Otázky s obrázkom v hre spolu vypnuté (zobrazenie na viacerých mobiloch netreba v prvej verzii).

**Odpovede a čas.** Všetci ťukajú alebo píšu. Hostiteľ môže v nastaveniach zapnúť, že on odpovedá hlasom (predvolene vypnuté). Čas na odpoveď je spoločný a riadi ho server (začiatok otázky + limit), nie každý mobil zvlášť:
- A až D: čas na rozmyslenie + okno na začiatok reči ako dnes pri hlase (predvolene 10 + 5 s).
- Voľná odpoveď: to isté + čas hlasovej odpovede + 5 s navyše na písanie (predvolene ~28 s). Konštanty na serveri v `/app-config`, aby sa dali zmeniť bez buildu.
Otázka sa uzavrie, keď odpovedia všetci alebo uplynie čas. Server nemá vlastný časovač: uzavretie spraví prvý dopyt po termíne, pod zámkom session, a je opakovateľné bez následkov (druhý pokus nič nespraví). Mobily dostávajú zostávajúce milisekundy, nie čas, lebo hodiny mobilov sa rozchádzajú.

**Vyhodnotenie.** Po uzavretí otázky server vyhodnotí všetky odpovede existujúcim `AnswerEvaluator` (presná zhoda, alternatívy, A až D, zvuková a fonetická zhoda, potom model). Rovnaké odpovede (po normalizácii) sa vyhodnotia raz a zvyšné súbežne. Model sa volá len pre odlišné odpovede, ktoré nezachytí zhoda bez AI, najviac raz na hráča, v praxi menej. Nový spoločný prompt pre všetky odpovede nerobíme: dnešné hodnotenie je overené a písané odpovede už ním idú (cesta `/sessions/{id}/input`). Žiadna zmena modelu. Hosť bez odpovede = 0. Bod za správnu odpoveď, žiadne body za rýchlosť (rýchlosť len rozhoduje remízu).

**Odhalenie.** Podľa voľby hostiteľa po každej otázke (kto čo odpovedal, „Vedeli 2 zo 4.“) alebo po celom kole (súhrn otázok a odpovedí). Využije existujúce nastavenie `answerRevealMode`.

**Limit (M1).** Bez zmeny: otázka sa ráta do limitu hostiteľa vo chvíli, keď sa podá (`record_question` pri štarte a pri ďalšej otázke). Hostia nič. Keď hostiteľovi dôjde limit, hra končí rovnako ako solo (nikdy tvrdá stena uprostred, ponuka ako dnes).

**Štatistiky (dohoda s #213).** Každá odpoveď loguje `answer_evaluated` ako solo + `multiplayer=true` + `room_id`, pod `subject_id` hráča, ktorý odpovedal (aj hosťa). Poradie a výsledok hry ako nové udalosti.

**Odchod z appky.** Appka hosťa (aj hostiteľa) pošle serveru udalosť, keď počas otvorenej otázky prejde do pozadia. Neposiela ju, keď práve prebieha hovor (`CXCallObserver`, bez povolenia). Server ich zbiera k hráčovi a otázke. Na konci hry ich vidí len hostiteľ („Peťo odišiel z Trubba počas 2 otázok“). Body sa nemenia.

## API pre appku (dohodnuté, 212.1 + 212.2)

Všetko pod `/api/v1`, s prihlásením (anonymný `subject_id` stačí), mimo prepínača 404. Odpovede miestnosti vynechávajú prázdne polia.

| Kto | Volanie | Načo |
|---|---|---|
| hostiteľ, hosť | `GET /rooms/net-probe` na hostname len IPv4 a len IPv6 | lístky siete pre `net_tickets` (kým DNS mená nie sú, appka posiela prázdny zoznam, funguje podľa adresy dopytu) |
| hostiteľ | `POST /rooms` {session_id, host_name, net_tickets, reveal_mode `question`/`round`, thinking_seconds 3–60} | z jeho čakajúcej session spraví miestnosť → room_id, join_token (do QR a odkazu) |
| hosť | `POST /rooms/nearby` {net_tickets} | hry v tej istej wifi (meno hostiteľa, farba, počet) |
| hosť | `POST /rooms/join` {display_name, join_token alebo room_id, net_tickets} | pripojenie → stav |
| hostiteľ, hosť | `DELETE /rooms/{id}/players/{pid}` | hostiteľ vyhodí hosťa, hosť odíde |
| hostiteľ | `POST /sessions/{session_id}/start` (`?audio=true`) | štart ako solo, otázka a zvuk z `/sessions/{id}/question/audio` |
| hostiteľ | `POST /rooms/{id}/open` {question_id} | dočítal nahlas → štart času (opakované nič nemení; bez neho čas začne sám po 45 s) |
| všetci | `POST /rooms/{id}/answer` {question_id, answer} | kľúč možnosti (a–d) alebo napísaný text; raz, konečné; 409 = už odpovedal / čas vypršal |
| všetci | `POST /rooms/{id}/away` {question_id} | appka išla do pozadia počas otázky, nie počas hovoru (212.4) |
| hostiteľ | `POST /rooms/{id}/next` | ďalšia otázka pre všetkých alebo koniec; 409 kým sa odpovedá |
| všetci | `GET /rooms/{id}/state?since=<version>` cca raz za sekundu | `changed:false` = bez zmeny; inak status lobby/playing/finished, players, question (tvar ako solo), round, na konci ranking, rounds, away (len hostiteľ) |

`round.phase`: reading (hostiteľ číta, `remaining_ms` chýba) → answering (odpočet od `remaining_ms`, nie od hodín mobilu) → grading → revealed (`correct_answer`, `explanation`, `results`). `answered` = kto už odpovedal, čo odpovedal je skryté do odhalenia. Pri `reveal_mode=round` appka výsledky otázok ukáže až na konci z `rounds`. `finished_reason`: max_questions / usage_limit (hostiteľovi došiel limit, ponuka ako solo) / no_more_questions. Čas: A až D = thinking + 5 s, voľná = thinking + 18 s, 2 s tolerancia na doručenie.

## Nastavenia v hre spolu

Umiestnenie (Profil + rýchle nastavenia z Home a z kvízu) rieši #213. Tento plán určuje, čo platí:

| Nastavenie | Hostiteľ v hre spolu | Hosť |
|---|---|---|
| Jazyk, kategórie, obťažnosť, lokálne otázky, počet otázok | jeho voľba, platí pre všetkých | nevidí |
| Odhalenie (po otázke / po kole) | jeho voľba | nevidí |
| Čítať otázky nahlas | zapnuté | vždy bez hlasu |
| Odpovedať hlasom | **vypnuté** (dá sa zapnúť) | nie |
| Hlasové povely | **vypnuté** | nie |
| Čas na rozmyslenie | jeho voľba, platí pre všetkých | nevidí |
| Automatický posun ďalej | jeho voľba | nevidí |
| Otázky s obrázkom | vypnuté, nedá sa zapnúť | nevidí |
| Stlmenie, zvuky | vlastné | vlastné |

Solo nastavenia sa hrou spolu nemenia (samostatná sada hodnôt).

## Hranice

- API len pridáva: nové endpointy miestnosti, nové voliteľné polia. Staré buildy bez zmeny. Prepínač `multiplayer_enabled` v `/app-config`, predvolene vypnutý.
- Žiadne nové povolenia v prvej verzii (miestna sieť, Bluetooth až 212.6).
- Žiadna zmena hodnotiaceho modelu ani kvality otázok.
- Hosť nemusí mať účet, stačí anonymný `subject_id`, ktorý appka má.
- Token miestnosti nevyhádnuteľný, zoznam z rovnakej IP ukazuje len meno hostiteľa a počet hráčov, nie odpovede.
- Do 8 hráčov v prvej verzii.

## Úlohy

Poradie: 212.1 → 212.2 a 212.3 súbežne (dohodnuté API) → 212.4 → 212.5. 212.6 až po meraní.

- [x] **212.1 Miestnosť na serveri** (kód 2026-10-28, za prepínačom; spoločný čas otázky presunutý do 212.2, lebo patrí k toku otázky; open pred 212.3: DNS mená pre sondy, len A záznam na zdieľanú IPv4 Fly 66.241.124.50 a len AAAA na IPv6 appky, + `flyctl certs add`) — založenie miestnosti z hostiteľovej session, token, pripojenie cez token, zoznam čakajúcich miestností z rovnakej IP (len wifi, expirácia), vyhodenie hosťa, stav miestnosti s verziou, spoločný čas otázky. Autorizácia: hosť smie len svoje odpovede a čítať stav, riadiť smie len hostiteľ (#144 — session route authorization). Testy: pripojenie, cudzia IP, IPv6 s rovnakým /64 a iným rozhraním, hostiteľ na IPv4 a hosť na IPv6, expirácia, hosť nemôže posunúť otázku. Sondy IPv4/IPv6 = dva ďalšie hostnamy (len A záznam na zdieľanú IPv4 Fly, len AAAA na IPv6 appky), každý s certifikátom Fly (zdieľaná IPv4 sa smeruje podľa mena). Sieť len s IPv6 hľadá len podľa /64. Dopyt na stav miestnosti nikdy nečaká na zámok session (vráti posledný stav), aby ho nebrzdilo vyhodnocovanie. Zmazanie účtu hosťa ho z miestnosti len odoberie (dnes `forget_user` deaktivuje každú session, kde je jeho id, čo by ukončilo hostiteľovu hru).
- [x] **212.2 Odpovede a vyhodnotenie** (kód 2026-10-28, za prepínačom; časy ako nastavenia servera, appka dostáva len zostávajúce ms, preto nie v `/app-config`) — odpoveď účastníka (A až D aj text), uzavretie otázky (všetci / čas), vyhodnotenie existujúcim hodnotiteľom, rovnaké odpovede raz, súbežne, body, remíza podľa rýchlosti, odhalenie po otázke a po kole, poradie. Udalosti `answer_evaluated` pod hráčom + `multiplayer`, `room_id`. Test: limit sa ráta raz na otázku u hostiteľa, nikdy u hosťa; rovnaké odpovede = jedno volanie modelu; uzavretie po termíne dvakrát = jedno vyhodnotenie.
- [x] **212.3 Appka: hostiteľ a hosť** (kód 2026-10-28, PR #621, za prepínačom; RS-28/RS-29 + ostrá skúška 2 simulátory + 2 roboti, [správa](../testing/runs/2026-10-28-212-live/README.md); Associated Domains 2026-10-29, PR #624: schopnosť na App ID + nový App Store profil s tým istým certifikátom, lane `refresh_appstore_profile`; otvorenie odkazu na skutočnom telefóne overiť s najbližším TestFlight buildom) — tlačidlo Spolu (variant A), miestnosť hostiteľa s QR a zoznamom hráčov, hosť: zoznam hier z tej istej wifi + otvorenie univerzálneho odkazu, otázka, písanie voľnej odpovede, zamknutá odpoveď, odhalenie, poradie. Nastavenia hry spolu podľa tabuľky. Obrazovky z plátna, texty sk/cs/en cez copy review. Identifikátory, snímky, RS scenár s dvomi simulátormi.
- [x] **212.4 Odchod z appky** (server hotový s 212.2; appka v PR #621: hlási len otvorenú nezodpovedanú otázku, nie počas hovoru; súhrn na konci hry vidí len hostiteľ) — appka: prechod do pozadia počas otvorenej otázky, okrem hovoru; server: záznam k hráčovi a otázke; hostiteľ na konci hry vidí súhrn. Test: hovor sa nepočíta, zamknutie mobilu áno.
- [~] **212.5 Meranie** (kód 2026-10-29: `room_created`, `room_joined` s `via` nearby/qr/link, `room_finished`; QR odkaz nesie `#qr`; nový hráč a neskoršia solo hra sa rátajú dotazom, recept v `docs/product/analytics-events.md`; ostáva vyhodnotenie 4 týždne po zapnutí prepínača) — udalosti: miestnosť založená, hosť pripojený (cesta: wifi / QR / odkaz), hra dohraná, hosť nový hráč (prvé spustenie appky do 24 h od pripojenia cez odkaz alebo wifi), neskoršia solo hra hosťa. Vyhodnotenie po 4 týždňoch od zapnutia.
- [ ] **212.6 Bluetooth a priblíženie mobilov** — len ak 212.5 ukáže, že hostia sa nevedia pripojiť (veľa hier bez hostí, veľa pripojení cez odkaz). SharePlay cez priblíženie (iOS 17+) alebo Bluetooth hľadanie, s povolením.

## Otvorené

- `/design-soundness` 2026-10-28: SOUND 0,85 po jednej oprave (IPv6, vlastný tok miestnosti, uzavretie otázky, existujúci hodnotiteľ).
- Zásady ochrany súkromia: veta o tom, že hostiteľ vidí meno a odpovede hostí a že server pri hľadaní hier porovnáva IP adresu.
- Firemná sieť alebo hotelová wifi: veľa ľudí na jednej IP, v zozname môžu byť cudzie hry. Riešenie v prvej verzii: zoznam ukazuje len miestnosti založené za posledných 30 min a meno hostiteľa, hosť vyberá sám.
