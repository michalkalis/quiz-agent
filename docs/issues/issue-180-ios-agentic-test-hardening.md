# Issue 180: iOS test hardening v2 — deterministické testy pre agentický vývoj

**Triage:** enhancement · ready-for-agent
**Reversibility:** a
**Status:** Track A HOTOVÝ 2026-09-18 (PR feat/180-track-a-clock): jeden vstrekovaný clock (swift-clocks) na celej quiz ceste, 33 testovacích súborov migrovaných na TestClock/pumpUntil, procesový serializovaný hlavný executor, 5/5 zelených behov po 1211 testov. Zistenie: paralelný režim Swift Testing je pri main-actor sade bez prínosu → CI ostáva serializované. **Track B HOTOVÝ 2026-09-21 v záložnom tvare** (PR feat/180-track-b-storekit): SKTestSession je na iOS 26.4/26.5 simulátore pri `xcodebuild` nepoužiteľný z unit-test hostiteľa AJ z UI-test runnera (SKInternalErrorDomain Code=3, Apple FB22774836, bez opravy; obchádzky = spustenie z Xcode IDE alebo runtime 26.1, ktorý nie je lokálne ani na CI) → 7 scenárov zakódovaných ako lifecycle testy nad protokolovými mockmi (`PurchaseEdgeCaseScenarioTests`, 8 testov, prepojenie ako v AppState, assert na výstup reconcilera/paywallu) + opt-in sonda `StoreKitSessionSmokeTests` (`HANGS_STOREKIT_LIVE=1`, v CI viditeľne skipped, so zapnutým prepínačom zlyhá nahlas), ktorá odhalí deň, keď Apple chybu opraví. **Track C 2026-09-21 (PR feat/180-track-c-quota):** backend `UsageTracker(now=)` = jeden vstrekovaný zdroj času pre celú kvótovú bránu (mesačné okno, expirácia predplatného aj `resets_at` z jedného okamihu na volanie); pytest `test_quota_pack_scenarios.py` (5 testov: balík hrá pri vyčerpanej free kvóte + kontrast free session odmietnutá; mesačný reset ako jeden UTC okamih cez koniec/začiatok DST a prelom roka; brána číta čas raz na volanie) + iOS `QuotaPackScenarioTests` (4 testy: balík hrá za free stenou bez nákupu; `resets_at` parsovaný ako serverový UTC okamih v drôtovom formáte; odpočet verí serveru, nie lokálnemu kalendáru; nový mesiac príde zo servera pri foregrounde bez reštartu). **Scenár (a) „stena uprostred kvízu → nákup → ten istý kvíz pokračuje“ = produktová zmena, nie test:** dnes backend pri stene session UKONČÍ (`flow.process_answer:usage_limit` → FINISHED) a iOS ide do idle → po nákupe sa začína nový kvíz. Mechanizmus na pokračovanie už existuje (#182 — hrať balík hneď po prvej otázke: zaparkovaná session + `next-question`/`resume_after_wait` + iOS `enterAwaitingQuestion`); rozhodnutie foundera čaká. Založené 2026-09-15 z researchu [ios-agentic-testing-best-practices-2026-09-14.md](../research/ios-agentic-testing-best-practices-2026-09-14.md). Founder 2026-09-15: „v zásade za každé odporúčanie", podmienka = dôveryhodné zdroje (Apple, iOS devs, GitHub repá, Anthropic/OpenAI). Founder 2026-09-16: bez nočných behov, príprava len na úrovni smeru; detail rieši interaktívna session. Ready 2026-09-16.

## Prečo

Opakované TF kolá (#171 — TF feedback 09-05, #173 — TF feedback 09-07, #174 — TF feedback 09-08, #178 — TF feedback 09-13, #179 — TF feedback 09-14) hlásia ten istý druh chýb: stavové a regresné problémy v audio čítaní/odpovedaní, nákupoch a free limite. Náš setup (unit + ViewInspector + 18 RS scenárov cez LLM) tieto triedy chytá až v TestFlighte. Profi prax 2026 pre agentický vývoj: stavové bugy chytať v deterministických unit testoch s injektovaným časom, nákupy testovať offline cez StoreKit Testing, a UI scenáre po overení **zmraziť** do CI namiesto LLM-driven behu pri každej kontrole.

Nadväzuje na #31 (iOS test hardening, done; XCUITest scheme wiring ostalo otvorené). Rešpektuje #43 — Maestro MCP UI flows (wontfix) — ostávame na XcodeBuildMCP + XCUITest.

## Tracky (poradie = páka)

Každý track nesie zdroj, aby bola dôveryhodnosť viditeľná.

### A. Injektovaný čas (swift-clocks) — Point-Free (GitHub, top iOS devs)
`ContinuousClock` v prode, `TestClock.advance(by:)` v testoch. Cieľ: dead-air, 30 s submit, recording window, debounce povelov, `SilenceDetectionService` bez reálnych sleepov. Pohltí TODO „Make SilenceDetectionService timing tests deterministic". Umožní vrátiť `-parallel-testing-enabled YES` v `ios-ci.yml` (dnes serializované, +60 % času).

### B. StoreKit Testing suita (SKTestSession) — Apple
Nad existujúcim `Hangs.storekit`: prerušený nákup, Ask to Buy, refund, vypršanie so zrýchleným `timeRate`, zlyhaná transakcia, restore na „novom zariadení", grace period. Assert na výstup `EntitlementReconciler`, nie na transakciách (RevenueCat prax: entitlementy, nie transakcie).

### C. Quota × balík cross-cutting scenáre — vlastná diera, mechanizmus z A+B
(a) free limit vyčerpaný → nákup → kvíz pokračuje bez reštartu; (b) balík kúpený + free quota vypršala → balík funguje; (c) mesačný reset vrátane DST. iOS strana s `TestClock`, backend strana pytest s injektovaným časom.

### D. Zmrazenie RS-01..RS-18 do XCUITest — Maestro / RocketSim / XcodeBuildMCP maintaineri
`HangsUITests/Regression` už existuje; doplniť chýbajúce scenáre (RS-14 a RS-18 sú unit testy a ostávajú unit), spúšťať nočne na `mba` (GitHub macOS runnery flakujú 25–37 % na XCUITest). `/regression` cez LLM ostáva len na exploráciu nových scenárov. Nové RS scenáre pre paywall / nákup / obnovu.

### E. Accessibility identifiers ako štandard — Apple XCUITest + všetci agentní tool vendori
Každý interaktívny prvok má `accessibilityIdentifier`; textové selektory zakázané (3 jazyky UI). Checklist do `.claude/rules/ios.md` + review.

### F. Snapshot testy (swift-snapshot-testing) — Point-Free; Airbnb škála
Textové stratégie (`.recursiveDescription`) pre agentom čitateľné diffy + pixel snapshoty hero obrazoviek × sk/cs/en × Dynamic Type. `__Snapshots__` v gite, žiadny auto re-record. Nahrádza odložený 52.18 (re-record snapshot baseline z #52 — iOS design-refresh sweep).

### G. Audio stavový automat bez simulátora — Apple AVAudioSession API
Prerušenie/route-change ako unit testy cez priamo postované notifikácie (dnes bez pokrytia; RS-18 je čistý unit helper pre Bluetooth mic v media móde, zámerne mimo živej audio session po zamrznutí HangsTests 2026-06-17). TTS failover ElevenLabs → OpenAI je serverový (`apps/quiz-agent/app/tts/service.py`) — testovať per úroveň v pytest s assertom na log (tichý fallback = fail); iOS testuje len „prázdne audio = viditeľná chyba", nie failover. Malý WER korpus povelov sk/cs/en pre STT vrstvu (Picovoice prax, slabší zdroj — voliteľné).

### H. Definícia „done" pre agenta — syntéza
Nový tok = identifikátory + zmrazený test; PR = unit + snapshot zelené; TestFlight = ľudský vizuál + reálny nákup, nie hľadanie stavových bugov. Zapísať do `.claude/rules/ios.md`.

## Kde to sedí (recon 2026-09-16)

- **A čas:** `ViewModels/QuizTimersController.swift`, `QuizViewModel+StallWatchdog.swift`, `RecordingCoordinator+Submission.swift` (30 s cez `Utilities/UserFacingTimeout.swift`), `Services/SilenceDetectionService*.swift`, `VoiceCommandCoordinator+*.swift`, `Utilities/TransientRetry.swift`. Reálne sleepy/XCTWaiter má ~31 testovacích súborov (grep `Task.sleep|Thread.sleep|XCTWaiter` v `HangsTests/`), napr. `QuizViewModelTimerTests`, `SubmissionStallTests`, `CommandListenerTests`, `PackRetryDurabilityTests`. Referenčný deterministický vzor už existuje: `SilenceDetectionServiceTests` (injected `FakeClock.advance`), `SubmitRetryTests` (`.zero` backoff override), `QuotaPaywallPurchaseLoopTests` (`SleepRecorder` + `pumpUntil`) — zjednotiť na jeden Clock seam. swift-clocks nie je závislosť (SPM cez `project.pbxproj`).
- **B nákupy:** `Services/StoreManager.swift`, `PurchaseService.swift`, `PackPurchaseService.swift`, `ViewModels/EntitlementReconciler.swift`, config `Configuration/Hangs.storekit`. `SKTestSession` sa dnes nikde nepoužíva.
- **C quota:** iOS `Models/UsageInfo.swift`, `EntitlementReconciler`, `Views/PaywallView.swift`, `HomePlanCard.swift`; backend `apps/quiz-agent/app/usage/entitlement.py`, `usage/tracker.py`, `api/routes/entitlements.py`.
- **D RS:** `HangsUITests/Regression/RegressionTests.swift` má dnes 8 slug testov (`testRSStart`, `testRSCorrect`, `testRSIncorrect`, `testRSLongQuestion`, `testRSMCQLongReveal`, `testRSMCQLongOptionsFooterReachable`, `testRSPaywall`, `testRSPackNavStart`), žiadne číslované `RS-NN`. Číslované RS-11, 13–18 sú unit testy v `HangsTests/` (viď `docs/testing/regression-scenarios.md`); RS-06 nie je implementovaný nikde; chýbajú RS-01–10 a RS-12. Loopback v `Utilities/UITestSupport.swift`.
- **E identifikátory:** 38 súborov ich už používa; žiadny lint hook (`.claude/hooks/` má len session-start).
- **F snapshoty:** swift-snapshot-testing nie je závislosť; existuje len ViewInspector.
- **G audio:** `Services/AudioService.swift` (interruption handling), testy `AudioServiceTests`. TTS failover je backend.

## Acceptance
_(rámec; konkrétne testy vzniknú pri implementácii)_
- [x] A: 5/5 zelených behov celej sady (serializované — paralelný režim zamietnutý s odôvodnením v `ios-ci.yml`); žiadny quiz-path test nečaká na reálny čas (zvyšok = view-level časovače a audio settle, vymenované v PR)
- [x] B: 7 vymenovaných scenárov pokrytých ako lifecycle testy (`PurchaseEdgeCaseScenarioTests`), zelené v CI bez siete; SKTestSession blokovaný Apple bugom FB22774836 (2026-09-21) → opt-in sonda namiesto tichého skipu; ak Apple opraví simulátor, scenáre sa dajú preniesť na SKTestSession bez zmeny asertov
- [~] C: (b) balík × vyčerpaná kvóta a (c) mesačný reset s DST hotové ako pomenované testy (iOS + pytest, zelené 2026-09-21); (a) stena uprostred kvízu → nákup → pokračovanie = produktová zmena (dnes session končí), čaká na foundera
- [ ] D: RS-01..RS-18 okrem RS-14 a RS-18 + nové paywall scenáre v `HangsUITests`, nočný beh na `mba` s reportom do `docs/testing/runs/`
- [ ] E: lint/grep nenájde interaktívny prvok bez identifikátora na obrazovkách kvízu, paywallu, výsledku
- [ ] F: snapshoty existujú pre Home/Question/Paywall/Result × 3 jazyky, `__Snapshots__` v gite
- [ ] G: prerušenie + route-change ako iOS unit testy, TTS failover per úroveň v pytest; RS-18 ostáva unit (pure helper)
- [ ] H: `.claude/rules/ios.md` obsahuje definíciu done

## Mimo rozsah
Maestro (#43 — Maestro MCP UI flows, wontfix), RevenueCat migrácia, CarPlay simulátor (vyžaduje reálne zariadenie → #97 — CarPlay support).
