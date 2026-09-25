# Research: Ako lepšie dizajnovať mobilnú appku (nástroje, UI/UX, design systém pre agentický vývoj)

**Date:** 2026-09-25 | **Query:** Ako lepšie dizajnovať iOS appku: nástroje s MCP (pen.dev, Mobbin, Figma…), oficiálne odporúčania, trendy, čo používajú iOS vývojári; konkrétne rady na UI/UX; jednotný design systém + knižnica komponentov, ktorá funguje pre agentický vývoj a kde founder vidí prehľad a môže komentovať bez terminálu.

## Executive Summary

- **Najväčší problém nie je nástroj, ale chýbajúci jeden zdroj pravdy.** V appke dnes žijú tri paralelné sady tokenov (pôvodná `Theme.*`, novšia `Theme.Hangs.*`, samostatné fonty v `Font+Theme`) + „legacy aliasy“. Agent si z toho vyberá náhodne → nejednotný vzhľad. Prvý krok = zlúčiť do jednej sady a zakázať ručne písané hodnoty lintom.
- **Pencil (pen.dev) nechať ako skicár, nie ako zdroj pravdy.** Má MCP, je zadarmo a vie SwiftUI export, ale review je „git-ový“, nie komentárový — pre foundera slabý. Zdroj pravdy pre agentický vývoj má byť **kód** (tokeny + komponenty), všetko ostatné sa z neho generuje.
- **Prehľad + komentovanie bez terminálu:** najlacnejšia cesta je **Design System artefakt na claude.ai** (máme ho k dispozícii zadarmo): tokeny, komponenty s náhľadmi, pravidlá, komentáre priamo na komponent, a agenti ho čítajú ako referenciu. Náhľady plníme skutočnými SwiftUI snapshotmi z testov, takže founder vidí reálnu appku, nie web napodobeninu. Figma (~$16/mes.) je lepšia v komentovaní, ale znamená druhý zdroj pravdy a migráciu z Pencilu.
- **Mobbin má od 05/2026 oficiálne MCP** (620k+ obrazoviek reálnych appiek, ~$10/mes. ročne) — hodnota pre výskum vzorov (onboarding, paywall, povolenia), nie na generovanie kódu. Oplatí sa ako mesačný „research sprint“, nie trvalé predplatné.
- **UI/UX pre Hangs:** hlas je primárne rozhranie, obrazovka len na pohľad (≤ 2 s pohľad, ≤ 12 s spolu — NHTSA); Liquid Glass len na navigačnej vrstve, obsah nepriehľadný; mierna spätná väzba pri zlej odpovedi, oslavy len na prirodzených koncoch; mikrofón pýtať v kontexte prvej otázky s pred-vysvetlením.

## Key Findings

### 1. Nástroje: kto čo vie a čo z toho má zmysel pre nás

| Nástroj | MCP | Silné stránky | Slabiny pre nás | Cena |
|---|---|---|---|---|
| **Pencil / pen.dev** (dnes) | áno, lokálne | agent číta/píše návrh, premenné (tokeny), export aj do SwiftUI | review cez git/PR, žiadne pohodlné komentáre; tokeny sú „web-štýlové“, nie priamy Swift | zadarmo (zatiaľ) |
| **Figma** | áno (Dev Mode MCP) | najlepšie komentáre (klik na prvok), Code Connect podporuje SwiftUI, oficiálny Apple iOS 26 kit | druhý zdroj pravdy popri kóde, migrácia z Pencilu, Figma Make generuje len web | ~$16/os./mes. |
| **Mobbin** | áno, oficiálne od 2026-05 | 620k obrazoviek / 142k tokov reálnych appiek → agent si pred návrhom pozrie, ako to riešia top appky | len inšpirácia, nie kód | free obmedzené, Pro ~$10/mes. |
| **Refero** | áno | podobné ako Mobbin | menší katalóg mobilu | platené |
| **Xcode 26.3 + Claude** | áno (Xcode MCP) | agent si vie vyrenderovať SwiftUI Preview a overiť komponent bez spúšťania celej appky | — | zadarmo |
| Magic Patterns, v0, Stitch, Subframe, UX Pilot | rôzne | rýchle skice | generujú web (React), nie SwiftUI | — |
| Judo | nie (neoverené) | natívny SwiftUI canvas | vlastný runtime, mimo nášho kódu | — |
| Play.new | — | bol SwiftUI prototyper | Apple ho kúpil a stiahol, nepoužiteľný | — |

