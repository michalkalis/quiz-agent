# Research: Cross-platform vs natívny vývoj mobilných appiek — z pohľadu testovateľnosti pre AI agenta (Claude Code)

**Dátum:** 2026-06-02 · **Query:** Trendy a best practices okolo React Native / Flutter / KMP vs natívny vývoj; vnímateľnosť native vs hybrid; **hlavne** testovateľnosť z pohľadu AI agenta (feedback loop), web/Playwright testovanie, a testovanie audio/voice funkcionality.

---

## Zhrnutie (TL;DR)

- **Adopcia:** Cross-platform trh ovládajú Flutter (~46 %) a React Native (~35 %), spolu 80 %+ nových cross-platform appiek. Natívny vývoj zostáva silný najmä tam, kde appka stojí na platformovo špecifických API (presne tvoj prípad — voice/Speech na iOS 26). Kotlin Multiplatform rýchlo rastie (7 % → 23 % za rok), ale je to skôr „shared logika", nie shared UI.
- **Vníma to user?** V roku 2026 prakticky nie. Výkonový rozdiel sa zmazal (RN New Architecture / Fabric, Flutter Impeller 2.0). Bežný používateľ nerozozná native od cross-platform; rozdiel cítiť len na grafiky náročných animáciách.
- **Hlavná pointa pre teba:** Cross-platform **sám o sebe agentovi nezjednoduší UI testovanie** — moderné nástroje (Maestro MCP, XcodeBuildMCP) fungujú rovnako dobre na natívnej iOS appke. Jediná reálna výhoda cross-platformu pre agentov je **spustenie v prehliadači + Playwright**, a tú má zmysluplne **iba React Native Web** (reálny DOM). Flutter Web renderuje do canvasu, kde Playwright „nevidí" elementy — testovateľnosť horšia než u natívu.
- **Voice/audio je úzke hrdlo na všetkých platformách rovnako.** Simulátory mikrofón reálne nemockujú; voice E2E vyžaduje injekciu nahraného audia (Perfecto, Botium) alebo reálne zariadenie. Cross-platform frameworky aj tak len premostia na tie isté natívne Speech API, takže na najťažšej časti **nezískaš nič** — skôr pridáš vrstvu navyše.
- **Odporúčanie:** Nemigrovať. Voice-first + závislosť na iOS 26 SpeechAnalyzer ruší jedinú agent-testing výhodu cross-platformu (web/Playwright loop sa na voice aj tak nedá použiť). Radšej vylepši loop, ktorý už máš (screenshoty na vizuálnu kontrolu, mockovanie transkriptov pri voice, prípadne Maestro MCP na simulátore).

---

## Kľúčové zistenia

### 1. Adopcia a trendy 2025–2026

Flutter a React Native spolu pokrývajú 80 %+ trhu cross-platform appiek. Podľa dát Flutter drží ~46 % cross-platform podielu, React Native ~35–38 % (Statista forecast). Náskok RN z roku 2023 (51 % vs 29 %) sa otočil — takmer 30 % nových *free* iOS appiek v App Store 2025 bolo postavených na Flutteri (vs ~10 % v 2021), RN ~15–18 %.

Veľké firmy: **Flutter** — Alibaba, Google Pay, BMW, Nubank (najväčšia LatAm digitálna banka, hlásili +30 % merge success rate oproti natívu). **React Native** — Meta (FB rodina appiek, 2 mld+ používateľov), Shopify, Microsoft. **Kotlin Multiplatform** rastie najrýchlejšie (7 % → 23 %), ale rieši hlavne zdieľanie biznis logiky, UI necháva natívne.

Natívny vývoj nezomiera — zostáva default tam, kde je appka tesne previazaná s platformovými API (kamera, ML, **speech/audio**, widgety, system integrácie). To je relevantné, lebo tvoja appka je presne taká.

### 2. Vie user rozoznať native vs cross-platform?

