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
- 11-05: **10 balíkov za deň** (nie 5); **otázky z knižnice bez obmedzenia**; Max za prepínačom OK; „over, či to nie je moc in-app purchase možností, aby to užívateľa moc nezahltilo“.

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
| + knižnica, 3 000 odpovedí | ~€2 | ~€38 |

Pre hráča: 20 balíkov zvlášť = €179,80 (+ Plus €4,99) → Max je o ~€35 výhodnejší. €199,99 by podmienku foundera nesplnilo.

## Čo Max obsahuje

1. Všetko z Plus a **otázky z knižnice bez mesačného limitu** (náklad ~$0,0006 za odpoveď, hlas zdieľaný). Doložka o férovom používaní ostáva: len osobné použitie, žiadne roboty ani hromadné kopírovanie (#199). Text v appke smie povedať „bez limitu“ len pri Max; pri Plus ostáva 1 000.
2. **20 vlastných balíkov za obdobie predplatného.** Nevyčerpané sa neprenášajú.
3. Hlas pri výbere novej témy: v1 ručne (founder pošle Max členom anketu), bez kódu.

## Riešenie

### Obdobie, nie kalendárny mesiac
Nárok sa obnovuje s **obdobím predplatného od Apple** (dátum nákupu → dátum obnovy), nie 1. v mesiaci. Pri kalendárnom mesiaci by sa dalo kúpiť 28., minúť 20, 1. minúť ďalších 20 a zrušiť: 40 balíkov za jednu platbu ≈ €128 nákladu proti €104 príjmu.

### Server (quiz-agent)
- **Limit otázok:** `UsageTracker` (`usage/tracker.py`) dostane pre úroveň `max` žiadny mesačný strop (Plus ostáva `SUBSCRIBER_MONTHLY_LIMIT`). Kontrola zásoby (#199) musí počítať s hráčmi, ktorí prehrajú celú knižnicu.
- **Úroveň predplatného:** dnes `account_is_entitled` vracia len áno/nie (`usage/entitlement.py:38`). Pridať úroveň `plus | max` odvodenú z `Subscription.product_id` a tabuľky `Product` (nový druh produktu). Všetko, čo dnes kontroluje „je predplatiteľ“, ostáva pravdou aj pre Max.
- **Účet nároku:** nová tabuľka `max_pack_allowance` (účet, začiatok a koniec obdobia, použité). Obdobie berie z RevenueCat udalostí (`INITIAL_PURCHASE`, `RENEWAL`, `PRODUCT_CHANGE`); pri `REFUND` / `EXPIRATION` sa zvyšok zruší (minuté sa vrátiť nedá, viď Riziká).
- **Poistka proti zneužitiu:** najviac 10 balíkov za deň (env, nie natvrdo). Doložka o férovom používaní už platí (#199).

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
Prepínač `max_enabled` v `/app-config` (DB prepínač, predvolene OFF) + skrytie v App Store builde ako pri hre spolu (`multiplayerHiddenByChannel`, `AppConfigStore.swift:70`). Kód sa zlučuje do `main` (pravidlo z 2026-10-16: flagy, nie dlhé vetvy); kým je prepínač OFF, hráč Max nevidí ani v TF. Founder súhlasil 2026-11-05.

### App Store Connect + RevenueCat
- Nové automaticky obnovované predplatné `com.carquiz.max.monthly`, €149,99, tá istá skupina ako Plus, vyššia úroveň. Texty en/sk/cs bez pomlčiek a bez „bez limitu“.
- RevenueCat: entitlement `max`, balík v offeringu; Plus offering ostáva.

## Koľko nákupov naraz (founder 2026-11-05)
Po #227 a #228 bude 5 platených vecí: Plus, Max, 100 otázok z knižnice, vlastný balík 10 a 30. Nikdy ich neukazovať všetky naraz; hráč vidí najviac 3 možnosti, a len tam, kde dávajú zmysel:
- **Došli otázky (paywall):** Plus a Max vedľa seba, Plus predvolene vybraný; 100 otázok ako malý odkaz pod nimi („Len 100 otázok za €2,99“). Max člen paywall nevidí.
- **Vlastný balík:** výber 10 alebo 30 otázok; Max člen namiesto ceny vidí „v cene Max“.
- **Profil:** len aktuálny plán a tlačidlo na zmenu.
Odporúčanie z praxe: viac ako 3 možnosti naraz zvyšuje váhanie a odchody; dve hlavné viditeľne, tretia menej výrazne. Kontrolovaný test pre presne náš prípad neexistuje, rozhodnú dáta z `max_paywall_view` / `max_purchase`.

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