Čo hovoria praktici (X, Reddit, blogy 2026): „vibe design“ = iterovať dizajn promptmi; indie iOS vývojári najčastejšie dajú agentovi screenshot/design systém ako smer a potom iterujú cez **screenshoty zo simulátora**. Rozšírené sú open-source **SwiftUI agent skills** (Paul Hudson, Antoine van der Lee), ktoré bránia agentovi písať zastaraný SwiftUI kód. Pencil je vnímaný ako nástroj „pre ľudí, čo už pracujú s coding agentmi“, výslovne nie pre bežné netechnické review.

### 2. Oficiálne Apple odporúčania (iOS 26, Liquid Glass)

- **Sklo patrí len navigačnej vrstve** (toolbar, tab bar, plávajúce ovládače), nikdy obsahu. Nevrstviť sklo na sklo, jeden „edge effect“ na obrazovku. → Karta otázky a odpovede ostávajú nepriehľadné.
- **Kapsuly = dotykové ciele** — veľké tlačidlá tvaru kapsuly sú aj Apple signál „toto sa dá stlačiť“; sedí pre jednoruké ovládanie.
- **Nad tab barom je nový „accessory“ priestor**, ktorý ostáva pri prepínaní tabov — prirodzené miesto pre trvalý mikrofón / stav počúvania.
- **Ikona cez Icon Composer** (vrstvená, prežije Default/Dark/Clear/Tinted varianty).
- **Pozor na posun:** Apple už v iOS 26.1 pridal prepínač priehľadnosti skla; ďalšie zmierňovanie v iOS 27 je podľa sekundárnych zdrojov (NEOVERENÉ). Nestavať dizajn na maximálnej priehľadnosti.

### 3. Hands-free a hlas (jadro Hangs)

- **NHTSA:** jeden pohľad ≤ 2 s, spolu ≤ 12 s mimo cesty. CarPlay HIG: pri hlasových appkách je hlas **predvolený** spôsob a obrazovka nesmie byť „odpoveďou“ na hlasovú interakciu. → Každá obrazovka počas kvízu: jedna hlavná akcia, čitateľná na jeden pohľad; nič sa nesmie dať *iba* prečítať.
- **Ticho > 3 s po reči pôsobí ako pád** — vždy krátky zvuk pre „počúvam / spracúvam / správne / chyba“ (sedí s naším pravidlom tichých earconov + haptiky).
- **Skákanie do reči (barge-in)** robia ľudia až v ~25 % ťahov → pri prerušení okamžite stopnúť hlas a zachovať stav.
- **Oprava chyby:** nepýtať sa znova celé, len chýbajúcu časť („Ktorú možnosť — B alebo C?“).

### 4. Hra, onboarding, paywall, prístupnosť

- **Spätná väzba ako Duolingo:** správne = krátky zvuk + jemná animácia; zle = mierne, nie trestajúce (žiadna červená stena). Séria (streak) má vlastný výraznejší moment. **Veľké oslavy len na konci kola**, nie počas jazdy.
- **Mikrofón pýtať v kontexte** (pri prvej otázke) s pred-obrazovkou „prečo to potrebujeme“ — zvyšuje súhlas o ~20–30 %.
- **Paywall:** kratší a s jednou jasnou voľbou konvertuje lepšie (RevenueCat 2025–26). Od 02/2026 Apple zamieta paywally s prepínačom „free trial“ — my trial nemáme, len ho nezavádzať.
- **Lokalizácia:** SK/CS reťazce testovať naostro (žiadne pevné šírky, jednoriadkové hero texty so zmenšovaním — už máme pravidlo); presné % rozšírenia pre SK/CS sa nepodarilo overiť.
- **Trend 2026:** „zdržanlivé“ sklo (kontrastný text na pevnom podklade), mikroanimácia spárovaná s haptikou v kľúčovom momente. Prežité: priehľadnosť na obsahu a interaktívnych prvkoch.

### 5. Design systém, ktorý funguje pre agenta

- **Tokeny v dvoch vrstvách:** základné hodnoty (farba `coral-500`, medzera `space-4`) a významové (`action-background → coral-500`). Významové smú ukazovať len na základné → zmena značky = úprava jedného súboru. Formát DTCG (stabilný od 10/2025) je de-facto štandard výmeny medzi nástrojmi.
- **SwiftUI štruktúra:** tokeny ako konštanty → nad nimi `ButtonStyle`/`ViewModifier` a malé komponenty; obrazovky skladajú len tieto kocky. Vzor na učenie: Orange `ouds-ios` (+ jeho showcase appka).
- **Čo reálne drží agenta v koľajach** (viacero zdrojov 2026): (1) textový súpis tokenov a komponentov, ktorý agent číta pred prácou, (2) **lint v CI, ktorý zhodí build pri ručnej farbe/veľkosti/odsadení**, (3) náhľad/galéria, cez ktorú agent aj človek vidí výsledok. Bez lintu agenti tokeny vymýšľajú a v rámci session „driftujú“.
- **Galéria komponentov z `#Preview`:** nástroje Prefire, swift-storybook, Phonebook (MCP-first, statické HTML, NEOVERENÁ zrelosť). Hostované vizuálne review s komentármi pre PR: Emerge Tools Snapshots (používa napr. iOS appka OpenAI; Emerge dnes patrí pod Sentry, ktorý už používame — cenu/dostupnosť treba overiť).