V roku 2026 prakticky **nie**. Citujem zo zdrojov: „Most users cannot tell whether an app is native or React Native" a „it is nearly impossible to tell whether your program was developed using native technology or a cross-platform framework". Výkonové rozdiely existujú na papieri (cold start, FPS pri ťažkých animáciách), ale bežný používateľ ich pri normálnom používaní nepostrehne. RN New Architecture znížila latenciu z ~16 ms na <2 ms a štart o ~50 %; Flutter Impeller 2.0 drží 120 FPS bez janku. **Výkon už nie je rozhodovací faktor.**

Záver: z pohľadu „ako to vyzerá navonok" nemáš dôvod meniť stack. Rozhodnutie stojí čisto na DX a testovateľnosti.

### 3. ⭐ Testovateľnosť pre AI agenta (jadro otázky)

Tu treba oddeliť tri veci:

**(a) Build-test-fix loop na natívnej iOS appke je dnes veľmi dobrý.**
XcodeBuildMCP (82 nástrojov) dáva Claude Code headless prístup k buildu, simulátoru, testom, LLDB a UI automatizácii. Kľúčový nástroj `snapshot_ui` vráti všetky UI elementy na obrazovke ako štruktúrované dáta s accessibility ID — agent ich „vidí" a vie na ne klikať. Loop „agent napíše kód → buildne → prečíta štruktúrovanú chybu JSON → opraví → spustí testy" beží autonómne bez otvoreného Xcode. Toto už máš (tvoj `regression` skill + HTTP listener harness na RS scenáre presne tento loop využíva).

**Známe trecie body natívu (a teda čo cross-platform NErieši alebo rieši inak):**
- **`.pbxproj` bariéra** — agent nesmie editovať projektový súbor, ľahko ho rozbije (rieši sa PreToolUse hookom). Cross-platform projekty (najmä Expo/RN) tento problém väčšinou nemajú — config je v JSON/JS.
- **Vizuálna slepota** — agent skompiluje SwiftUI layout, ktorý sa zle vyrenderuje (preklepy v spacingu, prekrytia), a build chybu nedostane. **Riešenie = screenshoty**, ktoré fungujú aj na simulátore. Tento gap má *každá* platforma rovnako.
- **Metal shadery / GPU kód** — neviditeľné pre agenta (case study: shader skompiloval, ale bol biely kvôli 10× zlým koeficientom). Okrajové pre teba.

**(b) Cross-platform NEdáva výhodu v UI testovaní cez MCP.**
Maestro MCP (napojený na Claude) funguje **rovnako** na Flutter, React Native aj natívnej iOS/Android appke — pracuje proti skompilovanému IPA/APK, bez inštrumentácie. Agent vie generovať YAML flowy z prirodzeného jazyka, inšpektovať view hierarchiu, ovládať simulátor. Čiže: ak chceš bohatšie natural-language UI testovanie, **pridáš Maestro MCP k natívnej appke** a nemusíš nikam migrovať. Toto je konkrétny lacný upgrade tvojho loopu.

**(c) Jediná reálna agent-testing výhoda cross-platformu = beh v prehliadači + Playwright.**
Toto je tá vec, na ktorú sa pýtaš. Áno, existuje — ale s veľkým rozdielom medzi frameworkami:
- **React Native Web** renderuje **reálny DOM** → Playwright / Playwright MCP ho vie ovládať spoľahlivo, rýchlo, so screenshotmi aj DOM selektormi. Toto je najlepší možný feedback loop pre agenta: bez simulátora, sekundové iterácie, agent „vidí" aj štruktúru aj pixely.
- **Flutter Web** renderuje do **canvasu (CanvasKit)** → Playwright/Selenium „nevidia" buttony ani inputy v DOM. Lokácia ide len cez accessibility/semantics strom, je krehká, a sú s tým bugy (napr. nedá sa programaticky napísať do inputu pri `excludeSemantics`). **Pre agenta horšie než natív.**
- **Pozor na limit:** Playwright ovláda len web/WebView, **nie** natívne UI a **nie** natívne dialógy (permission prompty rieši ADB/Appium). A hlavne — web build je iná povrchová plocha než produkčná natívna appka; testuje logiku a layout, nie reálne platformové správanie.

