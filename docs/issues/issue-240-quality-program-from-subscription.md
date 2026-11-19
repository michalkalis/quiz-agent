# #240 — Kvalita appky z voľnej kapacity predplatného

**Triage:** enhancement · in-progress
**Status:** 2026-11-19 ráno: všetky schválené zmeny z posudku (240.9) sú zlúčené, server nasadený, build do Trubbo Beta spustený z `5e7278c0`; audit: 23 z 24 nálezov vyriešených (ostáva nasadenie pri výpadku spojenia); ďalej 240.3, 240.5, 240.6, 240.7
**Číslo:** do 2026-11-18 viedla táto úloha číslo 239 (zhoda s #239 — Partia v dennej výzve); PR #868, #871–#874 ju tak ešte volajú.
**Founder:** 2026-11-18 „mám moc veľa kreditov voľných a nestíhame ich minúť… najlepšie niečo, čo by zvýšilo kvalitu appky… ale automatizovane“; „ElevenLabs ani kredity nechcem čerpať, ideálne len zo subscription. Prechody appkou ok, tj. dôkladné testovanie… možno aj UX review a podobne“

Podklad: [rešerš 2026-11-18](../research/claude-code-quality-from-subscription-2026-11-18.md) (čo ide z predplatného, čo funguje, čo je plytvanie).

## Rozhodnutia foundera (2026-11-18)

1. Všetko **len z predplatného Claude**. API kredit ani ElevenLabs nie.
2. Jediná výnimka: robot-hráč pre hlas smie **malé čerpanie ElevenLabs** na prepis odpovedí (rádovo 2 kredity na odpoveď; strop tejto úlohy 5 000 kreditov, viac len po novom súhlase).
3. Vybrané na začiatok: audit kódu kolo 2, prechody appkou, vzhľad a prístupnosť, použiteľnosť + bezpečnosť.
4. Týždenné príspevky (#210 — marketing na sociálnych sieťach) pokračujú ako doteraz, bez nového hlasu z ElevenLabs.

## Pravidlá pre všetky časti

- Výstup sú **len potvrdené nálezy**: každý nález musí prežiť druhého agenta, ktorý ho má vyvrátiť; pri chybe v kóde je dôkazom test, ktorý bez opravy zlyhá. Zhoda agentov dôkazom nie je.
- Opravy idú bežnou cestou: vetva, PR, nezávislá kontrola. Rozhodnutia o správaní appky (UX, rozsah) idú founderovi, technické rieši agent.
- Žiadne plánované ani nočné behy; každé kolo sa púšťa na požiadanie.
- `/code-review ultra` sa nepoužíva (platí sa zvlášť).
- Simulátor: len existujúce zariadenia, Mac stlmený, iPhone 18 Pro pod zámkom, vlastný DerivedData na workera.
- Čo sa prekrýva s #238 — brány kvality otázok, sa tu nerobí.

## Časti

### 240.1 — Audit kódu, kolo 2
Od auditu 2026-07-30 pribudlo ~950 zmien, ktoré takým auditom neprešli. Hľadači po oblastiach, každý nález dostane skeptika.

Oblasti: Hra spolu (v miestnosti aj na diaľku) · zdieľanie kvízu odkazom · nákupy, predplatné, limity a tester strop · vlastné balíky (objednávka, worker, kontrola témy, opätovné použitie) · stavy kvízu a hlasová cesta v appke · denná výzva a profil · prihlásenie a účet · hlas na serveri a jeho cache · nasadenie a prevádzka na Hetzneri.

Hotové, keď: zoznam potvrdených nálezov podľa závažnosti je tu v časti Výsledky, kritické a vysoké sú opravené cez PR s testom, ostatné majú rozhodnutie (opraviť / nechať s dôvodom).

### 240.2 — Prieskumné prechody appkou
Agent prechádza appku na simulátore podľa zadaní s pomenovanými okrajovými prípadmi: prvé spustenie, kvíz hlasom aj ťukaním, MCQ, denná výzva, nákup a zlyhaný nákup, vlastný balík, Hra spolu, zdieľaný kvíz, profil, nastavenia; v sk/cs/en/uk; pomalá a vypadnutá sieť; odchod do pozadia a návrat.

Nález platí až po zopakovaní druhým agentom so snímkou a krokmi. Potvrdené chyby sa po oprave zmrazia do regresných scenárov (RS).

### 240.3 — Stráže vzhľadu a prístupnosti
Snímky obrazoviek doplniť o ukrajinčinu, malý telefón a najväčšie písmo; zabudovaný audit prístupnosti Xcode v UI testoch (kontrast, veľkosť cieľov, popisky, orezaný text); pseudojazyk s dvojnásobnou dĺžkou textu. Popisky pre čítačku obrazovky na hlavných obrazovkách.

### 240.4 — Prechod použiteľnosti po úlohách
Agent vykoná úlohy za nového hráča, rodinu a partiu a meria ťuknutia, čakanie a slepé uličky. Výstup: artefakt so snímkami a návrhmi na posúdenie founderom. Nič z toho sa nemení v appke bez jeho rozhodnutia.

### 240.5 — Bezpečnostný prechod
Jednorazový prechod servera aj appky (prihlásenie, platby, admin, odkazy na zdieľanie, limity) + bezplatné kontroly v CI (úniky tajomstiev, zraniteľné knižnice).

### 240.6 — Robot-hráč pre hlas
Odpovede a povely nahovorené hlasmi zabudovanými v Macu do súboru (bez zvuku nahlas), rôzne hlasy a tempo, s pridaným hlukom auta; pustené cez rozpoznávanie povelov aj prepis odpovedí. Výstup: podiel nepočutých podľa jazyka + sada, ktorá stráži zhoršenie. Nadväzuje na #197 — nahrávky z auta a #204 — spoľahlivejšie rozpoznanie odpovede.

### 240.7 — Preverenie testov úmyselnými chybami (neskôr)
Mutačné sondy na peniaze, limity, vyhodnotenie odpovedí a stavy kvízu; každá prežitá mutácia = nový test.

### 240.8 — Zábavnosť a chuť zdieľať
Founder 2026-11-18: „chcel by som, aby si skúsil posúdiť aj zábavnosť appky, či sú nejaké časti, čo nedávajú zmysel, prípadne sú dobré, čo by si upravil… či hra spolu bude zábavná pre ľudí, či bude lákať ju zdieľať.“

Posudok herného zážitku, nie hľadanie chýb: jadro hry (tempo, odmena, napätie, pestrosť), denná výzva, profil, vlastné balíky, Hra spolu (priebeh večera, čakanie, drámy, koniec) a všetky miesta, kde hráč môže niečo poslať ďalej (čo posiela, čo uvidí príjemca). Opiera sa o prechod appkou ako hráč, o skutočné čísla z prevádzky a z testov (dohrané kolá, návraty, vytvorené a otvorené odkazy, veľkosť a dĺžka hier spolu), o spätnú väzbu testerov a o to, čo funguje v kvízových a párty hrách (s citáciami). Rešerš upozorňuje, že úsudok modelu o zážitku je slabý dôkaz, preto je každý bod označený ako údaj alebo názor.

Výstup: artefakt so snímkami pre foundera: čo je dobré, čo nedáva zmysel, čo by som zmenil a prečo, zoradené podľa dopadu. V appke sa nič nemení bez jeho rozhodnutia. Robí sa spolu s 240.4.

## Výsledky

### 240.1 — Audit kódu, kolo 2 (2026-11-18, session quiz-agent-87)

38 agentov, 10 oblastí. 32 nálezov → 28 preverených skeptikom → **24 potvrdených** (6 zopakovaných skriptom, 18 stopou v kóde), 3 vyvrátené, 1 neistý, 4 nižšie zaradené nepreverené. Opravy idú cez PR s testom, ktorý bez opravy zlyhá.

| # | Závažnosť | Oblasť | Nález | Kde | Stav |
|---|---|---|---|---|---|
| 1 | vysoká | Hra spolu | Hra skončí 30 minút po otvorení miestnosti, bez poradia a bez chyby | `rooms/service.py:152` | PR #872 |
| 2 | vysoká | Účet | Zmazanie účtu a export údajov u prihláseného hráča účet nezmaže | `routes/auth.py:364` | PR #874 |
| 3 | vysoká | Účet | Po odhlásení sa na tom istom telefóne už nedá prihlásiť iným Apple ID | `usage/account_merge.py:60` | PR #878 (vlastný čistý účet, founder 11-18; obnova Plus podľa pravidla Applu prijatá) |
| 4 | vysoká | Prevádzka | Hlásenie o zlyhanom nasadení a postup nasadenia stále posielajú na Fly; nasledovanie by vrátilo starú appku na starej databáze | `backend-deploy.yml:239` | PR #873 |
| 5 | stredná | Hra spolu | Výpadok hodnotenia odpovede zasekne miestnosť a stratí odpoveď posledného hráča | `rooms/play.py:248` | PR #872 (pri trvajúcom výpadku sa otázka zruší všetkým, founder 11-18) |
| 6 | stredná | Zdieľaný kvíz | Jediné hranie zdieľaného balíka prepadne, keď štart zlyhá alebo ho hráč zruší (spolu s nálezom 22) | `shared_quiz/service.py:120` | čaká |
| 7 | stredná | Zdieľaný kvíz | Okno s výsledkami sa točí donekonečna, keď nie je s kým porovnať | `SharedQuizResultsSheet.swift:38` | čaká |
| 8 | stredná | Zdieľaný kvíz | „Pošli kamarátovi“ po predčasnom ukončení kola vždy zlyhá | `QuizViewModel+SharedQuiz.swift:70` | čaká |
| 9 | stredná | Peniaze | Záporný zostatok po vrátení peňazí za balík blokuje aj bezplatné otázky každý mesiac | `routes/misc.py:225` | čaká |
| 10 | stredná | Peniaze | Vlastný balík po vrátení peňazí ostáva hrateľný (zdieľané odkazy fungujú) | `routes/sessions.py:68` | čaká |
| 11 | stredná | Peniaze | Obnova nákupov vytvorí stratenú objednávku bez publika a obťažnosti | `storekit/reconcile.py:56` | čaká |
| 12 | stredná | Vlastné balíky | Po zastavení pre rozpočet ostane čiastočný balík „pripravuje sa“ a hráč čaká donekonečna | `worker/sweep.py:189` | čaká |
| 13 | stredná | Vlastné balíky | Worker, ktorý dobehne po vrátení peňazí, prepíše stav „vrátené“ | `worker/tasks.py:324` | čaká |
| 14 | stredná | Kvíz v appke | Napísaná odpoveď počas preskakovania zasekne kvíz na 35 s a ukáže falošnú chybu | `QuizViewModel.swift:2029` | čaká |
| 15 | stredná | Kvíz v appke | Preskočenie MCQ pri otvorenom mikrofóne nahrávanie neukončí | `QuizViewModel.swift:2152` | čaká |
| 16 | stredná | Denná výzva | Zdieľaný odkaz na dennú výzvu obchádza obmedzenie pre betu | `shared_quiz/service.py:144` | čaká |
| 17 | stredná | Denná výzva | Karta dennej výzvy po polnoci ukazuje včerajší deň | `HomeDailyChallengeSection.swift:43` | čaká |
| 18 | stredná | Denná výzva | Dátum výzvy podľa kalendára telefónu: iný než gregoriánsky kalendár výzvu rozbije | `DailyChallengeDay.swift:26` | čaká |
| 19 | stredná | Účet | Predplatné kúpené počas odhlásenia sa po prihlásení neprenesie | `usage/account_merge.py:145` | PR #874 |
| 20 | stredná | Hlas na serveri | Denný strop prepisu reči verí dĺžke, ktorú si nahraný súbor sám uvedie | `usage/caps.py:104` | čaká |
| 21 | stredná | Hlas na serveri | Kontrola zostatku ElevenLabs stojí pred každou požiadavkou na hlas, mimo 6 s limitu | `tts/service.py:242` | čaká |
| 22 | stredná | Kostra appky | Automatické opakovanie štartu zdieľaného balíka minie jediné hranie | `QuizViewModel.swift:1321` | čaká |
| 23 | stredná | Kostra appky | Odkaz od kamaráta pri prvom spustení preskočí súhlas s AI službami | `ContentView.swift:222` | čaká |
| 24 | stredná | Kostra appky | Trubbo Beta: vynútená aktualizácia otvára TestFlight App Store appky | `UpdateRequiredView.swift:94` | čaká |

**Pôvodne neistý, po posúdení skutočný (malá pravdepodobnosť, veľký dopad):** výpadok spojenia počas nasadenia v ~30 s okne nechá službu zastavenú a návrat sa nespustí (`infra/hetzner/deploy-ssh.sh:146`). Oprava samostatným PR: nasadenie beží na serveri nezávisle od spojenia.

**Po nasadení PR #874 (2026-11-18, overené):** dohľadanie účtov, ktoré mali byť zmazané: 0 postihnutých (v prevádzke sú 2 účty, oba čisté), netreba nič mazať.

**Vyvrátené:** prepnutie „Čo hráme“ v čakárni ukončí hru · kontrola duplicít porovnáva so súkromnými balíkmi iných zákazníkov · ukrajinské MCQ číta latinské písmená.

**Nepreverené (nižšia priorita):** jedno miesto na doklad o nákupe balíka, druhý nákup prepíše nepoužitý (`PackPurchaseService.swift:175`) · appka ukazuje Plus zo surového stavu predplatného, server dáva bezplatných 30 (`UsageInfo.swift:48`) · 6 s limit hlasu nastavený pre rýchlejší model, ukrajinčina beží na pomalšom (`tts/providers.py:60`) · zdieľaný odkaz ťuknutý počas hry spolu sa spustí neskôr sám (`ContentView.swift:167`).

### 240.2 — Prieskumné prechody appkou (2026-11-18, rozrobené)

Dva prechody v testovacom režime (bez servera), druhý pozastavený v polovici. Potvrdené druhým agentom, všetko drobné: surová systémová hláška pri zlyhanom nákupe (`StoreManager.swift:203`) · názvy kategórií na kartách ostanú v pôvodnom jazyku po prepnutí jazyka (`Config.categoryOptions`) · dlhá odpoveď odrezaná v potvrdzovacom okne bez náznaku pokračovania. Nie je chyba: „LISTENING FOR COMMANDS“ sa riadi jazykom povelov. Otvorené podozrenie (videné raz): po ukončení kola bez odpovede chyba „Vypršal časový limit“ namiesto prehľadu.

Nepokryté: prerušenia počas vyhodnocovania, denná výzva, profil, balíky, Hra spolu, najväčšie písmo; ukrajinčina v appke ešte nie je. Poznámky: `scratchpad/walk/batch1|batch2/report.md` (session quiz-agent-87). Poučenie: simulátor nastavovať cez ID, nie menom (dva „iPhone 17e“), a po prechode appku vypnúť (drží port 9999).

Druhý prechod, dokončený po pauze: nová potvrdená chyba (2/2): **Nastavenia otvorené počas kvízu zmiznu**, lebo odpočet a mikrofón bežia ďalej a po vypršaní nahrávania ich nahradí okno „Nič som nezachytil“. Videné raz: po kole bez odpovede chyba „Vypršal časový limit“ (pravdepodobne oneskorené zlyhanie hlasového odoslania cez výsledky); jazyk kvízu sa medzi spusteniami nie vždy zachová. Hra spolu v testovacom režime prešla bez nálezu (vytvorenie, pripojenie, odchod, odstránenie hráča). Nepokryté ostáva: profil a nastavenia po riadkoch, odoslanie objednávky balíka, najväčšie písmo.

### 240.8 — Zábavnosť a chuť zdieľať (2026-11-18)

Posudok: [docs/research/fun-and-shareability-review-2026-11-18.md](../research/fun-and-shareability-review-2026-11-18.md), artefakt pre foundera https://claude.ai/artifact/ApjyP33XSGY85ri4DSnC1v.

Čísla z prevádzky (App Store buildy od 11-02, 9–11 inštalácií): 10 začatých kôl, 0 dohraných, 17 z 25 hlasových odpovedí odmietnutých ako „žiadna reč“ (interne 27 %), nikto sa nevrátil v iný deň; denná výzva, zdieľanie a Hra spolu bez dát od skutočných hráčov.

Príčina odmietnutých odpovedí (rozbor len čítaním): (1) hráč mlčal, kým bol mikrofón otvorený (10 s čakanie, 5 s okno, tiché nahrávky sa posielajú a automaticky opakujú, takže sa rátajú dvakrát); (2) zakázaný mikrofón sa nekontroluje a hráč dostane „nezachytil som“ (`RecordingCoordinator+Capture.swift:36`, `QuizViewModel.swift:1356`); (3) zlyhanie rozpoznávania povelov vypne nahrávanie odpovedí na builde 84, opravené na main cez #237 — povolenie povelov na požiadanie, ale ešte nie v App Store builde; (4) jedna inštalácia je pravdepodobne App Review.

Chýbajúce meranie: stav mikrofónu a spúšťač nahrávania pri odpovedi, dôvod a miesto odchodu z kola, štart a koniec hry spolu s dôvodom, príchod cez odkaz, kanál buildu na každej udalosti, `pack_id` pri kole z balíka.

Ďalšie kroky čakajú na rozhodnutia foundera (poradie v posudku, časť „Čo by som spravil“).

### 240.9 — Schválené zmeny z posudku (founder 2026-11-18 večer)

Founder: „pozrel som artefakt… so všetkým, čo navrhuješ, súhlasím. Pusti sa do toho. Ideálne aby si pracoval bez prerušenia… radšej skontrolujem všetko v TF beta verzii… bolo by super, keby mám ráno hotový beta build v TF.“

Rozhodnutia: denná výzva s partiou pre App Store **až s verziou 1.3** (dnešným App Store buildom sa prepínače nemenia) · ranný build do Trubbo Beta sa spustí, **až keď budú hotové všetky otvorené zmeny appky ostatných session** (#231 — ukrajinčina PR #860 a #862, #236 — rodinná sekcia PR #887) · Nastavenia počas otázky pozastavia odpočet (ruší pravidlo z 2026-07-06) · vrátený balík je zablokovaný všetkým · druhé Apple ID dostane vlastný čistý účet.

Bez ďalších otázok: voľby pri vzhľade a hodnotách robí agent, každý PR ich vypíše v časti „Decisions made“, founder ich posúdi v bete. Žiadne prepínače pre živé App Store buildy, žiadne platené služby.

| Vetva | Obsah | Stav |
|---|---|---|
| A — prvá minúta (appka) | zakázaný mikrofón, Nastavenia, hláška nákupu, názvy kategórií | PR #888 |
| B — hlas a sólo kolo (appka) | mikrofón hneď po otázke a jasné „teraz hovor“, mlčanie bez výčitky a bez dvojitého pokusu, kratšie čakania, séria, veta na konci, posledný verdikt pri limite, nálezy auditu 14 a 15, meranie (spúšťač nahrávania, stav mikrofónu, dôvod odchodu) | po zlúčení A |
| C — Hra spolu (server + appka) | odhalenie po otázke predvolené, čas 15 s, viditeľný stav čítania a hodnotenia, oznam zrušenej otázky, koniec s „Ešte raz“, obrázkom poradia a oceneniami, vibrácia pri odhalení, meranie štartu a konca hry | beží |
| D — odkazy (web) | náhľad odkazu v chate, pozvánka do miestnosti prežije inštaláciu, odkazy otvára aj Trubbo Beta | beží |
| E — server | nálezy auditu 20 a 21, dôvod odmietnutia prepisu v meraní | beží |
| F — zdieľanie a drobnosti (appka) | odkaz na obrázku prehľadu, vloženie celej správy, nálezy auditu 7, 8, 17, 18, 23, 24, čísla dennej výzvy stoja, prázdna partia, výber veku detí skrytý, čakanie na balík, starší prehľad | po B alebo C |
| G — nasadenie | skript nasadenia nezávislý od spojenia | potom |

Poradie zlučovania appky: po jednom, každý ďalší sa zosúladí s hlavnou vetvou (texty a snímky). Potom kompilácia Release, build do Trubbo Beta, overenie v TestFlighte. Zvyšok programu (240.3 stráže prístupnosti, 240.5 bezpečnosť, 240.6 robot-hráč) až po builde.

#### Výsledok 240.9 (2026-11-19 ráno)

| Vetva | Zmena | PR |
|---|---|---|
| A — prvá minúta | zakázaný mikrofón má hlášku a cestu do Nastavení; Nastavenia počas otázky pozastavia odpočet; zrozumiteľná hláška pri zlyhanom nákupe; názvy kategórií po zmene jazyka | #888 |
| B — hlas | mikrofón hneď po otázke, „Teraz hovor“, odpočet 15 s; mlčanie sa neposiela a nie je neúspech; nálezy auditu 14 a 15; meranie | #905 (+ server #906) |
| B — sólo kolo | výsledok ide ďalej 3 s po dohovorení verdiktu; séria od 3 správnych; veta na konci kola; verdikt a koniec kola pred ponukou pri limite | #911 |
| C — Hra spolu | odhalenie po otázke predvolené, 15 s, stav čítania a hodnotenia, oznam zrušenej otázky, „Ešte raz“, obrázok poradia, 3 ocenenia, vibrácia; zmena „Čo hráme“ nezruší odkaz | #900 (server), #907 |
| D — odkazy | náhľad odkazu v chate (jeden, po anglicky), pozvánka do miestnosti prežije inštaláciu, odkazy na kvíz otvára aj Trubbo Beta | #894 |
| E — server | strop prepisu reči sa nedá obísť; kontrola zostatku hlasu nezdržuje otázku; skutočný dôvod odmietnutej odpovede v meraní | #897 |
| F — zdieľanie a drobnosti | nálezy auditu 7, 8, 17, 18, 23, 24; prehľad sa zdieľa s vetou a adresou; vloženie celej správy; čísla dennej výzvy stoja; „balík sa ešte pripravuje“; starší prehľad sa nestratí | #909 (vrátane #910) |

Nálezy auditu mimo 240.9: 6 a 22 → #882 · 9 → #884 · 10 → #886 · 11, 12, 13 → #883 · 16 nepotvrdený (pokryl #864) · 20, 21 → #897.

Rozhodnutia agenta, ktoré má founder posúdiť v bete, sú v každom PR v časti „Decisions made“. Ukrajinské texty nových reťazcov sú v PR #911 a #909 v časti „Ukrainian texts for native check“ a v PR #912 (session quiz-agent-25).

**Vynechané / otvorené:**
- 240.9 G — skript nasadenia nezávislý od spojenia: zámerne nie v noci bez foundera.
- Výber veku detí vo formulári balíka: nie je chyba, patrí k #236 — rodinná sekcia.
- Náhľad odkazu podľa konkrétneho kvízu a jazyka: vyžaduje, aby stránky /play a /join podával náš server.
- Odpočet sa nepozastaví, keď je otvorená len ponuka s tromi bodkami (bez Nastavení); Nastavenia otvorené počas už bežiaceho nahrávania ostali ako predtým.
- Hosť na staršom builde na záverečnej obrazovke nenasleduje „Ešte raz“ sám.
- Pozvánka do partie sa po opätovnom otvorení konca dennej výzvy z domova neukáže (treba zmenu servera).
- Nestabilný UI test `testRS07EditThenReRecordDiscardsWithoutSubmitting` (raz zlyhal na časovaní pri preťažených strojoch).

**Čo skúsiť v bete na telefóne:**
1. Čerstvá inštalácia, prvý kvíz: po otázke „Teraz hovor“, tón, odpočet 15 s; pri mlčaní pokojná veta bez výčitky; ťuknutie na mikrofón alebo povel funguje.
2. Mikrofón vypnutý v Nastaveniach iOS: hláška „Mikrofón je pre Trubbo vypnutý“ a tlačidlo do Nastavení.
3. Hlučné auto, tichý hlas: odpoveď sa zachytí (o tichu teraz rozhoduje telefón).
4. So zvukom: verdikt doznie a ďalšia otázka príde asi o 3 s; tri správne za sebou ukážu sériu; veta na konci kola.
5. Bezplatný účet jednu otázku pred limitom: verdikt, koniec kola, potom ponuka.
6. Hra spolu na dvoch telefónoch: odhalenie po každej otázke, 15 s, mená tých, čo odpovedali, vibrácia raz na otázku, „Ešte raz“, obrázok poradia a jeho zdieľanie, ocenenia.
7. Zdieľanie: prehľad z profilu do Správ má odkaz; vloženie celej správy s odkazom spustí kvíz; odkaz na kvíz sa na telefóne s oboma appkami otvorí v bete; náhľad odkazu v chate.
8. Denná výzva: čísla na konci stoja; ráno karta na domove ukáže nový deň.
9. Objednávka balíka po ~3 minútach čakania: „Tvoj balík sa ešte pripravuje“.
