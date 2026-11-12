# #234 — Trubbo Beta ako samostatná appka vedľa App Store verzie

**Triage:** enhancement · ready-for-agent
**Status:** 2026-11-12 plán skontrolovaný (SOUND), ďalej 234.1
**Founder:** 2026-11-12 „radšej by som mal plnú betu aj s nákupmi“ · betu dostane len founder a Svitlana

## Prečo

TestFlight build a App Store build majú dnes ten istý identifikátor (`com.missinghue.hangs`) aj ten istý záznam v App Store Connect (ASC). Na telefóne preto môže byť len jeden a navzájom sa prepisujú. Appka je v predaji, founder chce mať na ploche verziu, ktorú vidia hráči, a vedľa nej betu na skúšanie.

Predchádzajúce zamietnutia (07-22 pred vydaním, 10-11 prepínanie dizajnov) mali dôvody, ktoré už neplatia: appka je vonku a nákupy sa testujú bežne.

## Rozhodnutia

| Téma | Rozhodnutie | Kto |
|---|---|---|
| Nákupy v bete | áno, plný katalóg (predplatné, balík 100, balíky na mieru) | founder 11-12 |
| Kto dostane betu | founder + Svitlana (interní testeri) | founder 11-12 |
| Názov a ikona | „Trubbo Beta“, ikona s oranžovým pásikom BETA | agent (kozmetika) |
| Pozvánky do Hry spolu | beta posiela odkazy `trubbo.app/beta/join`, ostrá ostáva `trubbo.app/join` | agent (viď nižšie) |
| Ostrá appka v TestFlighte | ostáva len na kontrolu App Store buildu pred podaním | agent |

## Riešenie

### Identita appky

- Nový identifikátor `com.missinghue.hangs.beta`, nový záznam appky v ASC „Trubbo Beta“ (nikdy sa nevydá do App Store).
- Ktorý identifikátor build dostane, rozhoduje už existujúci prepínač App Store variantu (`APP_STORE_VARIANT`): TestFlight build (`NO`) = beta, App Store build (`YES`) = ostrý. Rovnaká xcconfig indirekcia, akou sa dnes zapína `APP_STORE` podmienka; **len v `Prod.xcconfig`** nastaví príponu identifikátora, názov, ikonu a samostatnú podmienku `BETA` (predpona produktov sa riadi ňou, nie `!APP_STORE`, inak by sa rozbili lokálne StoreKit testy v `Hangs-Local`, kde je variant tiež `NO`). Local a Staging sa nemenia. Dôsledok: Debug-Prod na zariadení je tiež `.beta` a potrebuje vývojový profil.
- Staging konfigurácia (deprecated, „Trubbo Beta“ názov na staging serveroch) sa nemení ani nepoužíva; názov „Trubbo Beta“ teraz nesie TestFlight build proti prodom.

### Nákupy

ID produktov sú v Apple unikátne v celom vývojárskom účte, beta appka teda nemôže použiť tie isté. Pravidlo: **beta ID = `beta.` + ostré ID** (`beta.pack_30`, `beta.com.carquiz.unlimited.monthly`, …).

