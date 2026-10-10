# #199 — Stráženie zásoby otázok + Trubbo Plus s mesačným limitom

**Triage:** enhancement · in-progress
**Založené:** 2026-10-10 (founder: aktívna kontrola stavu otázok, aby sa napr. čerstvé otázky zo zábavy generovali vopred; predplatné „bez limitu“ sa dá zneužiť nonstop hraním)
**PR:** #358 (199.1 + plán), #359 (199.2), #357 (199.4), iOS 199.3 `feat/199-plus-ios`

## Cieľ

1. Founder dostane e-mail skôr, než v niektorom jazyku a kategórii dôjdu otázky, alebo než vyprší zásoba čerstvých otázok zo zábavy. Zostane mu tak čas vygenerovať ďalšie.
2. Súčasné predplatné prestane sľubovať „bez limitu“. Volá sa **Trubbo Plus** a má **1 000 otázok za kalendárny mesiac**. Podmienky dostanú doložku o férovom používaní.

## Rozhodnutia foundera (2026-10-10)

- **Prahy upozornení:** menej ako **50** hrateľných otázok v (jazyk × kategória), alebo menej ako **15** čerstvých otázok zo zábavy v jazyku, ktoré budú čerstvé ešte o 14 dní.
- **Predplatné:** názov **Trubbo Plus**, **1 000 otázok/mesiac**. Slovo „bez limitu / unlimited“ zmizne zo všetkých textov (appka, App Store, IAP, web, podmienky), „aby to nikto nemohol napadnúť“.
- **Po vyčerpaní limitu:** rovnako ako pri bezplatnom pláne. Najprv sa minú kúpené balíčky otázok, potom príde paywall s ponukou balíčka a odpočtom do nového mesiaca. Predplatné, ktoré už hráč má, sa mu znovu neponúka.
- **Doložka o férovom používaní:**
  - Knižnica otázok je konečná. Nové otázky pridávame podľa vlastného uváženia; predplatné nedáva nárok na určitý počet nových otázok za mesiac ani v kategórii či jazyku. Otázky sa môžu opakovať.
  - Len osobné použitie: žiadne roboty ani skripty, žiadne hromadné kopírovanie alebo export otázok a žiadny ďalší predaj.
  - Zákaz platených kvízov a podujatí s našimi otázkami. Párty, chata a deti sú v poriadku.
  - Vlastné balíčky (custom packs) sa platia zvlášť, nie sú súčasťou predplatného.
- **Drahší, naozaj neobmedzený plán:** zatiaľ nie. Je to samostatná úloha 199.5, robí sa až podľa dát o tom, či na limit niekto naráža.

## Kontext (recon 2026-10-10, origin/main `30f2b6f2`)

- Zásobu dnes nič nesleduje po (jazyk × kategória). Monitor `app/monitoring/question_monitor.py` počíta len podľa obtiažnosti a témy a jeho endpoint je verejný. Keď otázky dôjdu, kvíz skončí skôr (`flow.py`, `no_more_questions`).
- Sk/cs session vidí natívne riadky aj anglické riadky s `language_dependent = False` (preložené). Počet sa preto musí brať cez rovnaké pravidlo, aké používa výber otázok: `QuestionRetriever.count_available`.
- Vzor pre denné upozornenie je `app/monitoring/provider_balances.py`: denná slučka v procese, Sentry issue so stabilným fingerprintom a Sentry pošle e-mail. Rovnako sa správajú pomalé metriky, preto ho preberáme (a nie `prod-monitor.yml`, ktorý by pri trvalom nedostatku posielal e-mail každých 30 min).
- Predplatiteľom sa otázky dnes nepočítajú: `record_question` pri vetve s predplatným zapíše `questions_count = 0` a `get_usage` vracia `questions_limit = None`.
- „Unlimited“ sa vyskytuje v 9 kľúčoch v `Localizable.xcstrings`, v `PaywallView` / `SettingsView` / `HomePlanCard` / `RoundCompleteView`, v `Hangs.storekit`, `fastlane/store_copy.json`, `fastlane/metadata/*/description.txt` (4 jazyky), `review_information/notes.txt`, na webe `apps/website/src/strings/*.json` a v podmienkach `apps/quiz-agent/app/legal/terms.html` §4.

## Tracky

