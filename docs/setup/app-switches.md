# Prepínače appky bez reštartu (#207 — pripravenosť na produkciu, úloha 207.18)

Vynútená aktualizácia (minimálna verzia), vypínač objednávok vlastných balíčkov a oznam sa menia cez admin endpoint quiz-agent. Zmena sa prejaví hneď, bez reštartu stroja (Fly secret by reštartoval jediný stroj počas kvízu). Appka si `/app-config` načíta pri spustení a pri návrate do popredia (cache do 60 s).

| Prepínač | Hodnota | Účinok |
|---|---|---|
| `min_version_app_store`, `min_version_testflight` | `"1.2"` / `"1.2.3"`, `null` = bez minima | buildy pod verziou musia aktualizovať |
| `orders_enabled` | `true` / `false` | `false` skryje objednávanie v appke a quiz-pack-api odmietne nové objednávky (existujúce bežia ďalej) |
| `notice_sk`, `notice_cs`, `notice_en` | text do 300 znakov, `null` = bez oznamu | pruh s oznamom; chýbajúci jazyk padne na `en` |

Bez zmeny cez endpoint platí hodnota z env / Fly secretu (`MIN_APP_VERSION_*`, `PACK_ORDERS_ENABLED`, `APP_NOTICE_*`), presne ako predtým. Zmena cez endpoint má prednosť.

Admin kľúč je v GitHub secrete `QUIZ_AGENT_ADMIN_API_KEY` (na laptope v `.env` ako `ADMIN_API_KEY` alebo cez `fly secrets`, ak ho máš).

```bash
# stav: čo appka dostáva, čo je prepnuté v DB, čo je v env
curl -s -H "X-Admin-Key: $KEY" https://quiz-agent-api.fly.dev/api/v1/admin/app-switches

# pozastaviť objednávky + oznam
curl -s -X PUT -H "X-Admin-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{"set": {"orders_enabled": false, "notice_sk": "Objednávky sú dnes pozastavené."}}' \
  https://quiz-agent-api.fly.dev/api/v1/admin/app-switches

# vrátiť na hodnoty z env
curl -s -X PUT -H "X-Admin-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{"reset": ["orders_enabled", "notice_sk"]}' \
  https://quiz-agent-api.fly.dev/api/v1/admin/app-switches
```

Chybná hodnota (napr. verzia `v1.2`) vráti 422 a nezmení nič, ani ostatné prepínače z tej istej požiadavky. Uložené je to v tabuľke `app_switches` (migrácia quiz-agent `0015_app_switches`); quiz-pack-api z nej číta `orders_enabled` pri každej novej objednávke a pri chybe čítania použije svoju env hodnotu.