- **Appka:** ID produktov sa nečítajú natvrdo, ale cez jednu funkciu, ktorá v beta builde pridá predponu (StoreManager, PackSize, StoreKit konfigurácia na lokálne testy ostáva bez predpony).
- **Server:** jedna funkcia `canonical_product_id(bundle_id, product_id)` na **každom** mieste, kde ID prichádza od Apple alebo RevenueCat: overenie transakcie, notifikácie, `reconcile.py` (história z Server API), `revocation.py`, RevenueCat webhook aj REST snímka (`fetch_rc_subscriber`). Predpona `beta.` sa odstráni len pri beta identifikátore, takže beta ID sa nikdy nezapočíta pod ostrou appkou; ďalej všetko pracuje s ostrým ID (tabuľka produktov, `PACK_PRODUCTS`, ceny balíkov, analytika). Vstupy: overenie StoreKit transakcie a notifikácie v quiz-pack-api, RevenueCat webhook a entitlements v quiz-agent. Nič iné sa neduplikuje (žiadne nové riadky v tabuľke produktov).
- Beta nákupy sú vždy sandbox (TestFlight), prod ich prijíma od 09-10; žiadna zmena peňazí ani limitov. Týždenný strop objednávok z TestFlightu (PR #777) platí aj pre betu, lebo kanál sa určuje podľa sandbox dokladu, nie podľa identifikátora.
- **ASC katalóg:** skript `scripts/asc_store_upload.py` už vie zakladať nákupy (`iap-create`, `iap-price`, `iap`) zo `store_copy.json`. Rozšíri sa o cieľovú appku a predponu, takže beta katalóg = ten istý zdroj s predponou. Pri každej zmene katalógu alebo cien sa skript pustí pre obe appky (zapíše sa do `release-flow.md` a do testflight skillu). Beta nákupy stačí doviesť do stavu „Ready to Submit“, v sandboxe tak fungujú bez App Review.
- **RevenueCat:** do existujúceho projektu nová iOS appka (vlastný `appl_` kľúč), beta produkty pripojené k tým istým entitlementom (`unlimited`) a ponuke. Kľúč v appke podľa variantu. Webhook je jeden pre projekt, netreba nič nové. In-App Purchase kľúč (p8) je tímový, poslúži aj beta appke.

### Server: prijať dva identifikátory

Dnes server prijíma práve jeden identifikátor. Zmeniť na zoznam (spätne kompatibilne, jeden prvok = dnešné správanie):

| Kde | Dnes | Po zmene |
|---|---|---|
| quiz-pack-api overenie nákupov a notifikácie | `APP_BUNDLE_ID` (jeden) | zoznam; App Store Server API volanie s `bid` podľa identifikátora z transakcie |
| quiz-agent Sign in with Apple | `APPLE_SIGNIN_CLIENT_ID` (jeden audience) | zoznam audience; client secret podľa appky; pri refresh tokene sa uloží aj appka, ktorá ho vydala (dnes jeden stĺpec `apple_refresh_token_encrypted`), a odvolanie pri zmazaní účtu použije tú istú, inak GDPR odvolanie potichu zlyhá |
| quiz-agent App Attest | `APP_ATTEST_APP_ID` (jeden) | zoznam |

Prihlásenie: Apple dáva identifikátor používateľa v rámci tímu ([Apple: Authenticating users with Sign in with Apple](https://developer.apple.com/documentation/signinwithapple/authenticating-users-with-sign-in-with-apple)); beta App ID sa navyše **zoskupí pod primárne `com.missinghue.hangs`** (jeden súhlas, jedna položka v „Apps using Apple ID“). Zoskupenie treba nastaviť výslovne, API aj fastlane predvolene zakladajú primárne App ID. Founder a Svitlana budú v bete na tom istom účte ako v ostrej appke (po jednom prihlásení, keychain je oddelený). Overí sa v 234.7.

**Spoločný stav účtu:** predplatné a kredity patria účtu, nie appke. Sandbox predplatné kúpené v bete odomkne Trubbo Plus aj v ostrej appke toho istého účtu (TestFlight to tak robí už dnes). Ostrá appka teda ukazuje to isté rozhranie ako hráčom, nie nutne ten istý platený stav.

Premenné idú do tajomstiev na Hetzneri (prod beží tam od 11-06), nie do Fly.

### Odkazy na trubbo.app

Ak by obe appky mali v `apple-app-site-association` rovnakú cestu, iOS nezaručuje, ktorá odkaz otvorí. Preto:
- ostrá appka: `/join?t=…` (bez zmeny, staré buildy fungujú ďalej),
- beta appka: `/beta/join?t=…`; beta pri zdieľaní pozvánky vytvorí odkaz s touto cestou a vie ju prečítať. Web stránka `/beta/join` sa správa ako `/join` (záložná stránka, keď appka nie je nainštalovaná).
- Testovanie pozvánok (#230 — Hra spolu na diaľku) teda ide beta ↔ beta (founder ↔ Svitlana).

### Build a vydávanie

- **fastlane:** identifikátor appky sa neberie natvrdo (dnes 3 miesta vo Fastfile + Appfile + Matchfile), ale podľa variantu. match spravuje profil pre oba identifikátory.
- **Číslo buildu:** jedno spoločné počítadlo pre obe appky (max z oboch + 1), aby git tagy `ios/<verzia>-b<build>` ostali jednoznačné a CI kontrola API (openapi_compat) videla každý živý build.
- **Exportná deklarácia** (`set_compliance`) a TestFlight info pre beta appku.
- **ASC skripty** (testeri, skupiny, promote) už berú identifikátor z `ASC_AUDIT_BUNDLE_ID`; workflowy dostanú voľbu appky. Skupiny v bete: `Founder` (automaticky každý build) a `family+friends` so Svitlanou (automaticky každý build; pri založení skupiny sa to nastaví hneď, neskôr sa nedá zmeniť). Public beta pre betu nezakladať.
- **Skill `testflight` a `release-flow.md`:** TestFlight build ide do Trubbo Beta, App Store build do Trubbo; ostrá appka v TestFlighte len na kontrolu pred podaním.

### Čo sa nemení

Backend adresy, `/app-config` a minimálne verzie (kanál podľa sandbox dokladu), analytika a hlavička `X-Build-Channel`, Sentry (release už obsahuje identifikátor appky), CarPlay (len lokálne).

## Úlohy

Poradie je dané závislosťami: server najprv (spätne kompatibilný, nasadí sa sám), potom Apple a RevenueCat nastavenia, potom appka a pipeline.

- [ ] **234.1 Server: zoznam identifikátorov + predpona `beta.`** — quiz-pack-api (overenie, notifikácie, Server API `bid`), quiz-agent (Sign in with Apple, App Attest, RevenueCat webhook a entitlements). Testy: beta transakcia sa započíta ako ostrý produkt; neznámy identifikátor sa stále odmietne; jeden prvok v zozname = dnešné správanie. Nasadiť.
- [ ] **234.2 Identifikátor a profil (agent cez ASC API)** — zaregistrovať `com.missinghue.hangs.beta` so schopnosťami Sign in with Apple (zoskupené pod primárne App ID) a Associated Domains, match profily App Store + vývojový.
- [ ] **234.3 Záznam appky v ASC (founder klikne, Apple to cez API nedovolí)** — presný postup v sekcii nižšie. Potom agent: TestFlight info, skupiny Founder + family+friends (automatické buildy), Svitlana do skupiny.
- [ ] **234.4 Beta katalóg nákupov (agent)** — `asc_store_upload.py` s cieľovou appkou a predponou; predplatné, balík 100, pack_10/pack_30 (+ pack_20/50 ak sú v katalógu), ceny, lokalizácie; stav Ready to Submit (vrátane review screenshotu, bez neho tam nákup nedôjde). URL notifikácií v ASC pre beta appku (API, inak Playwright v spoločnom prehliadači).
- [ ] **234.5 RevenueCat (agent cez Playwright, founder sa len prihlási)** — nová iOS appka v projekte, produkty k entitlementu `unlimited` a ponuke, `appl_` kľúč do appky.
- [ ] **234.6 Appka + pipeline** — identifikátor/názov/ikona podľa variantu, ID produktov s predponou, RevenueCat kľúč podľa variantu, beta cesta pozvánok, Fastfile (`latest_testflight_build_number`, mapa profilov, `set_compliance`)/Appfile/Matchfile, spoločné číslo buildu, workflowy s voľbou appky, AASA s `/beta/join` na webe. Unit testy: beta variant skladá ID s predponou, ostrý bez; pozvánka z bety má beta cestu. Release-Prod sa skompiluje lokálne v oboch variantoch.
- [ ] **234.7 Overenie na zariadení (founder, na požiadanie TestFlight build)** — beta a ostrá appka vedľa seba; v bete prihlásenie (ten istý účet), nákup balíka a predplatného v sandboxe, pozvánka do Hry spolu beta ↔ beta so Svitlanou; ostrá appka nedotknutá.
- [ ] **234.8 Dokumentácia** — `release-flow.md`, skill `testflight`, `add-tester`, pamäť (nahradí `project_no_separate_staging_app_mvp`).

## Postup pre foundera (234.3)

1. Otvor https://appstoreconnect.apple.com → **Apps** → modré **„+“** → **New App**.
2. Platforms: **iOS**. Name: **Trubbo Beta**. Primary Language: **English (U.S.)**. Bundle ID: vyber **com.missinghue.hangs.beta** (agent ho zaregistruje vopred v 234.2). SKU: **trubbo-beta**. User Access: **Full Access**.
3. **Create**. Nič ďalšie nevypĺňaj, zvyšok spraví agent cez API.

(RevenueCat: stačí byť prihlásený v spoločnom prehliadači, agent naklikne sám.)

## Riziká

- **Zabudnutý beta katalóg pri zmene cien** → beta ukáže staré ceny alebo produkt chýba; ostrá appka nezasiahnutá. Poistka: skript beží pre obe appky jedným príkazom, krok v `release-flow.md`.
- **Nový produkt (napr. #227 — Trubbo Max)** treba založiť v oboch appkách; rovnaký skript.
- **Dve appky = dve sady TestFlight buildov.** Kontrola App Store buildu pred podaním ostáva v ostrej appke, ako dnes.

## Náklad

Apple ani RevenueCat nič neúčtujú (beta nákupy sú sandbox). Práca: 6 krokov agenta, 1 krok foundera (založenie appky), test na zariadení.

## Stav

- 2026-11-12: plán podľa rozhodnutí foundera; `/design-soundness` SOUND 0,78 bez vád, 5 upozornení zapracovaných (zoskupenie App ID, väzba refresh tokenu na appku, všetky vstupy ID produktov, podmienka `BETA` len v Prod, spoločný platený stav).
