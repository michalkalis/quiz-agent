# #189 — TF feedback 2026-09-29 (AirPods, mimo auta, slovenský kvíz)

**Triage:** in-progress · **Build:** TF z `6310b647` (2026-09-25) · **Zdroj:** founder poznámky + 5 screenshotov, Sentry 08:43–09:04 UTC, Fly logy

## Nálezy a diagnóza

| # | Founder | Príčina (overené v kóde / logoch) | Oprava |
|---|---------|-----------------------------------|--------|
| 1 | Nápoveda na sheete „Povedz odpoveď znova alebo „áno“ / „nie““ nemá napísaný povel „znova“; texty v appke celkovo treba prejsť | Nápoveda je Swift literál v `VoiceCommandLexicon+Display.swift` (en/sk/cs), nie v xcstrings; neuvádza tlačidlové povely (pravidlo #174) | PR C: citovať „potvrď“ / „znova“ + „alebo novú odpoveď“ vo všetkých 3 jazykoch + test parity; celková revízia textov cez artefakt (nižšie) |
| 2a | Po „znova“ appka vôbec nerozumela (posledná otázka 10/10, „Neptún“) + chybová obrazovka „Odpoveď sa nepodarilo odoslať“ po preskočení / napísanej odpovedi | Server ukončil sadu po ohodnotení prvej odpovede na poslednú otázku (FINISHED, `max_questions` — 10/10 položených, 8 zodpovedaných + 2 preskočené; nedostatok otázok vylúčený); každé ďalšie odoslanie dostalo 400 „Not waiting for input“ → klient to bral ako „nezachytil som“ (slučka) a pri preskočení ako všeobecnú chybu odoslania | PR A: backend kódovaná chyba `session_finished` + povoliť opätovné odoslanie poslednej ohodnotenej otázky; iOS pri `session_finished` ukončí kvíz → výsledky |
| 2b | Na sheete po „znova“ nerozumela (Q5 „Chile. Neviem“) | Plausible: pri opakovanej nahrávke on-device analyzér nevráti nič (Scribe z toho istého audia prepis má); navyše H1/H2 nižšie. Hypotéza „Chile“ z predchádzajúcej otázky vyvrátená | PR B: telemetria „hluchý analyzér“ + opravy H1/H2; overenie na zariadení |
| 3 | Riadok vo výsledkoch: otázka a odpoveď majú rovnaké miesto, zlé zvislé zarovnanie | Dvojstĺpcový riadok v `SetRecapView` | HTML varianty A–D: [`docs/design/variants/issue-189-results-row.html`](../design/variants/issue-189-results-row.html) · [artefakt](https://claude.ai/artifact/MpEjnHh9PNoMNGvWPvUZW1) → founder vyberie → Pencil → kód |
| 4 | Po otvorení Control Center sa rozbil layout otázky a ostal aj na ďalšej | Ťah na minimalizáciu (`InteractiveMinimizeModifier`) drží posun v `@State`; systém gesto zruší bez `onEnded` → obsah ostane posunutý ~100 pt, zmenšený, vyblednutý | PR C: posun v `@GestureState` (reset pri zrušení) |
| 5 | Hneď po zobrazení potvrdzovacieho sheetu chýba lišta „Počúvam“ | Počas prečítania odpovede sa poslucháč vypne → `commandListenerHint` = nil → lišta skrytá (~4 s) | PR C: lišta v stave „čítam odpoveď“, potom „počúvam“ |
| 6 | Občas divné stavy pri odpovedaní | Review stavového automatu, nálezy nižšie | PR B |

### Nálezy review (#6)
- **H1 high** — počas nahrávania odpovede `refreshCommandWindow()` (návrat z Control Center/notifikácií, minimalizácia, pauza/resume, prepínač povelov) vypne zdieľaný mikrofónový engine → nahrávka ohluchne. Fix: v `syncCommandListenerWindow` nič nerobiť počas `.recording`.
- **H2 high** — nahrávka prevezme engine, ktorého štart ešte beží; po dobehnutí štartu ho guard vypne (typicky „Znova“ hneď po prečítaní odpovede na Bluetooth). Fix: guard nezastavuje počas `.recording`, nahrávka počká na dokončenie štartu.
- **M3** — pauza počas nahrávania → prázdna nahrávka → automatický retry otvorí mikrofón napriek pauze. Fix: retry rešpektuje pauzu (+ P9 vyčistiť `isRerecording`).
- **M4** — `finishQuiz` nevypne poslucháča → mikrofón horúci na výsledkoch, súhrn hrá cez živý engine. Fix: vypnúť pred `deactivateSession()`.
- **M5** — „povedz to znova“ zo servera po napísanej/upravenej odpovedi otvorí sheet vlastnený už odoslaným pokusom → Znova/Zruš odmietnuté. Fix: nový pokus v `presentNoAnswerChoice`.
- Nechané, len log: L6 (zrušené preskočenie nechá otázku bez odpočtu), L7 (prečítanie odpovede bez timeoutu), P8 (engine zastavený OS pri zmene trasy).

## PR plán
- **PR A** `fix/189-session-finished` (backend + iOS, Opus): #2a — hotové: opätovná odpoveď na poslednú otázku sa preoceňuje, inak `session_finished` → výsledky. Známa hrana: posledná otázka + „znova“ + preskoč → riadok poslednej otázky vo výsledkoch chýba, skóre zo servera ju obsahuje.
- **PR B** `fix/189-mic-engine-states` (iOS, Opus): H1, H2, M3, M4, M5 + telemetria (hluchý analyzér, `listener.stop` v ledgeri, P8/L7 logy, detail HTTP chyby).
- **PR C** `fix/189-confirm-sheet-and-drag` (iOS, Sonnet): #1 nápoveda, #5 lišta počas prečítania, #4 gesto + tento issue a varianty.
- Workeri needitujú mimo svojho worktree a nebuildujú; build + cielené testy sériovo jeden tester (vlastný simulátor).

## Revízia textov
Editor všetkých textov sk/cs/en s kontextom: artefakt (odkaz doplnený po publikovaní). Founder píše nové verzie → Claude ich prečíta a zapracuje samostatným PR.

## Otvorené (founder)
- Varianta riadku výsledkov (A–D).
- Režim odhalenia odpovedí pri #4 (po otázke / na konci sady).
- Overenie #2b na zariadení podľa postupu po PR B.
