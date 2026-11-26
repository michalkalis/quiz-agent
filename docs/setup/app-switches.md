# Prepínače appky bez reštartu (#207 — pripravenosť na produkciu, úloha 207.18)

Vynútená aktualizácia (minimálna verzia), odporúčaná aktualizácia, režim údržby, vypínač objednávok vlastných balíčkov a oznam sa menia cez admin endpoint quiz-agent. Zmena sa prejaví hneď, bez reštartu stroja (Fly secret by reštartoval jediný stroj počas kvízu). Appka si `/app-config` načíta pri spustení a pri návrate do popredia (cache do 60 s).

| Prepínač | Hodnota | Účinok |
|---|---|---|
| `min_version_app_store`, `min_version_testflight` | `"1.2"` / `"1.2.3"`, `null` = bez minima | buildy pod verziou musia aktualizovať |
| `orders_enabled` | `true` / `false` | `false` skryje objednávanie v appke a quiz-pack-api odmietne nové objednávky (existujúce bežia ďalej) |
| `notice_sk`, `notice_cs`, `notice_uk`, `notice_en` | text do 300 znakov, `null` = bez oznamu | pruh s oznamom; chýbajúci jazyk padne na `en` |
| `recommended_version_app_store`, `recommended_version_testflight` (#214 — odporúčaná aktualizácia a údržba) | ako minimum, `null` = vypnuté | buildy pod verziou dostanú na Home kartu „Nová verzia Trubbo je pripravená“ s tlačidlom do obchodu; hráč ju zavrie a pri tej istej verzii sa už neukáže |
| `maintenance_enabled` | `true` / `false` | celá obrazovka „Hneď sme späť“ cez celú appku; appka sa každých 30 s pýta znova a po vypnutí pokračuje sama |
| `multiplayer_enabled_app_store` (#217 — Together v App Store buildi) | `true` / `false` | App Store build ukáže záložku Spolu a otvorí pozvánky len pri `true` (predvolene `false`); TestFlight buildy ju ignorujú a riadi ich `multiplayer_enabled`. Starší server pole nepošle = skryté |
| `maintenance_sk`, `maintenance_cs`, `maintenance_en` | text do 300 znakov, `null` = predvolený text | text na obrazovke údržby (napr. „Späť o 10:00.“) |
| `triage_bridge_enabled` (#218 — automatizácia pádov a spätnej väzby) | `true` / `false` | most do súkromného repa `trubbo-triage`: nové problémy zo Sentry, hlásenia z TestFlightu (webhook App Store Connect) a spätná väzba z appky. `false` = nič neposiela (napr. pri lavíne pádov); predvolene zapnutý. Bez `GITHUB_TRIAGE_DISPATCH_TOKEN` most nič neposiela ani so zapnutým prepínačom |
| `voice_limit_old_builds` (2026-11-21 — 30 hlasových odpovedí z bezplatných 150 otázok) | `true` / `false` | server odmietne hlasovú odpoveď po minutí bezplatných hlasových odpovedí aj buildom bez schopnosti `voice-allowance` (App Store 1.2 a TestFlight do 90). Takýto build ukáže len všeobecnú chybu „Too many requests“ s Try Again (späť na otázku, kde ide písať aj ťukať) a Go Home, nepovie prečo. `false` (predvolené) = starým buildom sa hlas len počíta, neodmieta; nové buildy so schopnosťou odmieta server vždy |
| `free_monthly_questions`, `free_monthly_voice_answers`, `plus_monthly_questions` (2026-11-26 — limity bez reštartu) | celé číslo; otázky zadarmo a Plus aspoň 1 (0 by bol tvrdý paywall), hlasové odpovede aj 0; `reset` = späť na env | mesačný limit otázok zadarmo (150), z nich hlasom (30) a v Trubbo Plus (1000) platí od ďalšej otázky. `/app-config` posiela `plus_monthly_questions`, aby paywall menoval to isté číslo. **Pozor:** buildy pred touto zmenou majú na paywalli „1,000“ natvrdo, limit Plus preto nemeň, kým ich hráči ešte používajú (App Store 1.2 a staršie, TestFlight buildy pred touto zmenou) |

Bez zmeny cez endpoint platí hodnota z env / Fly secretu (`MIN_APP_VERSION_*`, `PACK_ORDERS_ENABLED`, `APP_NOTICE_*`), presne ako predtým. Zmena cez endpoint má prednosť. Odporúčaná verzia, údržba, `multiplayer_enabled_app_store`, `voice_limit_old_builds` a `triage_bridge_enabled` nemajú env hodnotu, sú len v DB (predvolene vypnuté, `triage_bridge_enabled` predvolene zapnutý).

**Pozor pri odporúčanej verzii a údržbe:**
- Odporúčanú ani minimálnu verziu nezvyšuj, kým nový build nie je v App Store naozaj dostupný (pri postupnom vydaní ho hráč vie stiahnuť ručne, takže odporúčaná verzia je v poriadku od prvého dňa, minimum radšej až po dokončení).
- Údržbu poznajú len buildy, ktoré ju už majú (od verzie po 1.1). Staršie (1.1) uvidia len oznam, preto pri údržbe zapni aj `notice_*`.
- Údržba ide cez tento server. Keď server úplne spadne, appka, ktorá sa práve spúšťa, údržbu nezistí a ukáže bežnú chybu; zapni ju preto **pred** plánovaným odstavením.

Admin kľúč je v GitHub secrete `QUIZ_AGENT_ADMIN_API_KEY` (na laptope v `.env` ako `ADMIN_API_KEY` alebo cez `fly secrets`, ak ho máš).

```bash
# stav: čo appka dostáva, čo je prepnuté v DB, čo je v env
curl -s -H "X-Admin-Key: $KEY" https://quiz-agent-api.fly.dev/api/v1/admin/app-switches

# pozastaviť objednávky + oznam
curl -s -X PUT -H "X-Admin-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{"set": {"orders_enabled": false, "notice_sk": "Objednávky sú dnes pozastavené."}}' \
  https://quiz-agent-api.fly.dev/api/v1/admin/app-switches

# údržba zapnúť (s oznamom pre staršie buildy) / vypnúť
curl -s -X PUT -H "X-Admin-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{"set": {"maintenance_enabled": true, "maintenance_sk": "Späť o 10:00.", "notice_sk": "Dnes 9:00 až 10:00 údržba."}}' \
  https://quiz-agent-api.fly.dev/api/v1/admin/app-switches
curl -s -X PUT -H "X-Admin-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{"set": {"maintenance_enabled": false}, "reset": ["maintenance_sk", "notice_sk"]}' \
  https://quiz-agent-api.fly.dev/api/v1/admin/app-switches

# zapnúť Spolu (Together) pre App Store build (bez novej verzie appky) / vrátiť skryté
curl -s -X PUT -H "X-Admin-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{"set": {"multiplayer_enabled_app_store": true}}' \
  https://quiz-agent-api.fly.dev/api/v1/admin/app-switches
curl -s -X PUT -H "X-Admin-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{"reset": ["multiplayer_enabled_app_store"]}' \
  https://quiz-agent-api.fly.dev/api/v1/admin/app-switches

# vypnúť most do triáže (#218) / zapnúť späť
curl -s -X PUT -H "X-Admin-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{"set": {"triage_bridge_enabled": false}}' \
  https://quiz-agent-api.fly.dev/api/v1/admin/app-switches
curl -s -X PUT -H "X-Admin-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{"reset": ["triage_bridge_enabled"]}' \
  https://quiz-agent-api.fly.dev/api/v1/admin/app-switches

# vrátiť na hodnoty z env
curl -s -X PUT -H "X-Admin-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{"reset": ["orders_enabled", "notice_sk"]}' \
  https://quiz-agent-api.fly.dev/api/v1/admin/app-switches
```

Chybná hodnota (napr. verzia `v1.2`) vráti 422 a nezmení nič, ani ostatné prepínače z tej istej požiadavky. Uložené je to v tabuľke `app_switches` (migrácia quiz-agent `0015_app_switches`); quiz-pack-api z nej číta `orders_enabled` pri každej novej objednávke a pri chybe čítania použije svoju env hodnotu.
