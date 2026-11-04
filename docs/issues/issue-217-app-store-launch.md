# #217 — Verejné vydanie v App Store

**Triage:** enhancement · ready-for-agent (founder rozhodnutia 2026-11-01 nižšie)
**Status:** 2026-11-01 plán. Nahrádza zvyšok #62 (cross-device, väzba nákupov) a zbiera otvorené body z #209, #140, #133, #61, #78, #155, #190, #207 do jedného poradia.
**Súvisí:** #61 — Sign in with Apple, #62 — cross-device a väzba nákupov (týmto uzavretý), #93 — predplatné a balíky, #140 — nákup vlastného balíka cez StoreKit, #209 — App Store variant buildu, #212 — hra spolu, [release-flow.md](../setup/release-flow.md)

## Cieľ

Trubbo je verejne v App Store a nákupy aj pokrok idú s Apple účtom: po reinštalácii alebo na novom
iPhone sa hráč prihlási cez Apple a má späť Plus, kredit otázok, vlastné balíky, štatistiky a prehľady.
Prihlásenie ostáva dobrovoľné (žiadna povinná registrácia, žiadny hard paywall).

## Skutočný stav (overené v kóde a v ASC 2026-11-01)

| Bod | Stav | Dôkaz |
|---|---|---|
| 1.1 v App Store review | **zatvorené**: build 80 (`ios/1.1-b80-store`) schválený, 2026-11-02 `READY_FOR_SALE` (phased 7 dní); `main` ide na 1.2 | asc-audit 11-02 |
| TEMP `generatedBy` odznak v QuestionView | **zatvorené**: riadok `TEMP (Bedrock gen test)` už neexistuje; nahradil ho `QuestionProvenanceRow` (#176), viditeľný len pri `debugSurfaces` | `QuestionView.swift:25`, `ReviewBadge.swift:119` |
| Panel hodnotenia otázok (#155) | **zatvorené pre obchod**: `BuildChannel.debugSurfacesEnabled()` vracia v App Store variante vždy false (#209, compile-time `APP_STORE`). Mazanie kódu netreba, TestFlight ho používa | `BuildChannel.swift:40`, `QuestionRatingEntry.swift:46` |
| `STOREKIT_ENVIRONMENT` Sandbox → Production | **zatvorené**: prod `Production,Sandbox` od 10-08 (#193.1; App Review a TF kupujú v Sandboxe). Živé čítanie hodnoty agentovi zablokovala poistka, overí 217.8 | `quiz-pack-api/app/config.py:54-61` |
| #78 meno po opätovnom prihlásení | **zatvorené v kóde** (`mergedAccountField`, server vracia meno); na zariadení neoverené → 217.10 | `AuthService.swift:400,534` |
| #209 privacy policy (Amazon, rola ElevenLabs) | **zatvorené**: Amazon Bedrock uvedený, ElevenLabs = len čítanie nahlas (PR #525) | `apps/website/src/legal/privacy.*.html` |
| Privacy štítky ASC, DSA trader, SBP, Paid Apps | **zatvorené** (207.21, pamäť 09-21 / 10-10) | #207, #190 |
| #61 zlúčenie anonymného účtu s Apple | **zatvorené v kóde**: denné použitie (súčet), predplatné, kredit (`credit_ledger`), denné výzvy sa prekľúčujú; štatistiky a prehľady čítajú aj prepojené anon id | `usage/account_merge.py:103-182`, `me_stats.py:59` |
| Vlastné balíky po prihlásení | **otvorené (chyba)**: `generation_orders` a `question_packs` ostanú na anon id → po prihlásení zmiznú z Moje balíky a nedajú sa hrať | `quiz-pack-api orders.py:556`, `quiz-agent sessions.py` (`user_id = :uid`) |
| Výzva na prihlásenie | **čiastočne**: len po zapnutí Plus, nie po kúpe kreditu ani balíka | `SignInPromptCoordinator.swift` |
| Náklady generovania v odpovedi objednávky | **otvorené**: `llm_cost_usd`, `search_cost_cents`, `total_cost_cents` idú každému vlastníkovi („hide before real users“) | `quiz-pack-api orders.py:166-170` |
| Apple oznámenia o refundoch pre vlastné balíky (#133) | **otvorené / nejasné**: ASC URL od 09-21 ukazuje na RevenueCat, endpoint `quiz-pack-api /v1/appstore/notifications` tak nič nedostáva | pamäť 09-21, #133 gate 2 |
| In-App Purchase kľúč (207.6, reconcile po obnove DB) | **otvorené** (founder) | #207 |
| #140 sandbox nákup balíka na zariadení | **otvorené** (founder) | TODO-details |
| Cena vlastného balíka vs. náklady API | **otvorené**: COGS po #182 nikto nezmeral | #140 krok 4 |

## Návrh: pokrok a nákupy idú s Apple účtom (zvyšok #62)

Väčšina už existuje: identita = náš `users.id` naviazaný na `apple_sub`; pri prihlásení server v jednej
transakcii zlúči anonymného hráča do účtu (zlúčenie, nie náhrada; súčet použitia, idempotentné cez
`upgraded_to_user_id`, 409 len keď anon už patrí inému účtu). Plus ide cez RevenueCat `logIn(users.id)`
+ webhook (vrátane TRANSFER), kredit otázok je serverový ledger na účte. Chýba len:

1. **Vlastné balíky sa pri prihlásení prekľúčujú na účet** (opravené po `/design-soundness` 11-01).
   `rekey_purchases` v `usage/account_merge.py` presunie `generation_orders`, `question_packs` aj
   `credit_ledger` z anon id prihlasujúceho sa zariadenia na `users.id` **pri každom prihlásení**, nielen
   pri prvom zlúčení (po odhlásení je zariadenie znova na tom istom, už prepojenom anon id a môže kúpiť
   ďalší balík alebo kredit). Beží až po kontrole 409, takže balíky cudzieho účtu sa nikdy nepresunú;
   idempotentné. Ten istý Postgres, `text()` ako `_unlink_pack_orders`. Súbeh s prvou dávkou balíka:
   `PersistStage` zamkne riadok objednávky (`FOR UPDATE`) a prekľúčovanie ide objednávky → balíky, takže
   balík nikdy neostane na anon id. Backfill pre už prepojené anon id: `scripts/rekey_linked_purchases.py`
   (dry run, potom `--execute --yes`). Zvolené prekľúčovanie, nie
   čítanie cez prepojené id ako pri prehľadoch: pack-api by inak čítal tabuľku quiz-agentu a vlastnícka
   kontrola hry by sa musela meniť na dvoch miestach. Druhý vzor (čítanie cez linked ids) ostáva pre
   štatistiky; tam dáta len čítame, nevlastníme. Známe obmedzenia: reconcile (`storekit/reconcile.py`)
   berie jeden seed na `user_id`, takže účet s objednávkami z viacerých Apple ID zrekonciliuje len jednu
   históriu; objednávka odoslaná ešte so starým anon tokenom, ktorá dorazí až po prihlásení, sa presunie
   až pri ďalšom prihlásení (217.4: výzvu ukázať až po prijatí objednávky).
2. **Výzva na prihlásenie po každom nákupe** (Plus, kredit, vlastný balík), rovnaký strop ako dnes; ponuka
   na novej inštalácii **zamietnutá** founderom 2026-11-04 (217.4).
3. **Odmietnuté:** Keychain synchronizovaný cez iCloud (anon by žil na dvoch telefónoch naraz a detekcia
   opakovaného refresh tokenu by rodinu tokenov zrušila); povinné prihlásenie (Guideline 5.1.1(v), founder
   nechce bariéry); vlastný serverový zoznam StoreKit transakcií pre Plus (RevenueCat to už robí).
4. **Známe obmedzenie (mimo rozsahu):** zoznam už položených otázok je len v zariadení (`PersistenceStore`),
   po reinštalácii sa otázky môžu zopakovať. Server ho vie odvodiť z analytiky; až po vydaní, ak to vadí.

**Pred implementáciou `/design-soundness`** (ťažko vrátiť späť): prekľúčovanie balíkov + backfill (presun
vlastníctva platených dát), poradie zlúčenia voči 409, a voľba RevenueCat preposielania v 217.5.

## Úlohy (v poradí)

- [ ] **217.1 Stav review 1.1 a typ vydania** — agent (founder 11-01: nechať `AFTER_APPROVAL`, len sledovať)
  - Čo: `gh workflow run asc-audit.yml -f script=asc_readiness_audit` (len čítanie), zapísať stav 1.1.
    Podľa otázky 1 prepnúť `releaseType` na `MANUAL` cez ASC API (najprv dry run; či Apple zmenu
    počas `WAITING_FOR_REVIEW` dovolí, je neoverené). Review sa nikdy neruší (founder 10-28).
  - Prečo: 1.1 vyjde sama hneď po schválení, bez opráv nižšie; 13 dní čakania je nezvyčajné.
  - Hotovo: stav a typ vydania zapísané tu; ak čaká > 14 dní, pripravený text dotazu pre Apple (217.1a).
- [ ] **217.1a Dotaz na App Review** (len ak 1.1 stále čaká) — founder, 2 kliky
  1. Agent otvorí v spoločnom prehliadači https://developer.apple.com/contact/app-store/ a vyplní dotaz
     (presné názvy polí doplní pri otvorení).
  2. Founder sa prihlási (ak treba) svojím Apple ID.
  3. Prečíta text, klikne **Submit** / **Send**.
- [ ] **217.2 Vlastné balíky idú s Apple účtom** — agent (`/design-soundness` hotový 11-01, opravy zapracované)
  - Čo: prekľúčovanie objednávok, balíkov aj kreditu pri každom prihlásení, po kontrole 409; zámok
    objednávky v `PersistStage`; backfill (návrh bod 1). pytest: anon kúpi balík → prihlásenie → balík je
    v `GET /v1/orders` aj hrateľný; prihlásenie → odhlásenie → kúpa → prihlásenie presunie aj nový balík a
    kredit; opakované prihlásenie nič nezdvojí; 409 nič nepresunie; súbeh s prvou dávkou; backfill.
  - Backfill (po nasadení, najprv dry run): `fly ssh console -a quiz-agent-api -C "python /app/scripts/rekey_linked_purchases.py"`,
    potom to isté s `--execute --yes`.
  - Prečo: dnes po prihlásení (aj na tom istom telefóne) balík za €8,99 zmizne.
  - Hotovo: PR zlúčený, nasadené `backend-deploy.yml`, backfill spustený a výsledok zapísaný. Funguje aj pre 1.1.
- [~] **217.3 Skryť náklady generovania** — agent (PR #664)
  - Čo: bez admin kľúča vracať `llm_cost_usd = null`, `search_cost_cents = 0`, `total_cost_cents = 0`
    (polia ostávajú, CI kontrola API prejde; iOS ich neukazuje).
  - Prečo: zákazník by v odpovedi videl našu cenu generovania.
  - Hotovo: test vlastník vs. admin, nasadené.
- [ ] **217.4 Výzva na prihlásenie po každom nákupe** — agent
  - **Founder 2026-11-04** (plátno https://claude.ai/artifact/Pk9BoVyYpa2nGuMG77cTr9, riadok „Výber“): nízke okno, ktoré ukáže, čo presne si kúpil (Plus, +N otázok, karta balíka), po kúpe Plus, kreditu aj vlastného balíka. **Žiadna** ponuka na novej inštalácii: noví hráči sa neotravujú, prihlásiť sa dá kedykoľvek v Profile (riadok účtu).
  - Čo: `SignInPromptCoordinator` aj pre kredit a vlastný balík.
    Texty sk/cs/en podľa `copy-style.md`, `xcstringstool sync`, udalosť analytiky v tom istom PR.
    Po prihlásení sa Hraj a Profil načítajú nanovo (balíky, kredit, štatistiky).
  - Prečo: kredit a balíky Apple neobnoví (consumable); bez prihlásenia sú na novom telefóne preč.
  - Hotovo: unit testy brány (kto, kedy, strop), snímky, PR zlúčený.
- [ ] **217.5 Oznámenia Apple o refundoch aj pre vlastné balíky** — agent cez Playwright (founder sa len prihlási)
  - Čo: URL v ASC (App Information → App Store Server Notifications) ostáva na RevenueCat (potrebuje ich
    pre Plus). V RevenueCat (app → App Store settings) nastaviť **Apple Server Notification Forwarding URL**
    na `https://quiz-pack-api.fly.dev/v1/appstore/notifications`; funkcia existuje
    ([docs](https://www.revenuecat.com/docs/platform-resources/server-notifications/apple-server-notifications)).
    Overiť end-to-end, že preposlaný payload stále prejde našou kontrolou Apple JWS
    (`quiz-pack-api/app/storekit/notifications.py`), aj pre Sandbox.
  - Prečo: refund vlastného balíka dnes nič neodoberie; RevenueCat oznámenia potrebuje pre Plus.
  - Hotovo: testovacie oznámenie (App Store Server API, vyžaduje 217.6) prejde cez RevenueCat do
    `quiz-pack-api` a overí sa (Production aj Sandbox).
- [ ] **217.6 In-App Purchase kľúč pre server** — founder (kľúč vytvára founder, hodnoty nikdy do chatu)
  1. Otvor https://appstoreconnect.apple.com → **Users and Access**.
  2. Hore karta **Integrations** → vľavo **In-App Purchase**.
  3. Klikni **Generate In-App Purchase Key** (alebo **+**), názov `Trubbo server`, **Generate**.
  4. V riadku kľúča klikni **Download In-App Purchase Key** (stiahne sa len raz, súbor `SubscriptionKey_….p8`).
  5. Opíš **Key ID** z tabuľky; vľavo **App Store Connect API** → hore opíš **Issuer ID**.
  6. Otvor v TextEdit súbor `~/code/quiz-agent/.env`, na koniec pridaj dva riadky
     `APP_STORE_SERVER_KEY_ID=<Key ID>` a `APP_STORE_SERVER_ISSUER_ID=<Issuer ID>`, ulož.
  7. Napíš agentovi „kľúč je v Downloads“. Agent nastaví Fly secrets `quiz-pack-api` (aj obsah .p8)
     bez vypísania hodnôt a súbor potom zmaž.
  - Hotovo: `python -m app.storekit.reconcile --help` na prode beží bez „not configured“.
- [ ] **217.7 RevenueCat: obnova nákupov na novom telefóne** — agent cez Playwright, len čítanie
  - Čo: Project settings → **Restore Behavior** má byť „Transfer to new App User ID“ (server spracuje TRANSFER).
  - Hotovo: nastavenie zapísané tu; ak je iné, návrh zmeny foundrovi.
- [ ] **217.8 Cena vlastného balíka a živé prepínače** — agent
  - Čo: z prod DB `llm_cost_usd` posledných objednávok z Fly workera (API režim) vs. čistý príjem ~€6,20;
    `/app-config` a Fly env: `orders_enabled`, `multiplayer_enabled`, `STOREKIT_ENVIRONMENT`, `RC_ALLOWED_ENVIRONMENT`.
  - Prečo: po #182 nikto nemeral; zapnuté prepínače platia aj pre App Store build (release-flow).
  - Hotovo: čísla zapísané tu; ak balík vychádza v strate, otázka foundrovi (cena / dočasne vypnúť objednávky).
- [ ] **217.9 Upratať zastarané pripomienky** — agent (docs PR)
  - Čo: v `TODO.md` a `TODO-details.md` uzavrieť riadky „Pre-App-Store removal (#155)“, „Remove TEMP
    `generatedBy`“ (platí compile-time vypnutie z #209, novší a otestovaný vzor), `#140 leg 2` presunúť sem,
    „pred GA prepnúť STOREKIT_ENVIRONMENT“ zrušiť; #62 označiť „nahradené #217“; #48 a #50 zrevidovať.
  - Hotovo: žiadny riadok v TODO nesľubuje pred vydaním prácu, ktorá je hotová.
- [ ] **217.10 Test na zariadení: nákupy a pokrok po reinštalácii** — founder (TF build s 217.2 a 217.4 na požiadanie)
  1. Trubbo → **Profile** → účet: ak si prihlásený, **Sign out**.
  2. Kúp balík otázok (sandbox, nič sa neplatí) → v okne prihlásenia ťukni **Sign in with Apple**.
  3. Objednaj vlastný balík (sandbox) → počkaj, kým sa dá hrať, zahraj 2 otázky.
  4. Zapamätaj si: kredit otázok, Plus áno/nie, názov balíka, počet otázok v Profile.
  5. Na ploche podrž ikonu Trubbo → **Remove App** → **Delete App** → **Delete**.
  6. Otvor TestFlight → Trubbo → **Install**, spusti appku.
  7. Na ponuke prihlásenia (alebo **Profile** → **Sign in with Apple**) sa prihlás.
  8. Over: v Profile je tvoje meno, kredit a Plus sedia, balík je v Moje balíky a hrá sa, štatistiky sú rovnaké.
  9. Napíš agentovi „OK“ alebo pošli snímku toho, čo nesedí (Feedback v appke stačí).
  - Hotovo: všetkých 8 bodov sedí → zaškrtnúť aj #61 akceptáciu, #78 a #140 leg 2.
- [ ] **217.11 Verzia na vydanie a podanie** — agent; podanie na povel foundera
  - Čo: podľa otázky 1. Ak ide 1.2: po vydaní alebo stiahnutí 1.1 PR so zvýšením `MARKETING_VERSION`;
    lokálne skompilovať Release-Prod; skontrolovať prepínače (217.8); App Store build
    `gh workflow run ios-release.yml --ref main -f environment=production -f store=true`; founder ho v TF
    rýchlo pozrie (bez Diagnostiky hlasu a hodnotenia otázky); upload textov (`steps=listing`, nový popis
    z #605/#607 čaká od 10-28); `steps=app-review -f build=N` s typom vydania podľa otázky 1, phased release zapnutý.
  - Hotovo: verzia `WAITING_FOR_REVIEW` s `-store` buildom, tag `ios/<verzia>-b<build>-store`.
- [ ] **217.12 Spustenie a prvý týždeň** — founder povel „vydaj“, agent stráži
  - Čo: pri `MANUAL` founder: ASC → Apps → Trubbo → verzia → **Release This Version**. Agent počas phased
    release (7 dní) denne Sentry + `prod-monitor`; pri kritickej chybe **Pause Phased Release** a hotfix podľa
    `shared.md`. `min_version_*` nedvíhať, kým beží review.
  - Hotovo: 100 % používateľov na novej verzii, žiadny otvorený kritický alarm; #217 uzavretý, pamäť aktualizovaná.

## Poradie a závislosti

217.1 → otázky foundera → `/design-soundness` → 217.2 → 217.3 → 217.4 (217.5–217.8 súbežne, 217.5 test
potrebuje 217.6) → 217.9 → TF build na požiadanie → 217.10 → 217.11 → 217.12. Serverové 217.2, 217.3 a
217.5 pomôžu aj 1.1, ak vyjde skôr. Každý bod = samostatné PR (okrem founder krokov).

## Riziká

- 1.1 môže vyjsť sama skôr než 217.2 (dnes `AFTER_APPROVAL`) → 217.1 a 217.2 idú prvé.
- Kým je 1.1 schválená a nevydaná, 1.2 sa podať nedá: treba 1.1 vydať alebo ju zrušiť (
  developer reject, presný názov tlačidla overiť v ASC); schválené nákupy ostávajú schválené.
- Prekľúčovanie balíkov je presun vlastníctva platených dát: v jednej transakcii s prihlásením, test na
  idempotenciu, backfill najprv dry run.

## Otázky pre foundera

1. **Ktorá verzia ide verejne?** (a) 1.1 hneď po schválení Apple (dnešné nastavenie) alebo (b) 1.1 nechať
   len schváliť a verejne spustiť až 1.2 s novými kartami, Hrou spolu, prehľadmi a výzvou na prihlásenie.
   Odporúčam (b) a hneď prepnúť vydanie na ručné, rozhodnutie ostane na tebe pri schválení.
2. **Výzva na prihlásenie:** okrem Plus aj po kúpe kreditu a vlastného balíka, plus jedna ponuka
   „Prihlás sa a obnov nákupy“ pri prvom spustení na novom telefóne? Odporúčam áno, vždy s možnosťou zavrieť.
   **Rozhodnuté 2026-11-04:** po každom nákupe áno (nízke okno s tým, čo si kúpil); ponuka na novej inštalácii nie, prihlásenie ostáva v Profile.
3. **Hra spolu pri verejnom spustení:** prepínač je v prode zapnutý pre všetkých, takže ju App Store 1.2 ukáže
   každému. Nechať zapnutú, alebo do vydania vypnúť a zapnúť neskôr?
   **Rozhodnuté 2026-11-01:** v App Store builde skrytá, kým ju founder s blízkymi neotestuje; v TestFlighte viditeľná;
   zapnutie prepínačom `multiplayer_enabled_app_store` bez novej verzie (PR #661, [app-switches.md](../setup/app-switches.md)).
