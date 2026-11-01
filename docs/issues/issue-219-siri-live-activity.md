# #219 — Live Activity (zamknutá obrazovka, Dynamic Island, CarPlay); Siri vynechaná

**Triage:** enhancement · ready-for-agent (len Live Activity; Siri vynechaná, founder 2026-11-01)
**Status:** 2026-11-01 founder: pridať spúšťanie cez Siri/Skratky („Hey Siri, start a Trubbo quiz“, bez rúk) a Live Activity s aktuálnou otázkou, skóre a časom. Dnes v appke nič z toho nie je (žiadny súbor neimportuje AppIntents ani ActivityKit).
**Súvisí:** #97 — CarPlay (rovnaký zdieľaný QuizViewModel, vzor ovládača), #214 — odporúčaná aktualizácia a údržba (DB prepínače v `/app-config`), #209 — App Store review cleanup (obchodná varianta `APP_STORE`), #51 — analytika

## Cieľ

1. Hráč spustí kvíz bez dotyku: Siri, Spotlight, appka Skratky, tlačidlo Action. Kvíz beží rovnako ako po ťuknutí na Štart.
2. Kým kvíz beží a hráč nie je v appke (zamknutý telefón, iná appka, mapy), vidí jedným pohľadom, kde v kvíze je: na zamknutej obrazovke, v Dynamic Islande a na CarPlay Dashboarde.
3. Nič z toho nesmie zhoršiť hlasový priebeh (prvá otázka nesmie byť useknutá Siri, mikrofón len tam, kde smie byť).

Appka nie je len do auta: skratka rovnako poslúži na chate či na párty (Siri na HomePode alebo telefón na stole), Live Activity aj skupine, ktorá sa pozerá na zamknutý telefón.

## Čo hovorí výskum

