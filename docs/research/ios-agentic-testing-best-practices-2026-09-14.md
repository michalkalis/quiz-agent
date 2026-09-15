# Research: Testovanie iOS appky pri agentickom vývoji

**Date:** 2026-09-14 | **Query:** Best practices na testovanie iOS appiek pri agentickom vývoji: automatizácia, kvalita, UX, edge cases (nákupy, vypršanie free limitu, obnova po kúpe balíka, audio čítanie/odpovedanie, stavové a regresné problémy). Čo používajú a ako k tomu pristupujú profíci.

## Executive Summary

- **Profi vzor 2026 je jednotný:** agent si UI prácu overuje sám v slučke build → ovládaj simulátor → over (strom prístupnosti + screenshot) → **zmraz** fungujúci priebeh do deterministického testu (XCUITest / Maestro YAML) pre CI. LLM-in-the-loop je drahý a nedeterministický; slúži na *objavovanie*, nie na *stráženie*. (Maestro, RocketSim, XcodeBuildMCP.)
- **Pyramída platí aj pre mobil:** ~70 % unit / 20 % integrácia / 10 % plné UI (Google). Väčšina našich „stavových" problémov (audio stavový automat, quota, entitlementy) patrí do unit testov nad **explicitným stavovým automatom** s **injektovaným časom** (swift-clocks `TestClock`), nie do simulátora.
- **Nákupy sa testujú offline a deterministicky:** StoreKit Testing (`.storekit` + `SKTestSession`) vie zrýchliť obnovy (`timeRate`), simulovať prerušený nákup, Ask to Buy, refund, vypršanie, grace period, zlyhanie transakcie. Sandbox/TestFlight je posledný krok pre človeka, nie regresný nástroj. Quota a rollover free otázok je **serverová** logika → pytest s injektovaným hodinami.
- **Audio/reč nemá žiadny „mock mód" od Apple:** jediná deterministická cesta je protokolový seam + fixtúry (WAV/CAF, falošné sekvencie transkriptov) + priame posielanie `AVAudioSession` notifikácií (prerušenie, zmena trasy). Failover TTS (ElevenLabs → OpenAI) musí byť čistý stavový automat s pozorovateľným fallbackom.
- **Náš stav:** audio/answer automat je najlepšie pokrytá oblasť (unit + 18 RS scenárov). **Diery:** (1) žiadny RS scenár pre paywall/nákup/quota, (2) žiadny test „quota wall → nákup → kvíz pokračuje", (3) žiadny systémový seam na čas (odtiaľ flaky wall-clock testy, ktoré CI serializuje), (4) žiadne pixel snapshoty (ViewInspector = štruktúra, nie vzhľad).

## Key Findings

### 1. Ako agenti overujú vlastnú UI prácu (profi slučka)

Konsenzus troch nezávislých zdrojov z leta 2026 (Maestro blog 09-01, RocketSim 08-05, Crosley guide 08-16): agent má **ovládať bežiacu appku, nie hádať zo zdrojáku**. Slučka: `inspect_screen`/`snapshot_ui` (sémantický strom prístupnosti) → akcia → kompaktný diff stavu → screenshot len pre vizuálne overenie. XcodeBuildMCP v2.6+ hlási pri deterministickej úlohe ~68 % menej tokenov a ~70 % menej času vďaka tomu, že strom nahrádza pixely a každá akcia vracia kompaktný snapshot s hashom obrazovky.

Kľúčová disciplína: **čo raz prejde, zmraziť.** Maestro MCP odporúča priebeh preskúmať inline YAML, potom uložiť do `.maestro/` ako Flow pod git a púšťať v CI cez CLI. RocketSim: „jeden zlý tap na začiatku onboardingu zneplatní všetko za ním" → merať nie len pass/fail, ale aj počet zlých interakcií a veľkosť kontextu; držať scenáre statické, aby sa UI drift dal odlíšiť od regresie nástroja. TestSprite dáta: pass rate agentom generovaných testov 42 % → 93 % po jednom self-repair prechode → prvý pokus je nespoľahlivý, počítať s druhým.

