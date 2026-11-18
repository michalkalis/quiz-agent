# Research: Kvalita appky z voľnej kapacity Claude Code predplatného

**Date:** 2026-11-18 | **Session:** quiz-agent-87 | **Query:** Ako využiť nevyčerpanú kapacitu predplatného Claude Code (bez API kreditu, bez ElevenLabs) na automatizované zvyšovanie kvality Trubbo: testovanie na simulátore, UX review, hĺbkový audit kódu, plánované behy. Čo naozaj funguje, čo je plytvanie, aké sú limity.

Nadväzuje na [testovanie iOS pri agentickom vývoji (2026-09-14)](ios-agentic-testing-best-practices-2026-09-14.md) a [audit so 40 agentmi (2026-07-30)](adversarial-audit-2026-07-30.md); tu sa neopakujú.

## Executive Summary

- **Z predplatného ide takmer všetko:** bežné session, subagenti, workflowy, `/code-review` (okrem `ultra`), `/security-review`, behy bez obsluhy (`claude -p` s prihlásením), GitHub Action s tokenom predplatného, cloud session aj plánované rutiny. **Zvlášť sa platí** len `/code-review ultra` (na Max 3 jednorazové behy zadarmo, potom $5–25 za beh) a čokoľvek, kde je v prostredí nastavený `ANTHROPIC_API_KEY` (vtedy beh ticho prejde na platené API). [1][2][3]
- **Voľná kapacita prepadá:** limit je 5-hodinový a týždenný, Fable má vlastný týždenný limit; prenos nevyužitej kapacity nie je nikde zdokumentovaný (neoverené). Ak sú „usage credits“ vypnuté, beh sa na limite zastaví a nič sa nedoúčtuje. [4][5]
- **iOS práca beží len na Macu.** Cloud session je Linux, takže Xcode ani simulátor tam nebežia (záver z dokumentácie prostredia, nie výslovné tvrdenie). Cloud sa hodí na server, audit kódu, web a dokumenty. [6]
- **Najsilnejšie dôkazy majú dve veci:** audit kódu viacerými agentmi s nezávislým vyvracaním každého nálezu, a mutačné testy (úmyselné chyby v kóde, ktoré majú testy chytiť). Obe sme si v júli overili sami: 59 nálezov → 21 potvrdených vrátane jednej kritickej chyby; mutačná sonda našla nestrážený dátum vypršania predplatného. [7][8][9]
- **Agent ako tester na simulátore nachádza skutočné chyby, ale 39–43 % hlásení je falošných**; zlyháva na chybách časovania, na vzhľade a na „mätúce“. Funguje s presným zadaním (pomenované okrajové prípady) a s povinným zopakovaním chyby druhým agentom. [10][11][12]
- **Posudzovanie použiteľnosti zo screenshotov je samo o sebe slabé:** zhoda s odborníkmi 21 %, štvrtina nálezov falošná, problémy medzi obrazovkami nevidí. Kontrast, veľkosť tlačidiel a chýbajúce popisky majú robiť pevné kontroly, nie model. [13][14][15]

## Key Findings

### 1. Čo sa dá púšťať z predplatného a kde sú hranice

Z limitu predplatného čerpajú: interaktívne session, subagenti a workflowy (až 16 agentov naraz), `claude -p` a Agent SDK pri prihlásení predplatným, GitHub Action s `claude_code_oauth_token`, cloud session (bez príplatku za stroj) a rutiny (min. interval 1 h, do 100 behov za hodinu na účet). `/loop` beží len kým je session otvorená a po 7 dňoch vyprší. [1][2][3][16]

Pravidlá používania: limity „predpokladajú bežné, individuálne používanie“; predplatné sa nesmie použiť ako zázemie produktu pre iných ľudí. Zákaz behov bez obsluhy na vlastnom repozitári sme nenašli; dokumentácia ich sama popisuje, s podmienkami: jasná definícia hotového, vlastná kontrola, obmedzený rozsah (worktree, jedna vetva), strop na počet krokov a človek, ktorý schvaľuje zlúčenie. Číselná hranica „bežného“ používania nie je uvedená. [5][17]

Stav u nás (overené v repozitári): nezávislá kontrola každého PR už beží cez token predplatného, nie cez API. V tejto session nie je API kľúč v prostredí, takže behy idú z predplatného.

### 2. Audit kódu viacerými agentmi

Vzor, ktorý sa opakuje vo všetkých zdrojoch: paralelní hľadači podľa oblasti → každý nález dostane skeptika, ktorý vidí len tvrdenie a má ho vyvrátiť → prežijú len potvrdené. V 31-dňovej kampani „Refute-or-Promote“ skeptici zabili ~79 % kandidátov. Dve poučenia odtiaľ: desať agentov jednomyseľne potvrdilo chybu, ktorá neexistovala, a jeden skutočný test ju vyvrátil; skutočnú chybu naopak jednomyseľne zamietli. **Zhoda agentov nie je dôkaz, dôkazom je test, ktorý zlyhá.** Pridanie overovača v kontrolovanom pokuse zdvihlo presnosť z 53 % na 63 % bez straty záchytu. [8][18]

