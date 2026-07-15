# Founder human gates — App Store release (2026-07)

Návod krok-za-krokom pre brány (gates) v release runbooku [`docs/issues/release-orchestration-2026-07.md`](../issues/release-orchestration-2026-07.md) §Founder checklist, ktoré vyžadujú teba osobne — agent ich nevie dokončiť sám. Aktuálny stav gate-ov je vždy v tom runbooku, tento súbor je len postup "ako na to".

Mimo tohto súboru (nájdeš to inde, nie je to tu duplikované): **F1/F2/F3 sú už hotové** (§Completed v runbooku) a **G2 (51.2 analytics)** rieši orchestrátor s tebou naživo v chate, nie tento dokument.

## 1. G1 — On-device checklist na novom TestFlight builde (build #22)

Starý build, ktorý si mal doteraz (run `29255778835`, commit `386e6ac`), **predchádza opravám z 2026-07-14** (commit `1808036`: reaktivita hlasového indikátora + odolnosť order-pollu). Preto treba celý checklist zopakovať na novom builde, nestačí sa spoliehať na predchádzajúci test.

1. V TestFlight na iPhone over, že máš nainštalovaný **build #22** (GitHub Actions run `29334191671`, upload z commitu `248d63d`). Ak máš starší build, aktualizuj.
2. Otvor [`docs/issues/issue-96-ios-mvp-completion.md`](../issues/issue-96-ios-mvp-completion.md), sekcia **P7 — Verify + TestFlight as Trubbo** (~riadok 112) — presný "Post-build founder checklist": sandbox subscription + pack purchase (P1) · hlasové príkazy s indikátorom + Settings toggle (P2) · image toggle skrytý, jednoriadkové texty, paddingy (P3) · custom-pack order→play e2e alebo potvrdenie, že entry je skrytý (P5) · re-check položiek z 2026-07-11 (silent switch, mikrofón na pozadí).
3. Pre hlasové príkazy použi cheat-sheet hneď pod checklistom v tom istom súbore (~riadky 115-120) — presné slová a v ktorých momentoch fungujú.
4. Výsledok nahlás orchestrátorovi v chate (čo prešlo, čo nie) — zápis do issue-96/TODO spraví agent.

## 2. G3 — Blind-rating ~10-otázkovej vzorky

Session N2 pripraví súbor s 10 otázkami (5 Opus 4.8 / 5 glm-5.2, zamiešané, model skrytý) na `docs/testing/runs/corpus-blind-sample-2026-07.md`. **Ak súbor ešte neexistuje, N2 ešte nebežala — počkaj**, orchestrátor ti dá vedieť.