Stabilita selektorov: **accessibility identifiers**, nie texty (u nás 3 jazyky UI → textové selektory sa lámu pri každej zmene kópie). Identifikátory zdieľa XCUITest, idb, Maestro aj XcodeBuildMCP → jedna stratégia slúži všetkým nástrojom.

### 2. Architektúra pre testovateľnosť (čo robí Point-Free/TCA svet)

- **Čas ako závislosť:** `swift-clocks` — `ContinuousClock` v prode, `TestClock.advance(by:)` v testoch, `ImmediateClock` v preview. Debounce, dead-air, 30 s submit limit sa stanú okamžité a deterministické. Presne toto je lekcia z našej CI (wall-clock testy hladujú pri paralelnom behu, preto `-parallel-testing-enabled NO` a +60 % času).
- **Závislosti ako štruktúry closures** (`swift-dependencies`, `@DependencyClient`): v teste prepíšeš jeden endpoint, ostatné ostanú `unimplemented` → neočakávané volanie test zhodí nahlas. Lepšie než veľké Mock triedy, ktoré ticho vracajú default.
- **Explicitné enum stavové automaty** pre obrazovku aj hlasový tok; nedefinovaný prechod = chyba. Testovať **tabuľku prechodov** parametrizovane (Swift Testing `@Test(arguments:)`, pozor: dve kolekcie robia karteziánsky súčin, treba `zip`).
- **Snapshot hygiena:** vypnuté animácie, pinnutý locale/timezone/OS/simulátor, `__Snapshots__/` v gite, nikdy auto-re-record pri faile. Airbnb má ~30 000 snapshot testov (~3× viac než unit) — snapshoty legitímne dominujú iOS suite. Pre agenta, ktorý nevidí obrázky, sú **textové stratégie** (`.recursiveDescription`, `.hierarchy`) čitateľné v termináli; pixel diff dopĺňa, nie nahrádza.

### 3. Nákupy, entitlementy, quota

**StoreKit Testing v Xcode** (`Hangs.storekit` už máme) + `SKTestSession` v testoch beží offline aj v CI a pokrýva presne edge cases, ktoré v sandboxe trvajú hodiny alebo sa nedajú vyvolať: zrýchlená obnova (`timeRate`, napr. mesiac = pár minút), `interruptedPurchasesEnabled`, `askToBuyEnabled`, `failTransactionsEnabled`, refund/expire/vypnutie auto-renew, billing grace period, `clearTransactions` medzi testami. Zásada: **nikdy neposúvať hodiny zariadenia** — sandbox to odmieta.

RevenueCat (nepoužívame, ale ich prax je referenčná): Test Store obnovuje každých pár minút, po 5 obnovách automaticky zruší → testuje sa vypršanie bez čakania; assertovať na **entitlementy**, nie na surové transakcie. To isté platí u nás: testovať `EntitlementReconciler` výstup, nie StoreKit transakcie.

**Server:** App Store Server Notifications V2 → vždy vrátiť 200 a byť idempotentný (inak Apple retry → dvojité spracovanie). Quota free otázok a jej reset (mesačný rollover, DST, atomické počítadlá) je čistá backend logika → pytest s injektovaným časom. Kritický **cross-cutting scenár, ktorý nikto nepokrýva automaticky u nás:** narazím na quota wall → kúpim → kvíz pokračuje bez reštartu; a jeho zrkadlo: mám kúpený balík → free quota vypršala → balík stále funguje.

### 4. Reč a audio