Dokumentácia Claude Code radí to isté v malom: kontrola v čerstvom kontexte, ktorý nevidel písanie; a pozor, že „recenzent, ktorého požiadaš hľadať problémy, vždy niečo nájde“, preto kontrolovať voči zadaniu, nie voľne. [17][19]

### 3. Testy, ktoré naozaj chytajú chyby

Pokrytie klame: v jednom meraní mali testy od modelu 100 % pokrytie riadkov a len 4 % mutačné skóre (slabé overenia). Meta v nasadení na 10 795 tried: testy cielené na prežité mutácie, 73 % prijatých inžiniermi, a 277 z 571 by pri kritériu pokrytia vôbec nevzniklo. Agent píšuci testy vlastností (Hypothesis) nad 100 Python balíkmi: 56 % hlásení platných, v najlepšie hodnotenej skupine 86 %. Priame porovnanie s „jednoducho napíš viac unit testov“ na mobilnej appke neexistuje. [9][20][21]

### 4. Agent ako tester na simulátore

GUITestBench (143 úloh z 26 skutočných chýb): bežní agenti pod 25 % F1 na prvý pokus, viacagentová nadstavba 49 % na najlepší z troch. Dva typické úniky: agent pokazený prvok obíde a nenahlási ho, alebo skutočnú chybu appky pripíše sebe. Chyby použiteľnosti takmer nenachádza. Dlhé scenáre s GPT-4o: 68 skutočných chýb proti 57 od šiestich profesionálov, ale 52 falošných (štvrtina z nich screenshot pred dokreslením). Praktik: 210 behov, 14 skutočných a 9 falošných nálezov; pomalé načítanie (>8 s) čítal ako chybu, vágne zadanie viedlo k bezcieľnemu ťukaniu, zadanie s pomenovanými okrajovými prípadmi našlo skutočné chyby. [10][11][12]

Pre náš prípad: zadania po tokoch s pomenovanými okrajovými prípadmi, čakanie na dokreslenie pred snímkou, každý nález so snímkou a krokmi, zopakovanie druhým agentom, a čo prejde, zmraziť do pevného testu (zhodné so závermi z 09-14).

### 5. Použiteľnosť, prístupnosť, jazyky

GPT-4o proti trom odborníkom na 20 screenshotoch: trafil 21 % ich nálezov, 24 % vlastných bolo falošných, 27 nálezov pridal navyše; nič nenašiel pri zotavení z chýb. Starší test Baymard (GPT-4, 2023, predajca auditov): 80 % falošných. Falošné nálezy sú hlavne domnienky o správaní, ktoré model nevidel. Pri prístupnosti našiel najlepší model len 38 % toho, čo pevný skener. Google: samotná AI na kontrolu rozhrania nestačí, treba ju spojiť s pravidlami. Štúdiu, že kontrolné zoznamy alebo vyvracanie znižujú falošné nálezy práve pri UX, sme nenašli. [13][14][15][22]

Xcode má zabudované pseudojazyky (dvojnásobná dĺžka textu) na odhalenie orezaných textov a vlastný audit prístupnosti v UI testoch (kontrast, veľkosť cieľov, popisky, orezaný text). Ten druhý je známa funkcia Xcode, odkaz sa v tejto rešerši nepodarilo overiť. [23]

### 6. Čo sa neoplatí

Slučky bez dozoru, ktoré píšu kód (agent si prepíše testy, aby prešli; útrata bez stropu; „hotovo“ hodnotí sám sebe), obrovské generované sady testov merané pokrytím, agent kontrolujúci vlastnú prácu. Bez dozoru je bezpečné len čítanie, skeny, beh testov a mechanické úpravy, všetko s neskoršou kontrolou. Sedí to s rozhodnutím foundera „nočné behy nie“. [24][25]

## Implications for Trubbo

Čo už máme (netreba stavať znova): ~2 100 unit testov appky, 51 zmrazených UI scenárov, ~1 050 snímok obrazoviek v sk/cs/en (svetlý, tmavý, väčšie písmo), ~3 100 serverových testov, fuzz API, nezávislá kontrola každého PR, kontrola textov.

Diery, na ktoré voľná kapacita sedí:

| Diera | Stav |
|---|---|
| Audit kódu od júla nezopakovaný | Hra spolu, zdieľanie kvízu, nové nákupy, kontrola témy, presun servera ním neprešli |
| Mutačné testy | jedna ručná sonda v júli, nič pravidelné |
| Prístupnosť | žiadny skutočný audit (čítačka obrazovky, kontrast, najväčšie písmo) |
| Snímky obrazoviek | jedna veľkosť telefónu, bez ukrajinčiny |
| Bezpečnosť | žiadna automatická kontrola v CI (úniky tajomstiev, zraniteľné knižnice) |
| Prieskumné testovanie | `/regression` existuje, ale posledná zapísaná správa je z 09-22 |
| Použiteľnosť | posledný prechod pri redizajne; nič priebežné |

## Recommendations

Poradie podľa sily dôkazov a dopadu na hráča. Všetko z predplatného, na požiadanie (nie plánovane), výstup vždy len potvrdené nálezy.

