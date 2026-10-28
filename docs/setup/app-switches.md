# Prepínače appky bez reštartu (#207 — pripravenosť na produkciu, úloha 207.18)

Vynútená aktualizácia (minimálna verzia), odporúčaná aktualizácia, režim údržby, vypínač objednávok vlastných balíčkov a oznam sa menia cez admin endpoint quiz-agent. Zmena sa prejaví hneď, bez reštartu stroja (Fly secret by reštartoval jediný stroj počas kvízu). Appka si `/app-config` načíta pri spustení a pri návrate do popredia (cache do 60 s).

| Prepínač | Hodnota | Účinok |
|---|---|---|
| `min_version_app_store`, `min_version_testflight` | `"1.2"` / `"1.2.3"`, `null` = bez minima | buildy pod verziou musia aktualizovať |
| `orders_enabled` | `true` / `false` | `false` skryje objednávanie v appke a quiz-pack-api odmietne nové objednávky (existujúce bežia ďalej) |
| `notice_sk`, `notice_cs`, `notice_en` | text do 300 znakov, `null` = bez oznamu | pruh s oznamom; chýbajúci jazyk padne na `en` |
| `recommended_version_app_store`, `recommended_version_testflight` (#214) | ako minimum, `null` = vypnuté | buildy pod verziou dostanú na Home kartu „Nová verzia Trubbo je pripravená“ s tlačidlom do obchodu; hráč ju zavrie a pri tej istej verzii sa už neukáže |
| `maintenance_enabled` (#214) | `true` / `false` | celá obrazovka „Hneď sme späť“ cez celú appku; appka sa každých 30 s pýta znova a po vypnutí pokračuje sama |
| `maintenance_sk`, `maintenance_cs`, `maintenance_en` (#214) | text do 300 znakov, `null` = predvolený text | text na obrazovke údržby (napr. „Späť o 10:00.“) |

Bez zmeny cez endpoint platí hodnota z env / Fly secretu (`MIN_APP_VERSION_*`, `PACK_ORDERS_ENABLED`, `APP_NOTICE_*`), presne ako predtým. Zmena cez endpoint má prednosť. Odporúčaná verzia a údržba (#214) nemajú env hodnotu, sú len v DB (predvolene vypnuté).

**Pozor pri #214:**
- Odporúčanú ani minimálnu verziu nezvyšuj, kým nový build nie je v App Store naozaj dostupný (pri postupnom vydaní ho hráč vie stiahnuť ručne, takže odporúčaná verzia je v poriadku od prvého dňa, minimum radšej až po dokončení).
- Údržbu poznajú len buildy s #214. Staršie (1.1) uvidia len oznam, preto pri údržbe zapni aj `notice_*`.
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

# vrátiť na hodnoty z env
curl -s -X PUT -H "X-Admin-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{"reset": ["orders_enabled", "notice_sk"]}' \
  https://quiz-agent-api.fly.dev/api/v1/admin/app-switches
```

Chybná hodnota (napr. verzia `v1.2`) vráti 422 a nezmení nič, ani ostatné prepínače z tej istej požiadavky. Uložené je to v tabuľke `app_switches` (migrácia quiz-agent `0015_app_switches`); quiz-pack-api z nej číta `orders_enabled` pri každej novej objednávke a pri chybe čítania použije svoju env hodnotu.
