# Spoločné review generačnej pipeline — session so zakladateľom (2026-08-09)

**Účel:** Interaktívny prechod celej generačnej pipeline. Pri každej časti: ako funguje, model, doslovné prompty, nálezy z dvoch externých reviews + assessment, verdikt zakladateľa. Výstup: rozhodnutia → issues + trvalá ochrana kvality (anti-degradácia).

**Vstupy:**
- `docs/research/external-review-gen-pipeline-2026-08-09.md` — review #1 (architektúra/verifikácia, 14 nálezov)
- `docs/research/external-review-question-quality-2026-08-09.md` — review #2 (kvalita otázok, 8 nálezov)

**Rozšírené zadanie (zakladateľ, in-session):** aj out-of-the-box pohľad — zmysluplnosť/potrebnosť krokov, chýbajúce kroky, architektúra, alternatívne paradigmy garancie kvality (fine-tuning, špecializované modely a pod.).

## Postup review (časti)

1. Objednávka → téma → fakty (sourcing) — `[x]`
2. Generovanie otázok (prompty v2/v3/v4–v6, open/entertainment/kids vetvy, direct mode) — `[x]`
3. Kritika a výber (best-of-N, pairwise, MCQ vetva) — `[x]`
4. Answerability + verifikácia faktov — `[x]`
5. Skórovanie a brány + vysvetlenie kalibrácie sudcov — `[x]`
6. Dedup, top-up, kompozícia — `[x]`
7. Architektúra out-of-the-box + alternatívne paradigmy — `[x]`
8. Ochrana kvality do budúcna (anti-degradácia) — `[x]` (poistky P1–P7 nižšie)

**Otvorené po session:** zakladateľov stratený vstup — nové todo o entertainment otázkach s príkladom dobrej/zábavnej otázky (zadané ~12.–13. 8.): NENÁJDENÉ v repo (TODO.md bez zmien od 7. 8., nič necommitnuté) ani v Sentry feedbacku. Čaká sa na opätovné dodanie od zakladateľa; zapracuje sa do prompt rekalibrácie (D12/D28) a entertainment vetvy.

## Rozhodnutia zakladateľa (časť 1 + prierezové)