1. **Audit kódu, kolo 2.** Hľadači po oblastiach pridaných od júla + skeptik na každý nález + povinný zlyhávajúci test ako dôkaz. Opravy cez PR.
2. **Mutačné sondy** na peniaze, limity, vyhodnotenie odpovedí, stavy kvízu a Hru spolu; každá prežitá mutácia = nový test.
3. **Pevné stráže vzhľadu a prístupnosti:** zabudovaný audit prístupnosti do UI testov, snímky doplniť o ukrajinčinu, malý telefón a najväčšie písmo, pseudojazyk s dvojnásobnou dĺžkou.
4. **Prieskumné prechody appkou** podľa zadaní s pomenovanými okrajovými prípadmi (4 jazyky, zlá sieť, prerušenia); nález platí až po zopakovaní druhým agentom; potvrdené chyby zmraziť do testov. Mac stlmený.
5. **Prechod použiteľnosti po úlohách** (nový hráč, rodina, partia): agent úlohu naozaj vykoná a meria počet ťuknutí, čakanie a slepé uličky; výstup je artefakt so snímkami na posúdenie founderom, nie verdikt.
6. **Bezpečnostný prechod** celého povrchu jednorazovo + bezplatné kontroly v CI.
7. **Nerobiť:** `/code-review ultra` ako rutinu (platené), slučky bez dozoru píšuce kód, hodnotenie kontrastu a veľkostí modelom.

Pred väčším behom skontrolovať `/usage`, a že „usage credits“ sú vypnuté (stav účtu sme neoverovali).

## Sources

1. [Agent SDK a `claude -p` s predplatným](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan) — čerpajú z limitu predplatného
2. [Authentication](https://code.claude.com/docs/en/authentication) — nastavený API kľúč má prednosť
3. [Ultrareview](https://code.claude.com/docs/en/ultrareview) — platí sa zvlášť, 3 behy zadarmo na Max
4. [Claude Code s Pro/Max](https://support.claude.com/en/articles/11145838-using-claude-code-with-your-pro-or-max-plan) — 5-hodinový a týždenný limit, zvlášť limit pre Fable
5. [Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance) — „bežné, individuálne používanie“
6. [Cloud environments](https://code.claude.com/docs/en/cloud-environments) — Ubuntu x86_64
7. [Audit so 40 agentmi 2026-07-30](adversarial-audit-2026-07-30.md) — vlastný výsledok
8. [Refute-or-Promote](https://arxiv.org/html/2604.19049v1) — 79 % kandidátov zabitých, omyly pri jednomyseľnosti
9. [Mutation-Guided LLM Test Generation at Meta](https://arxiv.org/pdf/2501.12862) — mutácie proti pokrytiu
10. [GUITestBench](https://arxiv.org/html/2601.04500) — F1 agentov, typické úniky
11. [Soap-opera testing s LLM](https://arxiv.org/html/2412.08581v1) — 68 skutočných, 52 falošných
12. [Týždeň agenta na emulátore](https://dev.to/sharminsirajudeen/what-happens-when-you-let-ai-test-your-app-for-a-week-53md) — jedna skúsenosť praktika
13. [GPT-4o proti odborníkom na použiteľnosť](https://arxiv.org/html/2506.16345v1) — 21 % zhoda
14. [Baymard GPT-4 UX audit](https://baymard.com/research-articles/gpt-ux-audit) — 80 % falošných (2023, predajca)
15. [Google: AI is not enough (UI linting)](https://research.google/pubs/ai-is-not-enough-a-hybrid-technical-approach-to-ai-adoption-in-ui-linting-with-heuristics/) — AI + pravidlá
16. [Routines](https://code.claude.com/docs/en/routines) a [Workflows](https://code.claude.com/docs/en/workflows) — limity a čerpanie
17. [Best practices](https://code.claude.com/docs/en/best-practices) — kontrola, ktorú si agent vie spustiť; behy bez obsluhy
18. [Viacagentová detekcia zraniteľností](https://arxiv.org/pdf/2604.21282) — overovač zvyšuje presnosť (len zo súhrnu)
19. [Code review v session](https://code.claude.com/docs/en/code-review-local) — čerstvý kontext
20. [MutGen](https://arxiv.org/html/2506.02954v6) — 100 % pokrytie, 4 % mutačné skóre (len zo súhrnu)
21. [Agentic Property-Based Testing](https://arxiv.org/pdf/2510.09907) — 56 % platných hlásení
22. [LLM a prístupnosť](https://arxiv.deeppaper.ai/papers/2504.02110v1) — 38 % oproti skeneru (len zo súhrnu)
23. [Xcode: Test localizations](https://help.apple.com/xcode/mac/current/en.lproj/dev499a9529e.html) — pseudojazyky
24. [codecentric: zlyhania agentických slučiek](https://www.codecentric.de/en/knowledge-hub/blog/agentic-engineering-loops-practice-failure-patterns) — prepisovanie vlastných testov
25. [Čo nechať agentov robiť bez dozoru](https://flaviocopes.com/agents-unattended.md) — bezpečné a nebezpečné úlohy
