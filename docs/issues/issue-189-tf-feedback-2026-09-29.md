# #189 — TF feedback 2026-09-29 (AirPods, mimo auta, slovenský kvíz)

**Triage:** code-complete (2026-09-29) · open = TF test na požiadanie + Pencil D · **Build:** TF z `6310b647` (2026-09-25) · **Zdroj:** founder poznámky + 5 screenshotov, Sentry 08:43–09:04 UTC, Fly logy

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

## Stav (2026-09-29)
- PR #206 — koniec sady: opätovná odpoveď na poslednú otázku, inak `session_finished` → výsledky · MERGED · backend v120 v prode (pomáha už aj buildu z 6310b647).
- PR #207 — nápoveda citujúca povely, lišta „Čítam odpoveď“ počas prečítania, reset ťahu po Control Center (overené na simulátore) · MERGED.
- PR #208 — H1/H2/M3/M4/M5 + telemetria (hluchý analyzér, `listener.stop`, zmeny trasy) · MERGED.
- PR #209 — `docs/design/copy-style.md` + CI job `copy-review` (subscription token) · MERGED. Founder 09-29: ručná revízia 500 textov je príliš dlhá → automatická kontrola ako pri otázkach.
- PR #210 — výsledky sady ako jeden zoskupený zoznam, odpoveď pod otázkou (founder vybral variant D) · MERGED · Pencil pass otvorený (Pencil nebežal).
- PR #211 — jednorazová oprava textov: Opus návrhy → nezávislý Opus sudca → 172 hodnôt, 8 plurálov, InfoPlist sk/cs; founder: „kvíz“ všade, rodovo neutrálne oslovenie, „Hraj bez limitu“, „z českých dějin“.

## Overenie na zariadení (ďalší TF build, na požiadanie)
1. Posledná otázka: odpovedz, na sheete „znova“, odpovedz znova → prijme a ohodnotí; preskoč na prázdnom sheete poslednej otázky → rovno výsledky, žiadne „Ojoj“.
2. Na sheete hneď po zobrazení lišta „ČÍTAM ODPOVEĎ“, potom „POČÚVAM“ + „Povedz „potvrď“, „znova“ alebo novú odpoveď“.
3. S AirPods: „Znova“ hneď po prečítaní odpovede a ihneď hovoriť, 5×; appka musí rozumieť. Ak nie, poznač čas → Sentry „deaf analyzer“ / `listener.stop`.
4. Počas nahrávania odpovede stiahni Control Center a zavri → nahrávka pokračuje a sama skončí po odmlke.
5. Počas otázky stiahni Control Center z pravého rohu → rozloženie ostane.
6. Pauza počas nahrávania → mikrofón sa neotvorí, po obnovení odpočet beží.
7. Výsledky sady (odhalenie na konci): jeden zoznam, celé odpovede.

## Follow-upy
- Úvodná karta povelov: zoznam slov generovať zo slovníka povelov podľa jazyka kvízu (dnes pevný text).
- „sada“ vs „kvíz“ pre koniec sady (founder nerozhodol; nezmenené).
- Hrana: posledná otázka + „znova“ + preskoč → chýba riadok vo výsledkoch, skóre ho obsahuje.
- Nechané len ako log: zrušené preskočenie bez odpočtu (L6), prečítanie bez timeoutu (L7), engine zastavený OS (P8).
