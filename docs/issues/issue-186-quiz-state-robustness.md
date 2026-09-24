# #186 — Stabilizácia stavov kvízovej obrazovky (vlastníctvo async výsledkov + náhodné testy sekvencií)

**Triage:** enhancement · ready-for-agent (kroky 1 + 2 rozhodnuté 2026-09-24, robiť spolu s [#185 — test v aute 2026-09-23](issue-185-car-test-2026-09-23.md); kroky 3–4 neskôr)

## Smer

Founder 2026-09-24: stavy na kvízovej a súvisiacich obrazovkách sa dlhodobo občas „pokazia“ (naposledy confirm na ďalšej otázke, #185). Teraz žiadne veľké zmeny architektúry, ale zmierniť celú triedu chýb. Research: [quiz-state-robustness-2026-09-24.md](../research/quiz-state-robustness-2026-09-24.md) (26 zdrojov).

**Koreň triedy chýb:** asynchrónne výsledky (upload/prepis, vyhodnotenie, TTS, časovače, auto-advance) nie sú viazané na otázku a pokus, ktorý ich spustil. Poistky kontrolujú len prípad fázy (`== .processing`) a `QuizState` `Equatable` ignoruje asociované hodnoty, takže neskorý výsledok z otázky N prejde aj počas N+1. `submissionEpoch` sa kontroluje len na streaming ceste; question id sa posiela na backend, ale na klientovi ho žiadny výsledok neoveruje. Viacero Taskov mimo `TaskBag`. Zamietnuté prechody idú len do OSLog, nie do Sentry.

**Nerobiť:** TCA celé, nový boolean na každý bug, spoliehať sa len na cancellation, OSLog ako jediný terénny signál, statechart DSL.

## Kroky

1. **Lístok vlastníctva + čierna skrinka (malé, TERAZ):** jeden `AttemptID` (question id + počítadlo) nahradí `submissionEpoch`; každý async výsledok ho overí pred zápisom stavu, inak zahodí + Sentry log. Zamietnuté prechody a zahodené výsledky → Sentry. Ring buffer posledných vstupných udalostí priložený k Sentry eventom a TF feedbacku. DEBUG invarianty (napr. confirm sheet len s transkriptom aktuálnej otázky). Priamo pokrýva vedľajší nález #185 (chybové cesty uploadu bez kontroly vlastníka). Pinning test: neskorý 400 z Q1 počas Q2 nesmie otvoriť sheet.
2. **Test náhodných sekvencií udalostí (stredné, TERAZ po kroku 1):** seedované sekvencie (reč, povely, ťuknutia, časovače, prerušenia, route change, pozadie) proti reálnemu ViewModelu s mockmi a `TestClock`; invarianty po každom kroku; zlyhanie sa zmenší na minimálnu sekvenciu; rovnaký formát udalostí prehrá záznam z čiernej skrinky ako regresný test. Deterministické (seed), cielená suita, nie nočný beh.
3. **Zlúčiť booleany do stavu (neskôr, po klastroch pri dotyku kódu):** najprv potvrdzovanie: `.processing(attempt, .confirming(...))`, typovaná tabuľka prechodov namiesto stringov.
4. **Voliteľný vlastný čistý reduktor (neskôr, len ak 1–3 nestačia):** nie pred App Store launchom.

## Hotovo keď

- Krok 1: všetky async cesty v kvízovom flow overujú `AttemptID` (zoznam ciest v PR), Sentry dostáva zamietnuté prechody, pinning testy zelené.
- Krok 2: harness beží v cielenej suite, ≥ niekoľko tisíc sekvencií na beh bez porušenia invariantov, a pozná prehrať uložený záznam.