- **Siri nevie po slovensky ani po česky.** Apple zoznam jazykov Siri nemá ani slovenčinu, ani češtinu ([feature availability](https://www.apple.com/ios/feature-availability/), sekcia Siri). Nová Siri s Apple Intelligence rozumie písanej slovenčine len na macOS 27 a len pri systéme v English (US); hlasom nie, na iPhone v EÚ zatiaľ vôbec ([touchit.sk 07-2026](https://touchit.sk/nova-siri-slovencina-prehlad/893191/)). Čeština ani v iOS 27 ([letemsvetemapplem.eu](https://www.letemsvetemapplem.eu/en/?p=811121)). Dôsledok: sk/cs hráč má Siri nastavenú po anglicky (prípadne nemecky a pod.) a frázu povie v jazyku Siri. Slovenské a české frázy Siri nepoužije; preložené **názvy** skratiek sa ale v appke Skratky a v Spotlighte ukážu v jazyku telefónu. Spotlight, Skratky a tlačidlo Action fungujú bez ohľadu na jazyk Siri. (Či Xcode vôbec prijme sk/cs frázy v `AppShortcuts.xcstrings`, overiť v 219.4.)
- **App Shortcuts:** najviac 10 na appku ([Apple DTS, fórum](https://developer.apple.com/forums/thread/787555)), každá fráza musí obsahovať názov appky (`applicationName`), fungujú hneď po inštalácii bez nastavovania ([App Shortcuts](https://developer.apple.com/documentation/appintents/app-shortcuts)). Preklady fráz v String Catalogu `AppShortcuts` v cieľovom targete appky; intenty v samostatnom frameworku s prekladmi nefungujú ([fórum 768900](https://developer.apple.com/forums/thread/768900)). App Intents nepotrebujú Siri entitlement (ten je len pre starý SiriKit).
- **Otvoriť appku vs. bežať na pozadí:** od iOS 26 sa správanie určuje cez `supportedModes` (`openAppWhenRun` je zastarané): `.background`, `.foreground(.immediate / .dynamic / .deferred)` ([supportedModes](https://developer.apple.com/documentation/appintents/appintent/supportedmodes), [IntentModes](https://developer.apple.com/documentation/appintents/intentmodes)). Minimum appky je iOS 26, takže stačí nové API.
- **Zvuk a Siri:** `AudioPlaybackIntent` hovorí systému, že intent púšťa zvuk, a Siri potom nepridáva vlastné dialógy, ktoré by ho prerušili ([AudioPlaybackIntent](https://developer.apple.com/documentation/appintents/audioplaybackintent)). `AudioRecordingIntent` (iOS 18+) dovolí nahrávať zo spustenia intentom, ale **len kým beží Live Activity**, inak systém nahrávanie zastaví, a ukáže systémový indikátor nahrávania ([AudioRecordingIntent](https://developer.apple.com/documentation/appintents/audiorecordingintent)). To je jediná oficiálna cesta k úplne bezdotykovému kvízu na zamknutom telefóne a priamo spája obe časti tohto issue.
- **Live Activity:** potrebuje widget extension (nový target), max 8 h aktívna + 4 h na zamknutej obrazovke, statické aj dynamické dáta spolu ≤ 4 KB, nemá sieť; spustiť sa dá z appky v popredí alebo z intentu typu `LiveActivityIntent` aj na pozadí; aktualizovať z appky aj na pozadí ([Displaying live data](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)). Rozpočet aktualizácií platí pre **push** cez APNs (priorita 10 sa počíta, 5 nie) ([push updates](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications)). Trubbo počas kvízu beží (background audio) a stav pozná lokálne, takže **push ani APNs netreba**. Odpočet času sa kreslí systémovým časovačom z cieľového času, bez aktualizácie každú sekundu.
- **CarPlay:** od iOS 26 sa Live Activity z iPhonu sama ukáže na CarPlay Dashboarde v kompaktnej podobe, vlastný vzhľad cez rodinu `.small`; tlačidlá v Live Activity v CarPlay nefungujú ([custom views](https://developer.apple.com/documentation/activitykit/creating-custom-views-for-live-activities), [WWDC25 216](https://developer.apple.com/videos/play/wwdc2025/216/)). Na rozdiel od CarPlay appky (#97) na to netreba povolenie od Apple. Vodič to vie vypnúť v nastaveniach auta, hráč v nastaveniach iOS.
- **Testovanie:** `perform()` intentu sa testuje ako bežná funkcia (unit test), rozpoznanie fráz v Xcode „App Shortcuts Preview“ per jazyk, reálne „Hey Siri“ len na zariadení. Live Activity na simulátore funguje (zamknutá obrazovka, Dynamic Island na iPhone 18 Pro).

**Neoverené, overí 219.1:** či Siri na zamknutom telefóne pri intente s otvorením appky žiada odomknutie (predpoklad: áno, čo v aute s telefónom vo vrecku nie je bez rúk); ako rýchlo Siri uvoľní audio (či nezreže prvú otázku); ako anglická Siri rozumie slovu „Trubbo“; či CarPlay simulátor na mba ukazuje Dashboard s Live Activity.

## Návrh riešenia

**Skratky (App Intents).** Intenty žijú v targete appky (nie v extension), takže `perform()` beží v procese appky a siahne na ten istý zdieľaný QuizViewModel z AppState ako telefón a CarPlay (#97). Štart kvízu ide tou istou cestou ako tlačidlo Štart a CarPlay (`beginQuizStart`); NavigationModel pri štarte sám zavrie všetko otvorené, takže skratka nepotrebuje vlastnú navigáciu. Hraničné prípady (každý má test):
- kvíz už beží → appka sa len otvorí, nič sa nereštartuje,
- onboarding nedokončený, vynútená aktualizácia, údržba → appka sa otvorí tam, kde by sa otvorila aj tak,
- vyčerpaný limit otázok → bežný paywall so skúšobnou dobou (nikdy hard paywall),
- chýba povolenie mikrofónu → bežný postup appky,
- serverový prepínač vypnutý → skratka appku len otvorí na Hraj.
Kvíz beží v jazyku kvízu z appky, nie v jazyku Siri.

**Live Activity.** Nový `LiveActivityController` v AppState sleduje zdieľaný QuizViewModel rovnako ako CarPlay ovládač (jeden odber, debounce, len pri zmene stavu). Stav kvízu sa prekladá čistou funkciou na malý „snímok“ (číslo otázky, počet, skóre, fáza, koniec časomiery), rovnako ako `CarPlayScreen` pre CarPlay, a ten sa dá testovať bez systému. Live Activity sa zapne pri štarte kvízu (appka je v popredí), aktualizuje sa len pri prechode stavu (otázka, nahrávanie, vyhodnotenie, výsledok, pauza), skončí pri konci kvízu so záverečným skóre a pri ďalšom spustení appky sa upracú zabudnuté. Typ dát Live Activity je jeden súbor zdieľaný appkou aj extension. Texty v jazyku kvízu (rovnaké pravidlo ako #649 — celá appka v jazyku kvízu).

**Úplne bez rúk na zamknutom telefóne (fáza 2, len ak 219.1 potvrdí potrebu).** Intent beží na pozadí ako `AudioPlaybackIntent` + `AudioRecordingIntent` + `LiveActivityIntent`: spustí Live Activity, otázky číta a mikrofón smie počúvať, kým Live Activity beží. Dnes appka mikrofón na pozadí zámerne vždy vypína (`QuizViewModel+ScenePhase`); táto výnimka by platila len pre kvíz spustený skratkou, s indikátorom nahrávania od systému. To je produktové a súkromné rozhodnutie, preto otázka pre foundera nižšie.

## Prepínače

- **Siri/skratky:** App Shortcuts sú zakompilované, server ich zo Siri skryť nevie. Preto v1 len v buildoch bez `APP_STORE` (TestFlight, Local), do obchodnej varianty až na povel foundera. Navyše DB prepínač `shortcut_autostart_enabled` (predvolene OFF): vypnutý = skratka appku len otvorí, zapnutý = rovno spustí kvíz. Poistka, ak by automatický štart niekde zlyhal.
- **Live Activity:** DB prepínač `live_activity_enabled` (predvolene OFF), číta sa pri štarte kvízu; vypnutím sa nové nespúšťajú a bežiace sa ukončia. Vlastný prepínač v Nastaveniach appky netreba (iOS ho má v nastaveniach appky, auto v nastaveniach CarPlay).
- Oba ako #214 — odporúčaná aktualizácia a údržba: len pridané polia v `/app-config`, staré buildy ich ignorujú, popis v `docs/setup/app-switches.md`. Poradie zapínania: Founder skupina → family+friends → Public beta → obchod.

## Úlohy

- [ ] **219.1 Overenie na zariadení (spike)** — owner: agent (pripraví build a postup), founder (telefón, „Hey Siri“)
  - Čo: minimálna skratka „Start a quiz in Trubbo“ + holá Live Activity na vetve, build cez mba priamo na founderov telefón alebo TF build na jeho povel.
  - Prečo: štyri neoverené predpoklady vyššie rozhodujú, či stačí fáza 1 a ako vyzerá 219.4.
  - Hotové: zapísané odpovede (zamknutý telefón, useknutá prvá otázka áno/nie, rozpoznanie „Trubbo“ v en Siri, Dashboard na CarPlay simulátore na mba), rozhodnutie o fáze 2 s founderom. Vetva sa nemerguje.
- [ ] **219.2 Návrh vzhľadu (HTML varianty)** — owner: agent → výber founder
  - Čo: 2–3 varianty Live Activity (zamknutá obrazovka, Dynamic Island kompakt/minimal/rozbalený, CarPlay `.small`, StandBy) v stavoch otázka, počúvam, výsledok, pauza, koniec; plus riadok „Siri a skratky“ v Nastaveniach. Svetlá aj tmavá, sk/cs/en, obsah na prvom mieste, pokojne, bez animácií navyše.
  - Prečo: UI ide vždy najprv cez HTML varianty; Live Activity sa pozerá krátko a z diaľky.
  - Hotové: founder vybral variant v artefakte; výber zapísaný sem.
- [ ] **219.3 Serverové prepínače** — owner: agent (backend, quiz-agent)
  - Čo: `live_activity_enabled`, `shortcut_autostart_enabled` v DB prepínačoch a v `/app-config`, doplnený `app-switches.md`.
  - Prečo: zapínanie po skupinách testerov a okamžité vypnutie bez nového buildu.
  - Hotové: testy zapnutia/vypnutia naživo a zlých hodnôt zelené, OpenAPI kontrola (`Backend CI gate`) prejde, nasadené; oba OFF.
- [ ] **219.4 Skratky a Siri (App Intents)** — owner: agent (iOS)
  - Čo: dve skratky podľa odpovede foundera (predvolene „štart kvízu“ a „dnešná výzva“), frázy v angličtine (2–3 varianty na skratku, s názvom appky), názvy a popisy sk/cs/en; hraničné prípady z návrhu; riadok „Siri a skratky“ v Nastaveniach podľa 219.2 (odkaz do appky Skratky, pri sk/cs vysvetlenie, že Siri treba povedať po anglicky); len mimo `APP_STORE`.
  - Prečo: jadro požiadavky; jeden vstup, rovnaký štart ako tlačidlo.
  - Analytika v tom istom PR: nový zdroj štartu `shortcut` v `quiz_context.entry_point` (taxonómia na serveri, `analytics-events.md`, iOS `QuizEntryPoint`).
  - Hotové: unit testy `perform()` pre každý hraničný prípad (vypnutý prepínač, beží kvíz, onboarding, údržba, limit), frázy prejdú v App Shortcuts Preview, identifikátory na novom riadku (lint), snímky Nastavení nahraté vedome, CI zelené.
- [ ] **219.5 Podpis a build pre extension** — owner: agent, súhlas founder (zdieľaná podpisová infra)
  - Čo: nový target widget extension s vlastným bundle ID (napr. `com.missinghue.hangs.LiveActivity`), App ID v Apple účte, `NSSupportsLiveActivities` v Info.plist appky, match profily pre appku aj extension, `ios-release.yml` a fastlane podpisujú oba; CI build pre Debug aj Release.
  - Prečo: archív pre TestFlight inak padne na profile (rovnaký problém ako pri Sign in with Apple v #61); nový bundle ID potrebuje nový profil, nie len regeneráciu.
  - Hotové: Release-Prod sa skompiluje lokálne, `match` profily overené dekódovaním, testovací archív v CI prejde (bez nahrania do TF, ak founder nepožiada).
- [ ] **219.6 Live Activity** — owner: agent (iOS)
  - Čo: `LiveActivityController` + čistý prevod stavu na snímok, vzhľad z 219.2 vrátane CarPlay `.small`, časomiera zo systémového časovača, koniec so záverečným skóre, upratanie po páde, rešpektuje `live_activity_enabled` a vypnutie v iOS. Bez tlačidiel, ak founder nerozhodne inak.
  - Prečo: prehľad mimo appky, aj na CarPlay ešte pred povolením #97.
  - Analytika v tom istom PR: `live_activity_started` s výsledkom `started / disabled_by_user / failed` pri štarte kvízu (taxonómia, doc, iOS).
  - Hotové: testy prevodu pre každý `QuizState` a pauzu (TestClock, žiadne reálne čakanie), test, že sa neaktualizuje častejšie ako pri zmene stavu, textový kontrakt pohľadov sk/cs/en; snímka simulátora iPhone 18 Pro (zamknutá obrazovka + Dynamic Island) cez `ios-ui-driver`; CI zelené.
- [ ] **219.7 Fáza 2: kvíz bez rúk na zamknutom telefóne** — owner: agent, rozhodnutie founder; len ak 219.1 a founder povedia áno
  - Čo: skratka beží na pozadí (zvuk + nahrávanie + Live Activity), výnimka z pravidla „mikrofón na pozadí nikdy“ len pre takto spustený kvíz, so systémovým indikátorom.
  - Prečo: „Hey Siri“ s telefónom vo vrecku inak skončí výzvou na odomknutie.
  - Hotové: deterministické testy pravidla mikrofónu (pozadie bez Live Activity = vypnutý, so skratkou + Live Activity = smie), test na zariadení founderom, poznámka do App Review (prečo appka nahráva na pozadí).
- [ ] **219.8 Regresia a dokumentácia** — owner: agent
  - Čo: RS scenár „štart zo skratky“ (UI test spustí intent cez testovací vstup, nie hlasom) a „Live Activity počas kvízu“, zápis do `regression-scenarios.md`; krátky návod na ručný test Siri do `docs/setup/`; riadok v TODO.
  - Hotové: RS scenáre zelené v CI, návod existuje, issue aktualizované.

## Poradie a riziká

219.1 a 219.2 bežia súbežne (spike neblokuje návrh). Potom 219.3 → 219.4 (skratky sú užitočné aj bez Live Activity) → 219.5 → 219.6 → podľa rozhodnutia 219.7 → 219.8. Každé samostatné PR.

- **Siri a náš vlastný mikrofón:** ak Siri ešte drží audio, keď appka spustí prvú otázku, môže ju zrezať alebo sa mikrofón otvorí do Siri odpovede. Riešenie hľadáme v existujúcom ošetrení prerušení zvuku (#67), nie novým čakaním naslepo; overí 219.1.
- **„Trubbo“ v anglickej Siri:** neštandardné slovo sa môže zle rozpoznávať; ak áno, pridať alternatívne vyslovenie názvu appky (overiť, či App Shortcuts berú `INAlternativeAppNames`).
- **Podpis:** nový target je jediná zmena podpisovej infra od #61; bez neho TF archív padne.
- **App Review:** nahrávanie na pozadí (219.7) treba v poznámke pre review vysvetliť; bez 219.7 sa nič nemení.
- **Bez push:** keď systém appku počas kvízu ukončí, Live Activity zastará; nastaví sa čas zastarania a pri ďalšom spustení sa upracú.

## Otázky pre foundera

1. **Ktoré skratky?** Odporúčam dve: „Start a quiz in Trubbo“ (posledné nastavenia, náročnosť Náhodná) a „Play today's Trubbo challenge“ (dnešná výzva). Výber témy hlasom (napr. „start a history quiz“) až neskôr, ak bude záujem.
2. **Siri po slovensky a česky nevie. Čo s tým?** Odporúčam: frázy po anglicky, kvíz aj tak beží v jazyku kvízu z appky; v Nastaveniach jeden riadok „Siri a skratky“ s vetou, že Siri treba povedať po anglicky, a s ponukou dať si skratku na tlačidlo Action alebo do Spotlightu (tie fungujú v každom jazyku).
3. **Čo ukazuje Live Activity?** Odporúčam: číslo otázky, skóre, zostávajúci čas a jedno slovo stavu (Počúvam, Vyhodnocujem, Správne / Nesprávne). Text otázky len na zamknutej obrazovke (max 2 riadky), v Dynamic Islande a na CarPlay nie. Bez tlačidiel (povely hlasom už existujú). Finálny vzhľad vyberieš z HTML variantov (219.2).
4. **Kvíz na zamknutom telefóne úplne bez rúk (mikrofón na pozadí so systémovým indikátorom)?** Odporúčam: v1 nie, skratka otvorí appku (telefón sa odomkne tvárou); o fáze 2 rozhodneme po teste na tvojom telefóne (219.1).