### 199.1 Denná kontrola zásoby (backend quiz-agent) — `[x]` nasadené 2026-10-10 (quiz-agent v149). Prvé čísla z produ: hrateľných otázok je v každom jazyku a kategórii 84 až 350 (najmenej šport), všetko nad 50. Čerstvej zábavy je en 10 / sk 19 / cs 23, takže **en je pod prahom 15** a prvé upozornenie odišlo.
- Nový modul `app/monitoring/question_stock.py`, vzorom je `provider_balances.py`. Pre každý obsluhovaný jazyk × kategóriu z `CATEGORY_TAXONOMY` vytvorí skúšobnú session a spočíta otázky cez `count_available` (iba schválené, teda to, čo vidí App Store). K tomu pre každý jazyk spočíta čerstvé otázky zo zábavy, ktorým zvýhodnenie platí ešte o 14 dní. Trvalé zvýhodnenie (9999-01-01) sa nepočíta, lebo nikdy nevyprší.
- Zdieľaný `_build_where` dostane operátory `$gt` / `$lt`. `count_available` dostane voliteľné `extra_filters`.
- Prahy idú cez env `QUESTION_STOCK_MIN_PER_CELL=50`, `QUESTION_STOCK_MIN_FRESH=15` a `QUESTION_STOCK_FRESH_HORIZON_DAYS=14`. Zapína sa cez `QUESTION_STOCK_CHECK_ENABLED` (v `fly.toml` true).
- Sentry: jedna issue na nedostatkový (jazyk, kategória) a jedna na čerstvú zásobu jazyka, fingerprint je stabilný.
- Admin endpoint `GET /api/v1/admin/question-stock` (admin kľúč) vráti celú tabuľku na vyžiadanie.
- **Hotovo keď:** testy pokrývajú výpočet aj fingerprinty, nasadené, endpoint v prode vráti tabuľku a jej čísla sú v PR.
- Implementácia: `app/monitoring/question_stock.py`, `app/api/routes/question_stock.py`, testy `tests/test_question_stock.py` + `tests/db/test_question_stock_counts.py` + `packages/shared/tests/test_where_gt_lt.py`. Navyše `QUESTION_STOCK_INITIAL_DELAY_S` (default 180 s, ako pri kontrole kreditov); prázdna bunka (0) ide do Sentry ako `error`, nízka ako `warning`.

### 199.2 Trubbo Plus limit + podmienky (backend quiz-agent) — `[x]` nasadené 2026-10-10 (v149), podmienky naživo
- `UsageTracker`: limit pre predplatiteľa je `SUBSCRIBER_MONTHLY_LIMIT` (default 1000), pre ostatných `FREE_MONTHLY_LIMIT`. Ostatok sa nemení: jedno mesačné počítadlo na účet a po limite idú kúpené balíčky. Ak predplatné skončí uprostred mesiaca, platí limit 30 voči tomu istému počítadlu.
- `get_usage` vráti predplatiteľovi skutočné čísla `questions_limit` a `remaining`. Starý `is_premium` bez predplatného ostáva bez zmeny.
- 429 `quota_limit_reached` pošle predplatiteľovi `upgrade_available: false` (quiz.py aj flow.py).
- Podmienky §4 (sk/cs/en): Trubbo Plus má 1 000 otázok za mesiac, k tomu nová časť o férovom používaní podľa rozhodnutí vyššie. Nový dátum účinnosti.
- **Hotovo keď:** testy pokrývajú limit predplatiteľa, prechod do balíčkov po limite, skončenie predplatného uprostred mesiaca a `upgrade_available`. Zmena je nasadená.

### 199.3 Appka: Trubbo Plus namiesto „bez limitu“ (iOS) — `[x]` kód v PR; po zlúčení `/design-sync` (zmenené snapshoty karty plánu); TF build len na požiadanie
- Texty sk/cs/en: paywall, nastavenia, karta na domovskej obrazovke, výsledková obrazovka a hláška po kúpe. Predplatiteľ vidí zostatok otázok rovnako ako pri bezplatnom pláne.
- Paywall pri `upgrade_available == false` ponúkne len balíček a odpočet, predplatné nie.
- `Hangs.storekit` so zobrazovanými názvami. Snapshot testy treba aktualizovať.
- TestFlight build sa nerobí, len na požiadanie foundera.

### 199.4 Obchod + web — `[x]` texty v PR #357; **open = nahranie do App Store Connect až s TF buildom, ktorý má nové texty** (súhlas foundera)
- `fastlane/metadata/{en-US,en-GB,sk,cs}/description.txt`, `store_copy.json` (názov skupiny aj produktu), `review_information/notes.txt`, web `apps/website/src/strings/*.json`, potom `build.py`.
- Nahranie do App Store Connect je externý krok. Robí sa so súhlasom foundera.

### 199.5 Drahší neobmedzený plán (Trubbo Max?) — odložené
Nový produkt v ASC a RevenueCat, paywall s dvoma plánmi a druhá úroveň v `UsageTracker`. Spúšťa sa až podľa dát (`quota_hit` udalosti predplatiteľov).