### 6. Náš súčasný stav (recon 2026-09-25, main)

- 3 paralelné sady tokenov + legacy aliasy; farby takmer všade cez tokeny (1 výnimka), rohy 100 % tokeny, ale **59× ručná veľkosť písma** (najviac Paywall, Home, HangsButton), 23× ručné odsadenie, 9× systémová farba natvrdo.
- 14 zdieľaných komponentov (`Views/Components/Hangs/`) + 4 štýly tlačidiel; 44 `#Preview`; pixel snapshoty 4 hlavných obrazoviek × 3 jazyky × 2 veľkosti písma (od #180); žiadna galéria komponentov.
- Pravidlá pre layout/tokeny existujú (`ios-swiftui-layout.md`), ale sú necommitnuté a nič ich automaticky nevynucuje.
- Proces „HTML varianty → founder vyberie → Pencil → kód“ funguje pre veľké rozhodnutia, ale nemá trvalé miesto na komentáre.

## Implications for Hangs

Nástroj na kreslenie nie je úzke hrdlo — agent už vie kresliť v Penciliu aj písať SwiftUI. Úzke hrdlá sú dve: **(a)** agent nemá jednu jednoznačnú sadu pravidiel a nič ho nekontroluje, **(b)** founder nemá jedno miesto, kde vidí „toto je náš vizuál“ a kde môže napísať „tento stav je zlý“. Obe rieši jednotný design systém v kóde + z neho generovaný katalóg s komentármi.

## Recommendations

1. **Zlúčiť tokeny do jednej sady** (`Theme.Hangs` ako jediná, staré `Theme.*` a paralelné fonty preklopiť a zmazať), dvojvrstvovo (základné → významové). Pripojiť `ios-swiftui-layout.md` do repa.
2. **Lint na ručné hodnoty v CI** (farby, veľkosti písma, odsadenia mimo token súborov; výnimky len cez pomenovanú `Metrics` konštantu). Najprv spraviť súčasných ~90 výskytov, potom gate.
3. **Katalóg = Design System artefakt na claude.ai**, generovaný z kódu: README (značka, tón, pravidlá), tokeny, každý komponent s popisom „kedy použiť“ a obrázkom zo skutočného SwiftUI snapshotu (rozšíriť snapshoty z 4 obrazoviek aj na komponenty a ich stavy). Founder komentuje priamo na komponent; agent komentáre na začiatku UI práce prečíta a zapracuje. Artefakt sa po každom design PR preregeneruje (nikdy ručne, aby neodišiel od kódu).
4. **Pencil ponechať na skice a nové obrazovky**; po schválení sa hodnoty prepíšu do kódu a Pencil premenné sa synchronizujú z tokenov (nie naopak).
5. **Doplniť agentovi SwiftUI skill** (Hudson / van der Lee) a zapnúť Xcode MCP render Preview, aby si komponenty overoval sám a lacnejšie než celou appkou.
6. **Mobbin Pro na 1 mesiac** ako research sprint pred redizajnom onboardingu/paywallu (povolenia mikrofónu, paywall, prázdne a chybové stavy) — len so súhlasom (útrata).
7. **UI/UX checklist pri každej UI zmene:** jedna hlavná akcia na obrazovku, čitateľné na 2 s; hlas nikdy nevyžaduje čítanie; zvuk do 3 s pri každom ťahu; sklo len na navigácii; zlá odpoveď mierne, oslava na konci kola; test s SK/CS + veľkým písmom.
8. **Figma zvážiť len ak** artefakt s komentármi nebude stačiť (napr. príde externý dizajnér). Vtedy Figma ako hub + Code Connect na SwiftUI, Pencil preč.

## Sources

1. [pen.dev — AI integration](https://docs.pencil.dev/getting-started/ai-integration) — MCP, komponenty, premenné
2. [pen.dev — variables](https://docs.pencil.dev/core-concepts/variables) — tokeny v Penciliu
3. [pen.dev pricing](https://www.pen.dev/pricing) — zatiaľ zadarmo
4. [Atomize — Figma vs Pencil](https://atomize.tools/blog/figma-vs-pencil-design-system/) — git-review vs komentáre
5. [banani.co — Pencil review](https://www.banani.co/blog/pencil-dev-review) — cieľovka Pencilu
6. [Businesswire — Mobbin MCP](https://www.businesswire.com/news/home/20260511053592/en/Mobbin-Launches-MCP-Server-Giving-AI-Tools-621500-Real-App-Screens-to-Reference) — launch 2026-05, rozsah
7. [Mobbin MCP repo](https://github.com/mobbin/mobbin-mcp-server) — oficiálny server
8. [Figma — Dev Mode MCP](https://www.figma.com/blog/introducing-figma-mcp-server/) — čo MCP dáva agentovi
9. [Figma — Code Connect](https://developers.figma.com/docs/code-connect) — podpora SwiftUI
10. [Apple — iOS 26 design kits](https://developer.apple.com/news/?id=pnfbj8je) — Figma/Sketch kity
11. [Anthropic — Claude in Xcode](https://anthropic.com/news/claude-in-xcode) — render Preview agentom
12. [Refero MCP](https://doc.refero.design/mcp/tools) — alternatíva k Mobbinu
13. [Korben — Apple kúpil Play](https://korben.info/en/play-apple-acquires-swiftui-prototyping-tool.html)
14. [twostraws/SwiftUI-Agent-Skill](https://github.com/twostraws/swiftui-agent-skill) — SwiftUI skill pre agentov
15. [WWDC25 — Get to know the new design system](https://developer.apple.com/videos/play/wwdc2025/356/) — pravidlá skla
16. [iOS 26 tab bar](https://medium.com/design-bootcamp/dont-design-junk-in-the-new-ios-26-tab-bar-4de8e842da89) — accessory priestor
17. [Icon Composer workflow](https://www.offform.design/how-to-create-ios-26-icon-with-icon-composer/)
18. [AppleInsider — WWDC26 glass](https://appleinsider.com/articles/26/03/15/siri-and-refined-liquid-glass-controls-on-the-docket-for-wwdc-2026) — sekundárny zdroj, neoverené
19. [CarPlay HIG — interaction](https://developer.apple.com/design/human-interface-guidelines/carplay) — hlas ako primárna modalita
20. [NHTSA distraction guidelines](https://downloads.regulations.gov/NHTSA-2013-0137-0004/attachment_11.pdf) — 2 s / 12 s
21. [Fuselab — Voice UI guide 2026](https://fuselabcreative.com/voice-user-interface-design-guide-2026/) — earcony, 3 s ticha
22. [Appcues — permission priming](https://www.appcues.com/blog/mobile-permission-priming) — pred-obrazovka povolení
23. [RevenueCat — paywall case studies](https://www.revenuecat.com/blog/growth/paywall-redesigns-case-studies) — krátke paywally, trial toggle
24. [Duolingo gamification](https://omkarghawate.medium.com/gamification-secrets-behind-duolingos-success-fb4004c27e79) — spätná väzba, séria
25. [Mobile UI trends 2026](https://www.abdulazizahwan.com/2026/02/beyond-the-glass-7-mobile-ui-trends-defining-2026.html)
26. [DTCG stable spec](https://www.w3.org/community/design-tokens/2025/10/28/design-tokens-specification-reaches-first-stable-version/) — formát tokenov
27. [Style Dictionary + SwiftUI](https://www.swiftforjs.dev/blog/style-dictionary-colours-swiftui) — generovanie Swift z tokenov
28. [Orange ouds-ios](https://github.com/Orange-OpenSource/ouds-ios) — vzorový SwiftUI design systém
29. [Design systems for LLM agents](https://www.designsystemscollective.com/design-systems-for-llm-agents-two-files-that-fix-everything-3e78b0c7427e) — súpis pre agenta
30. [hvpandya — expose DS to LLMs](https://hvpandya.com/llm-design-systems) — drift a vymýšľanie tokenov
31. [Boldare — DS for AI dev](https://www.boldare.com/blog/design-system-ai-assisted-development/) — lint na ručné hodnoty
32. [Prefire](https://github.com/AllDmeat/Prefire) · [swift-storybook](https://github.com/eure/swift-storybook) · [Phonebook](https://github.com/stag-build/phonebook) — galérie z `#Preview`
33. [Emerge Snapshots](https://www.emergetools.com/product/snapshots) — hostované vizuálne review