- **D1 — Nomenklatúra (návrh, čaká na potvrdenie):** *korpusové otázky* (zdieľaný fond pre všetkých) vs *custom otázky* (z promptu jedného používateľa). Os generovania: *grounded* (z faktov) vs *direct* (bez faktov).
- **D2 — Celý user prompt 1:1 do generovania.** Custom objednávka sa neparsuje na témy/kategórie; celý prompt ide do generačného promptu ako samostatná property (napr. `user_prompt`). Len malá/žiadna kontrola + moderácia: nevhodný obsah (vulgarizmy a pod.) → používateľovi vopred oznámiť, nech prompt prepíše, inak sa nič nevygeneruje. (Nahrádza pôvodný nález #2.6 aj dnešné 3-tokenové parsovanie.)
- **D3 — Direct generovanie = prvotriedny režim.** LLM vymýšľa otázky bez zadaných faktov, pravdivosť nesie verifikačný krok. Cieľ ~1:1 pomer direct vs grounded; po review sa vygenerujú sady, zakladateľ ohodnotí → určí sa víťaz/pomer.
- **D4 — Marker v texte objednávky (aktivácia direct/„DIRECT GENERATION MODE") nahradiť server-side parametrom.** Potvrdená diera: dnes ho aktivuje reťazec v zákazníckom texte (`pack_generator.py:135`).
- **D5 — Nekredibilný fakt sa NIKDY neponecháva.** Zrušiť starvation-guard („pri núdzi ponechaj"). Ak téma nemá kredibilné fakty → otázky sa generujú direct (bez faktu). Kredibilita: listicle/blog bez citovaných zdrojov = nedôveryhodný; kontrolovať prítomnosť citácií. Faktov radšej nadbytok.
- **D6 — OpenTDB rewriter zapnúť** (pseudo-fakty „odpoveď na X je Y" nesmú vstupovať do generovania). Zdroje web/wiki/OpenTDB inak OK s výhradou (OpenTDB = klasické kvízovky, obmedzená).
- **D7 — Kurátorovaný topic pool pre korpus = zlý postup.** LLM má témy vyberať samo z neobmedzeného priestoru (manuálny zoznam limituje kreativitu). Redizajn výberu tém pre korpusové generovanie. (Custom otázky témy nemajú — ide celý prompt, viď D2.)
- **D8 — Custom objednávka bez promptu:** produktovo upozorniť, že si môže lacnejšie dokúpiť štandardný balík X otázok (korpus), nie generovať custom bez zadania.
- **D9 — Prebytok otázok sa nezahadzuje.** Ak pipeline prežije viac otázok než target, použijú sa (korpus). Kompozícia ako 7. krok je neskoro — orezané otázky sa dnes po zaplatení celej verifikácie+skórovania zahadzujú → ukladať ich. Doručovací flow (floor 80 %, fail objednávky) sa nerieši teraz — generuje sa na povel zakladateľa; premyslí sa pri reálnych používateľoch.
- **D10 — #153 Phase A kolo 2 ratingy odložené;** experimenty sa preplánujú v rámci tohto review. Nové osi: grounded vs direct, porovnanie gen modelov (Kimi K2.5 vs Gemini vs DeepSeek V3.2 vs Opus 5…), prompt verzie. Veľká generačná dávka počká na koniec review.
- **D11 — Nález #1.1 (fakty bez trvalého ID, citácie píše model) akceptovaný** — detail v časti 4.
- **D12 — „Plain recall is a defect" v prompte NEPLATÍ.** Zakladateľ: obyčajná vedomostná otázka je tiež v poriadku. Prompt bar prekalibrovať; POZOR na napätie s anti-pattern korpusom (Canberra/Shakespeare príklady značia recall ako zlý) a júlovou rubrikou (surprise reward, cliché penalty) — presná hranica sa doladí (viď kalibračná otázka v chate).
- **D13 — Grounding uvoľniť: odpoveď smie pochádzať aj z vlastných vedomostí modelu** (nie len zo zdrojového faktu). Syntéza (čaká na potvrdenie): povolené, ale poctivo označené — otázka bez zdroja nesmie mať vymyslenú citáciu; ide plnou verifikáciou ako direct otázky.
- **D14 — Deterministické brány presunúť PRED kritika** (nápad zakladateľa, potvrdený ako správny): dnes bežia až po best-of-N výbere a od kritika nezávisia; presun ušetrí kritikove volania a uvoľní sloty výberu pre životaschopné otázky.
- **D15 — Kids prompt zapojiť hneď** (malé issue); vízia: kids = kategória s podkategóriami (časom).
- **D16 — Nový direct prompt potvrdený** (v2 je horší — predchodca v3, prekonaný dizajn).
- **D1 potvrdené** zakladateľom (korpusové/custom, grounded/direct).
- **D13 potvrdené** (odpoveď smie ísť z vlastných vedomostí; vymyslené citácie absolútny zákaz; bez zdroja = plná verifikácia ako direct).
- **D17 — Pattern library je príliš limitujúca.** Smer: menej/žiadne vzory (v5-free štýl), rozhodnú experimenty. Pozorovania zakladateľa k vzorom: odd_one_out kolísavá kvalita, estimation kolísavá, comparison_bet väčšinou očividné odpovede, chýbajú napr. písmenkové logické hádanky. Preniesť do critique red flags.
- **D18 — Overiť pravdivosť celej example knižnice (53 položiek)** + rework konkrétnych: „Diving" (nezrozumiteľná aj pre zakladateľa), Canberra FIX v anti-patterns (Sydney/Melbourne prezrádza Austráliu; náhodný fakt), únava z veľko-číselných pravdepodobnostných otázok (10^120, deck-shuffle — obmedziť frekvenciu), wordplay otázky na zváženie (language-dependent).
- **D19 — Kalibrácia vkusu potvrdená:** „capital of Australia" NIE; „chobotnica má 3 srdcia" ÁNO. Princíp: fakt musí byť zaujímavý sám o sebe, forma smie byť jednoduchá; ale nie random niche fakt bez šance na odpoveď. **KONFLIKT ODHALENÝ:** živý critique prompt kotví presne chobotnicu ako 5.8 „mediocre pub quiz filler" → kritik dnes aktívne tlačí proti vkusu zakladateľa; treba prekotviť.
- **D20 — In-app hodnotenia otázok sa do generovania NEDOSTÁVAJÚ.** Plumbing existuje (placeholder „reserved for future use", vždy prázdny); ratings.db z appky nikto nečíta pri generovaní. Rieši konsolidácia ratingov (kandidát 11).
- **D21 — Master metodika hodnotenia (zakladateľ, kľúčové):** poradie: (1) najprv generovanie otázok (direct aj s guidelines), zakladateľ ich ohodnotí; (2) tie isté otázky sa nechajú posúdiť kritikovi/duelu/sudcom a porovná sa zhoda s hodnoteniami zakladateľa → z korelácie sa rozhodne, ktoré vrstvy pipeline sú relevantné a ostávajú. Zároveň tým vznikne kalibračný dataset pre sudcov zadarmo.
- **D22 — Verdikty časť 3:** kritika prekotviť na vkus zakladateľa (áno); rameno bez duelov vyskúšať (áno); MCQ cez rovnaký kritik+výber ako ostatné (určite).
- **D23 — Persona ramená: a (retold at table), b (no way really), d (bez persony)**; c (auto/jazda) VYRADENÉ — appka sa nepoužíva len v aute (product note: pozor, „while driving" framing je v niektorých promptoch — zvážiť zmäkčenie; single-listen TTS kontrakt ostáva). Tip zakladateľa: d) môže fungovať najlepšie.
- **D24 — Hodnotenie otázok cez debug obrazovku (nová feature):** škála vyššie=lepšie (odporúčanie agenta: 1–10 pre konzistenciu s historickými ratingami) + audio odôvodnenie (prepis, uloží sa ku ratingu). iOS + backend.
- **Anti-patterns:** spoločný prechod všetkých 24 so zakladateľom (opravy #15+ na posúdenie, #1–14 fixy OK) + faktická verifikácia opravených odpovedí — rozšírenie kandidáta 12.
- **Časť 5 pripraviť ako hĺbkové vysvetlenie kalibrácie sudcov** — zakladateľ chce samostatné review tejto medzery so mnou.
- **D24 upresnené:** debug obrazovka = LEN hodnotenie — 10 samostatných tlačidiel (1–10) + odôvodnenie (audio/text). ŽIADNE odpovedanie na otázky, žiadna schvaľovacia fronta v appke.
- **D25 — Multi-rater hodnotiaci web:** hodnotenia od viacerých ľudí, s atribúciou per osoba; nahradí lokálne single-user rating.html stránky. (Kandidát 15.)
- **D26 — Answerability model nemusí byť najlacnejší** — kľudne stredná trieda; vyberie sa podľa D21 experimentov (infra pozn.: mimo Bedrock kvót, OpenRouter OK).
- **D27 — Verifikáciu validovať proti dátam zakladateľa:** poradie — najprv zakladateľ otázky ohodnotí/zodpovie, POTOM sa pustí verifikačný krok a porovná sa zhoda. Kredibilita zdrojov platí aj pre verifikačné vyhľadávanie (žiadne „7 facts about…" blogy).
- **Verdikty časť 4:** fail-closed POTVRDENÉ (neoverené/held otázky nikdy do korpusu/packov — jednoducho nevyjdú; bez in-app fronty); answer-blind redizajn verifikácie OK; nezávislá klasifikácia tvaru otázky OK.
- **D24 doplnené:** debug obrazovka dostupná len v TestFlight buildoch; pred App Store verziou sa odstráni.
- **D28 — Zmierniť penalizáciu „klasických"/overexposed otázok.** Zakladateľ: sme príliš prísni na otázky, ktoré už mohli byť vo veľa kvízoch; trocha povoliť, klasiky nie sú od veci. Dotýka sa: critique red flag „overexposed_cliche" (−3), kotvy surprise_delight („thousand quizzes → 1–3 bez ohľadu na formuláciu"), zoznamu „deadest shapes" vo v3. Presná miera vyjde z D21 hodnotení; alternatíva k penalte: strop podielu klasík na pack (kompozičná vec, nie zákaz).
- **Verdikty časť 5:** prah „čo už môže von" sa NEURČUJE vopred — vyjde z ľudských hodnotení (D21); kvórum ≥2 sudcov v zásade áno, ale závisí od ceny — revisit po veľkom review; sada dimenzií — rozhodne sa po hodnoteniach („uvidíme").
- **Verdikty časť 6/7:** story-level dedup OK; banka faktov ako smer pre grounded rameno POTVRDENÁ; fine-tuning ODLOŽENÝ do ~500+ ohodnotených otázok (potom kandidát: reward-model sudca ako prvý FT cieľ); eval kvality prekladov POTVRDENÝ (kandidát 16).
- **D29 — Ľudské hodnotenie = nástroj kalibračnej fázy, nie trvalý krok pipeline.** Cieľový stav (zakladateľ): pipeline vyladená tak, aby ľudské hodnotenie nebolo potrebné — automatické brány kalibrované raz nazbieranými dátami. Multi-rater web (D25) je kalibračný nástroj tejto fázy. Odporúčanie agenta ponechané v pláne ako voliteľné: drobný mesačný spot-check (~10–20 otázok) ako lacná poistka proti driftu.

## Verdikty k nálezom — časť 1

| Nález | Verdikt | Akcia |
|---|---|---|
| #2.6 strata zámeru (3 tokeny) | Platný, ale riešenie iné než reviewer: žiadne parsovanie | D2 (celý prompt + moderácia) |
| #1.5+#2.2 DIRECT mode marker | Platný (potvrdené v kóde); samotný direct režim je žiadaná feature | D3 + D4 |
| #1.12+#2.2 nekredibilné zdroje | Platný; kredibilitný filter z #153 nestačí (starvation-guard) | D5, D6 |
| #1.1 provenance/fact ID | Platný, akceptovaný | D11, detail časť 4 |
| (in-session) topic pool nezapojený na živej ceste | Prekonané rozhodnutím | D7/D8 |

## In-session overené fakty

- **DIRECT GENERATION MODE:** aktivácia = marker-reťazec v zákazníckom texte objednávky (`pack_generator.py:135`) — potvrdená diera (D4). Režim = preskočí sourcing, generuje bez faktov, verifikácia nesie pravdu (#153 Phase 0.4 lever).
- **Direct mode dnes padá na v2 CoT prompt** (najstarší) — bez faktov sa nepoužije v3; pre D3 experiment treba vlastný direct prompt.
- **v4–v6 prompty nezapojené, prod beží v3** (nález #1.8 potvrdený; zámer počas #153 Phase A). Pozor: „v5_free/v6_free" = free *rein* (bez pattern library/house style), NIE fact-free — všetky sú grounded.
- **Kids prompt nezapojený** (nález #2.5 potvrdený): šablóna so safety/vekovými pravidlami má nula call sites; kategória `kids` je živá, ale píše ju generický v3 prompt.
- **Customerov prompt sa dnes do generačného promptu NEDOSTANE** — v šablóne preň nie je placeholder; model vidí len odvodené témy/kategórie.
- **Kompozícia:** orezané otázky sa zahadzujú (po plnej cene gen+verify+score) — podklad pre D9.

## Kandidáti na issues (zbiera sa priebežne, finalizuje sa na konci review)

1. Celý user prompt do generovania + moderačný pre-check s user-facing hláškou (D2)
2. Direct generovanie ako riadny režim + vlastný direct prompt + server-side prepínač namiesto markeru (D3, D4)
3. Kredibilita zdrojov: zrušiť starvation-keep, citation-check, OpenTDB rewriter ON (D5, D6)
4. Redizajn výberu tém pre korpus: LLM-driven, bez kurátorovaného poolu (D7)
5. Prebytok/orezané otázky ukladať do korpusu namiesto zahadzovania (D9)
6. Custom objednávka bez promptu → upsell štandardného balíka (D8, product/UX)
7. Experiment matica: grounded vs direct × modely × prompty + founder rating flow (D10)
8. Zapojiť kids prompt (D15, malé) + neskôr podkategórie
9. Deterministické brány pred kritika (D14)
10. Prompt rekalibrácia: plain recall OK (D12) + grounding relaxation (D13) + revízia persona formulácie — zlúči sa s experimentmi (D10/kandidát 7)
11. **Konsolidovaný ratings dataset** — zlúčiť všetky kolá founder hodnotení (gold library, júl rubrika, pilot 07-11, #153 baseline + Phase A, Bedrock batch, in-app ratings.db) do jedného kanonického datasetu; použiť na: refresh gold/anti príkladov, prekotvenie critique promptu (D19), kalibráciu judge prahov, zmrazený regresný eval set (časť 8). Zapojiť in-app ratings (D20).
12. Example library: verifikácia pravdivosti + rework označených (D18)
13. Critique re-anchoring na founder vkus (D19) — pravdepodobne súčasť kandidáta 11
14. Debug obrazovka: hodnotenie otázok — 10 samostatných tlačidiel + audio odôvodnenie; rating-only (D24, iOS + backend)
15. Multi-rater hodnotiaci web s per-osoba atribúciou (D25)
16. Eval kvality prekladov — vzorka preložených otázok (10 jazykov) do hodnotiaceho flow; preklad dnes nikto nekontroluje
17. Entertainment otázky — zakladateľov stratený vstup (todo + príklad dobrej otázky), čaká na opätovné dodanie

## ČASŤ 8 — Ochrana kvality do budúcna (poistky P1–P7)

Mechanizmy degradácie nájdené počas review: (a) drift verzií promptov (v4–v6 nezapojené, prod na v3); (b) ~20 neviditeľných env prepínačov + modely cez secrets, nikde neassertované; (c) nekalibrovaní sudcovia rozhodujú o shipnutí; (d) tiché fail-open fallbacky (verifikácia, čiastočný panel); (e) hodnotenia roztrúsené a nevyužité.

- **P1 — Zmrazený eval set:** ohodnotené otázky z D21 sa zmrazia; každá zmena promptu/modelu/konfigurácie musí prejsť bránou „korelácia sudcov s ľudskými hodnoteniami neklesla + deterministické craft testy zelené". Spustiteľné v CI.
- **P2 — Kanonická verzia promptov:** jedna aktívna verzia; startup assert + test pinujúci, ktorá šablóna beží v prode (zabíja triedu chýb „vylepšenie existuje, ale nebeží"); prehrané varianty sa archivujú, nie hromadia.
- **P3 — Config fingerprint:** každá vygenerovaná dávka nesie odtlačok konfigurácie (verzie promptov, modely per rola, kvalitatívne flagy); diff dvoch dávok okamžite odpovie „prečo je táto horšia".
- **P4 — Kalibrované brány, fail-closed všade:** prah z dát (D21), kvórum ≥2 sudcov, verifikácia fail-closed, žiadne model-controlled routovanie.
- **P5 — Golden-batch canary:** pred každým veľkým/plateným behom malá kanárska dávka celou pipeline; ak nesplní prahy, veľký beh sa nespustí.
- **P6 — Zmena = eval:** žiadna zmena gen modelov/promptov/prahov bez eval dát + founder approval (existujúce pravidlo rozšírené z modelov aj na prompty a prahy).
- **P7 — Voliteľný drift spot-check:** ~10–20 otázok mesačne do rating webu (viď D29 — voliteľné).

## Navrhované poradie realizácie

1. **Hodnotiaca infraštruktúra** — kandidáti 14 (debug obrazovka, TF-only), 15 (multi-rater web), 11 (konsolidovaný dataset). Všetko ostatné na nej stojí.
2. **Rýchle bezpečnostné/fail-closed opravy** (paralelne, nezávislé od hodnotení): D4 server-side prepínač namiesto markeru; fail-closed verifikácia/held; kvórum; nezávislá klasifikácia tvaru; server-check citácií; kids prompt (D15); brány pred kritika (D14).
3. **Experimentálne kolo (D21):** ramená grounded vs direct × modely (Kimi/Gemini/DeepSeek/Opus…) × prompty (v3/v4/v5-free/v6/nový direct/persona a/b/d) × bez duelov; zakladateľ hodnotí cez novú infra; potom replay kritika/duelov/answerability/sudcov na ohodnotených otázkach → korelácie → ktoré vrstvy ostávajú, prahy, panel, kanonické prompty. (Nahrádza odložené #153 Phase A kolo 2.)
4. **Prestavba sourcingu:** kredibilita bez výnimiek (D5, D6 rewriter), banka faktov, trvalé ID faktov/príbehov + story dedup.
5. **Zjednodušenia pipeline podľa výsledkov:** gate v2 zapnúť kalibrovanú, MCQ zjednotiť, duely prípadne von, prebytok do korpusu (D9), celý user prompt + moderácia (D2), zmiernenie klasík v promptoch/rubrikách (D12/D28).
6. **Poistky P1–P7** — budované priebežne popri krokoch 3–5.
7. **Eval prekladov** (kandidát 16) + entertainment vstup (kandidát 17) po dodaní.
