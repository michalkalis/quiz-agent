# #227 — Trubbo Max: drahé predplatné s vlastnými balíkmi

**Triage:** enhancement · ready-for-agent (po #228 — vlastné balíky vždy plné)
**Status:** plán 2026-11-05; náklad na balík zmeraný; implementácia nezačatá
**Založené:** 2026-10-28 (founder)
**Súvisí:** #199 — Trubbo Plus 1 000 otázok + zásoba (úloha 199.5 „drahší plán“ sa týmto nahrádza), #228 — vlastné balíky vždy plné + menší balík, #225 — vlastný balík: rovnaké zadanie = hotové otázky, #93 — vlastné balíky

## Cieľ

Druhé, drahé mesačné predplatné nad Trubbo Plus pre ľudí, ktorí neriešia peniaze a chcú najlepší zážitok. Hlavná hodnota: veľa vlastných balíkov na témy, ktoré si sami zadajú.

## Rozhodnutia foundera

- 10-28: drahý plán, cena nemusí presne zodpovedať tomu, čo hráč reálne dostane. Jednorazové číslované členstvo („Black“) teraz nie, „kým nemáme používateľov“; „navždy“ zatiaľ nie.
- 11-02: v cene veľa vlastných balíkov, ale ekonomicky to musí vychádzať. Priama linka na foundera NIE („užívateľ dostane dosť za to, že zaplatí viac“). Zlatá ikona, oslovenie menom a vlastná otázka v korpuse NIE. Hlas pri výbere novej témy ÁNO.
- 11-04: 20 balíkov mesačne; „musí to byť výhodnejšie ako kúpa custom balíčka priamo“. Nesmie sa objaviť v TF buildoch ani v App Store, kým to founder nepustí.
- 11-05: **€149,99 mesačne, 20 vlastných balíkov (po 30 otázok).**

## Ekonomika (meranie 2026-11-04)

Skúšobné behy s produkčným nastavením (sk, 30 otázok, nič sa neuložilo; výpočet z tokenov a cenníkov):

| Položka | Náklad |
|---|---|
| Písanie otázok (Claude Opus 5.5) | $1,61–1,65 |
| Overovanie faktov (gpt-5-mini, tokeny) | $0,31–0,36 |
| Overovanie faktov (poplatok za webové hľadania, odhad $10/1 000) | ~$0,40 |
| Hodnotitelia (DeepSeek + GLM na Bedrocku), kontrola odpovedateľnosti | ~$0,13 |
| Hlas (ElevenLabs v4 Turbo, podľa #93 Revision 2026-10-26) | ~$0,55 |
| **Spolu za balík** | **~$3,0–3,1** (počítame $3,5 s rezervou) |

Neúspešný beh stojí skoro rovnako (~$2,4) a produkcia ho skúsi až 3×. Preto #228 ide pred Max.

Príjem z €149,99 (SK: −23 % DPH, −15 % Apple) ≈ **€103,7** mesačne.

| Využitie | Náklad | Ostane |
|---|---|---|
| 5 balíkov | ~€16 | ~€88 |
| 20 balíkov (všetko) | ~€64 | ~€40 |

Pre hráča: 20 balíkov zvlášť = €179,80 (+ Plus €4,99) → Max je o ~€35 výhodnejší. €199,99 by podmienku foundera nesplnilo.

## Čo Max obsahuje

1. Všetko z Plus (1 000 otázok mesačne; či vyšší limit, rozhodne founder neskôr podľa `quota_hit`).
2. **20 vlastných balíkov za obdobie predplatného.** Nevyčerpané sa neprenášajú.
3. Hlas pri výbere novej témy: v1 ručne (founder pošle Max členom anketu), bez kódu.

## Riešenie

### Obdobie, nie kalendárny mesiac
Nárok sa obnovuje s **obdobím predplatného od Apple** (dátum nákupu → dátum obnovy), nie 1. v mesiaci. Pri kalendárnom mesiaci by sa dalo kúpiť 28., minúť 20, 1. minúť ďalších 20 a zrušiť: 40 balíkov za jednu platbu ≈ €128 nákladu proti €104 príjmu.

### Server (quiz-agent)
- **Úroveň predplatného:** dnes `account_is_entitled` vracia len áno/nie (`usage/entitlement.py:38`). Pridať úroveň `plus | max` odvodenú z `Subscription.product_id` a tabuľky `Product` (nový druh produktu). Všetko, čo dnes kontroluje „je predplatiteľ“, ostáva pravdou aj pre Max.
- **Účet nároku:** nová tabuľka `max_pack_allowance` (účet, začiatok a koniec obdobia, použité). Obdobie berie z RevenueCat udalostí (`INITIAL_PURCHASE`, `RENEWAL`, `PRODUCT_CHANGE`); pri `REFUND` / `EXPIRATION` sa zvyšok zruší (minuté sa vrátiť nedá, viď Riziká).
- **Poistka proti zneužitiu:** najviac 5 balíkov za deň (env, nie natvrdo). Doložka o férovom používaní už platí (#199).

### Server (quiz-pack-api)
- **Nová cesta objednávky „z Max“:** dnes objednávka vyžaduje StoreKit doklad konzumovateľného nákupu (`api/v1/orders.py:316`, `X-StoreKit-JWS`). Pre Max: prihlásený hráč (bearer token, ako už pri GET/retry) + server overí nárok u quiz-agent a v jednej transakcii zníži zostatok. `transaction_id` = syntetické `max-<účet>-<obdobie>-<n>` (unikátnosť a idempotencia ostávajú), `storekit_environment` z prostredia predplatného.
- Zlyhaný balík (aj po #228 môže výnimočne nastať) vracia nárok, nie peniaze.
- #225 (hotové otázky pri rovnakom zadaní) platí aj pre Max.
- **Kapacita:** 20 balíkov × člen, ~20 min každý, worker 512 MB s 2 súbežnými úlohami. Pri prvých desiatkach členov treba frontu sledovať; prípadne väčší worker (súčasť #222 — presun na Hetzner).

### iOS
- Max na obrazovke predplatného vedľa Plus (rovnaká skupina predplatného v App Store → prechod Plus ↔ Max rieši Apple), Max v Profile.
- Objednávka vlastného balíka pre Max člena: namiesto platby „Zostáva 14 z 20 balíkov v Max“; po vyčerpaní normálny nákup.
- Texty: `Profile/ProfileAccountRow.swift` má natvrdo „Trubbo Plus“ → podľa úrovne. Nikde „bez limitu“ (#199).

### Skrytie pred TF a App Store
Prepínač `max_enabled` v `/app-config` (DB prepínač, predvolene OFF) + skrytie v App Store builde ako pri hre spolu (`multiplayerHiddenByChannel`, `AppConfigStore.swift:70`). Kód sa môže zlučovať do `main` (pravidlo z 2026-10-16: flagy, nie dlhé vetvy); kým je prepínač OFF, hráč Max nevidí ani v TF. **Čaká na súhlas foundera** (11-04 žiadal vetvu).

### App Store Connect + RevenueCat
- Nové automaticky obnovované predplatné `com.carquiz.max.monthly`, €149,99, tá istá skupina ako Plus, vyššia úroveň. Texty en/sk/cs bez pomlčiek a bez „bez limitu“.
- RevenueCat: entitlement `max`, balík v offeringu; Plus offering ostáva.

## Analytika (v tých istých PR)
`max_paywall_view`, `max_purchase`, `max_pack_redeem` (zostatok), `max_allowance_exhausted`, `max_cancel`; náklad každého Max balíka v objednávke.

## Riziká
- **Vrátenie peňazí cez Apple po minutí balíkov:** Apple refund rozhoduje sám; strata je max. ~€64 za člena. Sledovať `REFUND` udalosti; opakovaných vylúčiť z Max.
- **Náklad na balík sa zmení** (iný model, viac kôl po #228): prepočítať po #228; cena a počet balíkov sú v env/ASC, nie v kóde.
- **Apple review:** popis musí presne povedať, čo Max dáva (Guideline 3.1.2); ukážka pre recenzenta.

## Úlohy
- [ ] 227.0 nezávislá kontrola plánu (`/design-soundness`) pred implementáciou
- [ ] 227.1 server: úroveň predplatného + tabuľka nároku + RevenueCat udalosti (migrácia len pridáva)
- [ ] 227.2 quiz-pack-api: objednávka z Max (overenie nároku, idempotencia, vrátenie pri zlyhaní)
- [ ] 227.3 iOS: Max na paywalle a v Profile, objednávka bez platby, za prepínačom
- [ ] 227.4 ASC produkt + RevenueCat entitlement (agent cez prehliadač; founder len prihlásenie)
- [ ] 227.5 test v sandboxe: nákup, 20 balíkov, obnova obdobia, refund, prechod Plus ↔ Max
- [ ] 227.6 spustenie: founder zapne prepínač