> **Dôsledok pre teba:** web/Playwright loop je super, ale tvoja appka stojí na voice, a **voice sa v prehliadači aj tak otestovať nedá** (mikrofón/Speech API). Takže jediná výhoda cross-platformu, ktorá by ti reálne pomohla, sa o tvoj hlavný use-case obíja.

### 4. Testovanie audio / voice — úzke hrdlo na všetkých platformách

Toto je najťažšia časť a je **rovnako ťažká natívne aj cross-platform**:

- **Voice E2E** znamená: injektnúť nahrané/syntetické audio na vstup (STT) a zachytiť TTS výstup a previesť späť na text na validáciu. Simulátory mikrofón normálne nemockujú.
- **Nástroje:** Perfecto (cloud, injekcia audio súborov do zariadenia + preklad výstupu späť na text), Botium/Cyara (konverzačné AI testovanie, CI/CD), prípadne Appium s custom audio handlingom. Modernejšie voice-agent eval nástroje (Braintrust, Evalion) simulujú prerušenia, prízvuky, hluk — ale to je skôr na server-side voice agentov než na iOS Speech.
- **Reálne audio E2E** prakticky vyžaduje **reálne zariadenie** alebo cloud device farm. Na simulátore to nejde čisto.
- **Best practice (a to už čiastočne robíš):** abstrahuj voice vrstvu za rozhranie a testuj **logiku s mocknutými transkriptmi/intentmi**, nie reálne audio. Tvoj HTTP listener fallback na spúšťanie UI testov (z pamäte: iOS 26 URL scheme bug) je presne ten typ riešenia — voice príkaz nahradíš injektnutým eventom.

**Kľúčové:** iOS 26 SpeechAnalyzer je natívne, cutting-edge API. Akýkoľvek cross-platform framework by naň musel **premostiť** — t.j. na najťažšej časti tvojej appky nezískáš testovaciu výhodu, len pridáš bridging vrstvu, ktorá môže zlyhať a ktorú treba tiež testovať.

---

## Implikácie pre Quiz Agent

1. **Voice-first + iOS 26 Speech je dominantná podmienka.** Ona ruší jedinú agent-testing výhodu cross-platformu (web/Playwright loop), pretože voice sa v prehliadači netestuje. To je rozhodujúci argument proti migrácii.
2. **Loop, ktorý už máš, je dobrý a zhodný s best practice 2026:** XcodeBuildMCP (build-test-fix headless) + `snapshot_ui` + regression skill + HTTP listener na injektovanie príkazov. Presne takto vyzerá state-of-the-art natívny agent loop.
3. **Hlavný gap natívu — „agent nevidí render" — sa rieši screenshotmi**, nie zmenou frameworku. Stojí za to mať vo verify/regression loope povinný screenshot + (voliteľne) vizuálnu kontrolu cez druhý agent prechod.
4. **Cieľ „prompt z telefónu → auto-implement → auto-deploy na TestFlight" je iOS-špecifický** a postavený na fastlane/match/XcodeBuildMCP. Migrácia by tento hotový pipeline rozbila.
5. **Switching cost je vysoký, user-facing upside nulový** (parita výkonu aj UX).

---

## Odporúčania