1. Otvor `docs/testing/runs/corpus-blind-sample-2026-07.md`.
2. Ku každej z 10 otázok napíš verdikt **"fun"** alebo **"flat"** podľa svojho rubricu — pripomienka kritérií (fun-fact/prekvapenie/skrytá vrstva = plus, klišé/výplň/suchý recall = mínus) je v [`docs/research/question-quality-founder-calibration-2026-07-09.md`](../research/question-quality-founder-calibration-2026-07-09.md), ak si ju potrebuješ osviežiť.
3. Verdikty povedz orchestrátorovi v chate (otázka č. → fun/flat), on ich zapíše.
4. Súbor má na konci answer-key sekciu odhaľujúcu, ktorá otázka je od ktorého modelu — pozri sa na ňu **až po** ohodnotení všetkých 10, nie skôr (aby ťa neovplyvnila).
5. Výsledok (ktorý model vyšiel lepšie) nastaví default `GENERATION_MODEL` pre budúcu generáciu (#30/#95).

## 3. G4 / #50 — App Store Connect: agreements, availability, privacy label

App = **Trubbo**, ASC app id **6762482437**. Draft privacy nutrition labelu pripraví session R14 do `docs/product/privacy-nutrition-label.md` — ak ten súbor ešte neexistuje, R14 ešte nebežala.

**3a. Paid Apps Agreement**
1. App Store Connect → **Business** → **Agreements, Tax, and Banking**.
2. Pod "Agreements": ak **Paid Apps** ukazuje "View Terms in Action Needed", klikni a odsúhlas (musí to byť Account Holder/Admin — to si ty).
3. Skontroluj, že tax + banking sú vyplnené (inak IAP produkty zostanú zaseknuté v "Missing Metadata").

**3b. Availability SK/CZ/EN**
1. App Store Connect → (app **Trubbo**) → **Pricing and Availability** → **Availability**.
2. Zaškrtni **Slovensko** + **Česko** (lokalizovaný zážitok) + anglicky hovoriace krajiny — prípadne nechaj dostupné worldwide s angličtinou ako jazyk pre zvyšok sveta.
3. Ulož.

**3c. Privacy nutrition label**
1. Otvor `docs/product/privacy-nutrition-label.md` — obsahuje presné dátové kategórie a odpovede na zaklikanie.
2. App Store Connect → (app **Trubbo**) → **App Privacy** (ľavé menu) → **Get Started** (alebo **Edit**, ak už bolo rozbehnuté).
3. Prejdi dotazník krok za krokom; pre každý typ dát zadaj presne to, čo hovorí draft súbor — nehádaj/negeneruj vlastné odpovede.
4. **Publish** / **Save**.

## 4. G5 — Pencil ⌘S

Session N4 upraví `design/quiz-agent.pen` (nové dynamic-state rows — timer chip, Answer-Confirm progress, atď.). Pencil zmeny needituje na disku, kým ich neuložíš ty.

1. Otvor appku **Pencil** (mala by mať otvorený `design/quiz-agent.pen`, N4 v ňom pracovala).
2. Stlač **⌘S**.
3. Potvrď orchestrátorovi, že si uložil — agent následne commitne `.pen` súbor.

## 5. G6 — `/code-review ultra` + go/no-go

Posledná brána pred releasom. `/code-review ultra` je platený multi-agent cloud review celej vetvy — spustiť ho vieš **len ty** (beží pod tvojím účtom, orchestrátor ho spustiť nemôže).

1. Počkaj, kým orchestrátor nahlási, že session **R24** (#48 Stage 2 security review) je hotová — G6 je až po nej.
2. V Claude Code v repe `quiz-agent` napíš `/code-review ultra`.
3. Review pobeží v cloude (platený beh) a vráti nálezy zoradené podľa závažnosti.
4. **Go/no-go:** ak nie sú žiadne blokujúce (blocker/critical) nálezy → potvrď "go", release pokračuje. Ak sú → rozhodni, či sa opravia pred releasom alebo sa release odloží. Rozhodnutie je tvoje, orchestrátor len prezentuje nálezy.

## 6. Štyri zariadenie-gaty (kedykoľvek, nezávisle od poradia session-ov)

- **77.15 — hlasové príkazy v aute.** V reálnom aute (nie simulátor): povedz každý príkaz svojím slovenským prízvukom v angličtine a over, že sa rozpozná; over STOP v hlučnej kabíne; over Bluetooth mikrofón; over že prerušenie telefonátom nezanechá zaseknuté nahrávanie. Detail a presný postup: [`issue-77-voice-commands-handsfree.md`](../issues/issue-77-voice-commands-handsfree.md), úloha **77.15** (~riadok 258).
- **#61 — SK sign-in + privacy label.** Over Sign in with Apple na zariadení s telefónom/appkou nastavenou na slovenčinu — prihlásenie musí prebehnúť bez chyby. (Privacy label časť je zhodná s G4 vyššie, nerob ju druhýkrát.) Detail: [`issue-61-auth-phase2-sign-in-with-apple.md`](../issues/issue-61-auth-phase2-sign-in-with-apple.md) (riadok 22).
- **67-A — obnova po prerušení hovorom.** Počas prehrávania otázky alebo nahrávania odpovede prijmi telefonát (AirPods); po jeho skončení sa appka musí vrátiť do funkčného stavu (žiadne zaseknuté nahrávanie). Detail: [`issue-67-audio-interruption-and-barge-in.md`](../issues/issue-67-audio-interruption-and-barge-in.md) (riadok 54).
- **59.1 — TTS na zariadení.** Over, že sa otázka prečíta nahlas (slovenčina, cez AirPods aj telefónny reproduktor). **Poznámka:** toto si reálne používal už 2026-07-12 pri bežnej prevádzke appky — ak si TTS vtedy počul spoľahlivo, môžeš tento gate odškrtnúť na základe toho bez ďalšieho formálneho testu. Tvoje rozhodnutie. Detail: [`issue-59-quiz-flow-bug-cluster.md`](../issues/issue-59-quiz-flow-bug-cluster.md), úloha 59.1 (riadok 28).