Apple nedáva mock mód pre `SFSpeechRecognizer`/`SpeechAnalyzer`; mikrofón simulátora je proxy Mac mikrofónu a v CI sa nedá skriptovať. Profi prístup:
- Protokolový seam (máme: `MockElevenLabsSTTService`, `MockAudioService`, HTTP loopback na port 9999 na injekciu transkriptov) + **audio fixtúry** (WAV/CAF) posielané priamo do rozpoznávača pre integračné testy.
- iOS 26 `SpeechAnalyzer` vracia `AsyncSequence` → testovať falošnými sekvenciami vrátane **chýbajúceho jazykového modelu** ako explicitnej chyby (reálne riziko pre SK/CS).
- **Prerušenia a zmeny trasy** (hovor, CarPlay/Bluetooth odpojenie): postovať `AVAudioSession.interruptionNotification` / route-change priamo v unit teste, sledovať reakciu stavového automatu. Náš RS-18 (BT mikrofón) to robí cez simulátor — drahšie a krehkejšie než unit test.
- **TTS failover ako stavový automat:** injektovať zlyhanie per úroveň (ElevenLabs quota → OpenAI → on-device) a assertovať, že fallback je pozorovateľný (log/Sentry breadcrumb), nie tichý. Citovaný cudzí bug: tichý fallback, žiadne audio, žiadny indikátor — presne náš #178 vzor s vyčerpaným ElevenLabs limitom.
- Korpusový test STT kvality (WER nad sadou nahrávok povelov v sk/cs/en) je štandard pre hlasové produkty (Picovoice) — u nás zatiaľ nič.
- Nepotvrdené: `AVAudioSession.MicrophoneInjectionMode` (iOS 18) ako testovací nástroj — je to primárne user feature, nespoliehať sa.

### 5. Proces a kvalita

- **TestFlight:** spätná väzba viazaná na build; triedenie ~2× týždenne; testerov segmentovať podľa toku (nákup / hlas / jazyk). Ľudia ostávajú nutní pre vizuálnu správnosť, reálne App Store transakcie, podpisovanie a fyzické zariadenie (CarPlay simulátor vyžaduje reálny iPhone cez USB).
- **Sentry Cocoa 9+:** štruktúrované logy sú stabilné a nahrádzajú ručné breadcrumbs; jeden bohatý log per operácia > veľa tenkých. Súhlasí s naším PR #150 (logy prechodov stavov + MCQ submit).
- **CI realita:** GitHub Actions macOS runnery flakujú na XCUITest 25–37 % (zaseknutý simulátor) → pinnúť presný OS + destination, retry brať ako infra náklad; unit a snapshot testy v CI, plné UI scenáre nočne/na požiadanie.
- Property-based testing v Swifte je nezrelé → cieliť na tabuľky prechodov a parsery (povely, MCQ matcher), nie všeobecné PBT.
- Google pyramída: „70 % kritických bugov chytia unit testy, len 10 % potrebuje plnú UI automatizáciu."

## Implications for Hangs

Máme nadpriemerný základ: ~100 testovacích súborov, protokolové mocky pre audio/STT/nákupy, `.storekit` config, XCUITest page objects, 18 RS scenárov cez XcodeBuildMCP + HTTP loopback, Sentry so stavovým kontextom. Odchýlky od profi praxe:

| Oblasť | Profi prax | My | Diera |
|---|---|---|---|
| Čas | injektovaný Clock | reálne časovače, CI serializované | flaky, pomalé CI, quota expiry netestovateľná |
| Nákupy e2e | SKTestSession scenáre + zmrazené UI toky | unit mocky, žiadny RS scenár | paywall/nákup/obnova bez regresie |
| Quota × entitlement | cross-cutting test „wall → kúpa → pokračuj" | nič pomenované | opakované TF problémy |
| Vizuál | pixel/text snapshoty v CI | ViewInspector štruktúra, VISUAL check len v `/regression` | layout drift v 3 jazykoch nechytený |
| RS scenáre | zmrazené deterministické testy v CI | LLM-driven cez subagenta, na požiadanie | drahé, nedeterministické, nebeží pri každom PR |
| Audio prerušenia | unit test cez notifikácie | RS-18 v simulátore | krehké, pomalé |
| STT kvalita | WER korpus | nič | regresie povelov sk/cs nevidno |

## Recommendations

