# #214 — Odporúčaná aktualizácia a režim údržby

**Triage:** enhancement · done (kód; ide s najbližším buildom)
**Status:** 2026-10-28 founder: do ďalšej verzie (1.1 ostáva v review), karta na Home + údržba cez celú obrazovku.
**Súvisí:** #193 — beta hardening (193.9 vynútená aktualizácia), #207 — pripravenosť na produkciu (207.18 prepínače bez reštartu) · [research](../research/app-versioning-messages-2026-10-28.md)

## Cieľ

Pripraviť appku tak, aby sme zo servera vedeli bez nového vydania:
1. jemne odporučiť novú verziu (hráč môže ignorovať),
2. počas údržby ukázať pokojnú obrazovku namiesto „Chyba servera“, a appka pokračuje sama, keď údržba skončí.

## Riešenie

- **Server (quiz-agent):** nové DB prepínače `recommended_version_app_store/_testflight`, `maintenance_enabled`, `maintenance_sk/cs/en`; `/app-config` ich posiela (len pridané polia, staršie buildy ich ignorujú). Bez env hodnôt, predvolene vypnuté. Návod: [app-switches.md](../setup/app-switches.md).
- **Appka:**
  - karta „Nová verzia Trubbo je pripravená“ na Home nad oznamom, tlačidlo do App Store / TestFlight, zavretie platí pre danú verziu,
  - obrazovka „Hneď sme späť“ cez celú appku (ako vynútená aktualizácia), text zo servera alebo predvolený, bez tlačidla (hráč môže šoférovať), každých 30 s sa pýta znova,
  - vynútená aktualizácia má prednosť pred údržbou aj kartou.

## Testy

- Backend: `test_app_config.py`, `test_app_switches_db.py` (zapnutie/vypnutie naživo, zlé hodnoty odmietnuté).
- iOS: `AppConfigStoreTests` (verzia per kanál, zavretie per verzia, údržba končí sama, výpadok ju nevypne, prednosť vynútenej aktualizácie); RS-26, RS-27.

## Známe obmedzenia

- Údržbu poznajú len buildy s #214; pre 1.1 treba zároveň oznam.
- Pri úplnom páde servera appka údržbu nezistí (konfigurácia je na tom istom serveri) → zapínať pred plánovaným odstavením. Záloha mimo servera zámerne odložená (founder 2026-10-28).