1. **Zostať natívne (SwiftUI).** Pre voice-first appku viazanú na iOS 26 Speech je to správna voľba a cross-platform by agentský loop nezlepšil — na voice časti by ho skôr skomplikoval.
2. **Lacný upgrade loopu A — Maestro MCP na simulátore.** Pridaj Maestro ako MCP server k natívnej appke: dostaneš natural-language UI flowy, inšpekciu view hierarchie a debug zlyhaní cez Claude, bez migrácie. Dobré doplnenie k existujúcim RS scenárom.
3. **Lacný upgrade loopu B — povinné screenshoty vo verify kroku.** Zacieli na jediný reálny natívny gap (vizuálna slepota agenta). Po každej UI zmene: build → screenshot → agent porovná oproti očakávaniu.
4. **Voice testuj na úrovni logiky, nie audia.** Drž voice vrstvu za rozhraním; v testoch injektuj transkripty/intenty (rozšír HTTP listener pattern). Reálne audio E2E nechaj na občasný manuálny beh na reálnom zariadení; ak by to niekedy bolo kritické, zváž Perfecto/cloud device farm s audio injekciou.
5. **Ak raz pôjdeš do web-ui companionu, tam má Playwright zmysel.** Web verzia (React/Next, nie Flutter canvas) dá agentovi rýchly DOM+screenshot loop — ale ber to ako *doplnkovú* plochu, nie náhradu iOS appky.
6. **Sleduj, ale neadoptuj zatiaľ:** ak by si niekedy potreboval Android, najlacnejšia cesta s minimálnym dopadom na agent loop je RN/Expo (reálny DOM web build = najlepšia Playwright testovateľnosť), nie Flutter. Ale to je post-MVP rozhodnutie a voice časť ostane natívny bridging tak či tak.

---

## Zdroje

1. [Flutter vs React Native: 46% vs 35% Market Share 2026 — tech-insider.org](https://tech-insider.org/flutter-vs-react-native-2026/) — podiely na trhu, podiel nových App Store appiek.
2. [Flutter vs React Native in 2026 — TechAhead](https://www.techaheadcorp.com/blog/flutter-vs-react-native-in-2026-the-ultimate-showdown-for-app-development-dominance/) — enterprise adopcia, firmy (Nubank, BMW, Alibaba).
3. [Why the 'New Architecture' and Impeller 2.0 Changed Everything — Bolder Apps](https://www.bolderapps.com/blog-posts/flutter-vs-react-native-in-2026-why-the-new-architecture-and-impeller-2-0-changed-everything) — výkonová konvergencia 2026.
4. [Kotlin Multiplatform vs Flutter vs React Native: 2026 Reality — JavaCodeGeeks](https://www.javacodegeeks.com/2026/02/kotlin-multiplatform-vs-flutter-vs-react-native-the-2026-cross-platform-reality.html) — rast KMP 7 %→23 %.
5. [Flutter vs React Native vs Native: 2025 Performance Benchmark — Synergyboat](https://www.synergyboat.com/blog/flutter-vs-react-native-vs-native-performance-benchmark-2025) — „users cannot tell" + benchmarky.
6. [Maestro MCP + Claude: AI-Powered Mobile UI Test Automation — Very Good Ventures](https://verygood.ventures/blog/maestro-mcp-claude-mobile-ui-test-automation/) — Maestro MCP funguje rovnako pre Flutter/RN/native; conversational feedback loop.
7. [Automating iOS App Testing with Claude Code and XcodeBuildMCP — zenn.dev](https://zenn.dev/shimo4228/articles/xcodebuildmcp-ios-verification?locale=en) — `snapshot_ui`, headless build-test-fix loop na simulátore.
8. [Building iOS Apps with AI Agents: The Practitioner's Guide — Blake Crosley](https://blakecrosley.com/guides/ios-agent-development) — reálne trecie body natívu (.pbxproj, vizuálna slepota, shadery).
9. [Reliable Flutter Web Automation Without Image-Based Hacks — DevAssure](https://www.devassure.io/blog/flutter-web-automation-devassure/) + [Flutter Playwright Testing Guide — Autonoma](https://getautonoma.com/blog/flutter-playwright-testing-guide) — Flutter web = canvas, Playwright nevidí DOM; RN Web = reálny DOM.
10. [Playwright MCP for Mobile App Testing — Panto](https://www.getpanto.ai/blog/playwright-mcp-for-mobile-app-testing) — Playwright len web/WebView, nie natívne UI/dialógy.
11. [Voice Application Testing: Tools and Frameworks — Medium/Antony Berlin](https://medium.com/@antonyberlin2003/voice-application-testing-tools-and-frameworks-for-the-conversational-age-06bdf97276c5) + [Test Voice Recognition — Perfecto](https://www.perfecto.io/blog/test-voice-recognition-perfecto) — injekcia audia, STT/TTS validácia, cloud device farm.