1. **Zaviesť `swift-clocks` seam** do QuizViewModel/CommandListener/dead-air/submit časovačov; prepísať wall-clock testy na `TestClock`. Umožní vrátiť paralelný CI beh a otvorí testy quota expiry. Najvyšší pákový efekt.
2. **SKTestSession suita** nad `Hangs.storekit`: prerušený nákup, Ask to Buy, refund, vypršanie so zrýchleným `timeRate`, zlyhaná transakcia, restore na novom zariadení. Assertovať na `EntitlementReconciler`, nie na transakciách.
3. **Cross-cutting scenáre quota × balík** ako unit/integračné testy s injektovaným časom: (a) wall → nákup → pokračovanie bez reštartu, (b) balík kúpený + free quota vypršala, (c) mesačný reset s DST. Backend strana v pytest.
4. **Zmraziť RS-01..RS-18 do XCUITest** (HangsUITests/Regression už existuje) a púšťať nočne na `mba`; `/regression` cez LLM ponechať na *nové* scenáre a exploráciu. Nové RS scenáre pridať pre paywall/nákup/obnovu.
5. **Accessibility identifiers na všetkých interaktívnych prvkoch** ako povinný štandard (lint/review checklist) — predpoklad pre 4 a pre stabilitu v sk/cs/en.
6. **Snapshoty:** pridať `swift-snapshot-testing` s textovými stratégiami (agent číta diff) + pixel snapshoty pre hero obrazovky × 3 jazyky × Dynamic Type; `__Snapshots__` v gite, žiadny auto re-record.
7. **Audio automat:** prerušenia/route-change ako unit testy cez notifikácie; TTS failover testovať per úroveň s assertom na Sentry log; pridať malý WER korpus povelov (sk/cs/en) ako regresný test STT vrstvy.
8. **Definícia „done" pre agenta:** unit + snapshot zelené v CI, relevantný zmrazený RS scenár zelený, nový tok má identifikátory + zmrazený test. TestFlight = ľudský vizuál + reálny nákup, nie hľadanie stavových bugov.

## Sources

1. [Maestro: Mobile UI testing with coding agents](https://maestro.dev/blog/mobile-ui-testing-with-coding-agents) — 2026-09-01; explore inline → zmraz Flow → CI; MCP pre Claude Code/Cursor/Codex.
2. [RocketSim: How we test AI agents for the iOS simulator](https://www.rocketsim.app/blog/testing-ai-agents-ios-simulator/) — 2026-08-05; deterministické fixtúry, merať zlé interakcie a kontext, zmrazené scenáre.
3. [Blake Crosley: Building iOS apps with AI agents](https://blakecrosley.com/guides/ios-agent-development) — 2026-08-16; identifikátory, snapshoty, čo ostáva človeku (vizuál, signing, reálne nákupy).
4. [Agentic Developer Cookbook: Apple UI verification](https://agenticdevelopercookbook.com/appendix/research/developer-tools/apple/ui-verification) — textové snapshot stratégie pre agentov, accessibility audit, xcparse.
5. [XcodeBuildMCP complete guide 2026](https://mcp.directory/blog/xcodebuildmcp-complete-guide-2026) — snapshot_ui benchmark (−68 % tokenov, −70 % času).
6. [Apple: SKTestSession](https://developer.apple.com/documentation/storekittest/sktestsession) — timeRate, interrupted purchases, Ask to Buy, refund/expire, grace period.
7. [RevenueCat Test Store](https://www.revenuecat.com/docs/test-and-launch/sandbox/test-store) — obnovy každých pár minút, auto-zrušenie po 5; assert na entitlementy.
8. [swift-dependencies](https://github.com/pointfreeco/swift-dependencies) — closures + `unimplemented` fail-loud.
9. [swift-clocks](https://github.com/pointfreeco/swift-clocks) — TestClock/ImmediateClock.
10. [Sentry Apple structured logs](https://docs.sentry.io/platforms/apple/logs/) — stabilné od Cocoa 9.0.
11. [Google mobile test pyramid](https://developer.android.com/training/testing) — 70/20/10.
12. [GitHub runner-images issue #12777](https://github.com/actions/runner-images/issues/12777) — macOS simulátor flake.
13. [Use Your Loaf: Swift Testing parameterized tests](https://useyourloaf.com) — cross-product vs zip.
14. [Picovoice: STT benchmarking](https://picovoice.ai/blog) — WER korpus.

Poznámka: zdroje 1–7 overené priamym fetchom/vyhľadaním; 8–14 z vyhľadávacích snippetov a známej dokumentácie.
