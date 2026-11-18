# #209 — App Store review: verzia bez testerských prvkov, súhlas s AI

**Triage:** bug · ready-for-human (kód hotový 2026-10-19; build pre App Review na požiadanie)
**Status:** kód v main; open = App Store build (`store: true`) → odoslať namiesto bežného buildu, doplniť Amazon (Bedrock) do privacy policy na webe
**Založené:** 2026-10-19 (verzia 1.1 v App Store review, hrozí zamietnutie podľa 2.2 a 5.1.2(i))
**Súvisí:** #155 — hodnotenie otázok v TestFlight, #176 — review odznaky, #197 — nahrávky odpovedí, #207 — pripravenosť na produkciu (tagy buildov, privacy štítky)

## Cieľ

App Review inštaluje appku so sandbox potvrdenkou, presne ako TestFlight. Preto videl testerské prvky (výzva „Pomôž zlepšiť rozpoznávanie reči“, hodnotenie otázky, diagnostika hlasu, review odznaky, neschválené otázky cez `X-Build-Channel`). TestFlight ich musí mať naďalej. Riešenie: druhý variant buildu z toho istého kódu, kde sú testerské prvky vypnuté už pri kompilácii.

## Čo sa zmenilo

- **Prepínač pri kompilácii:** `APP_STORE_VARIANT=YES` (Shared.xcconfig) pridá podmienku `APP_STORE`. `BuildChannel.isTestFlight` aj `debugSurfacesEnabled` potom vracajú vždy false, bez ohľadu na potvrdenku aj DEBUG. Všetky testerské prvky už išli cez `BuildChannel`, takže netreba meniť jednotlivé obrazovky:
  - výzva na nahrávky odpovedí (Home) a samotné ukladanie nahrávok,
  - hlavička `X-Build-Channel` (server potom dáva len schválené otázky, bez review odznakov a modelu),
  - Nastavenia › Diagnostika hlasu,
  - ⋯ › Ohodnotiť otázku (otázka aj výsledok),
  - minimálna verzia: App Store build berie `min_version_app_store` a odkaz do App Store.
- **Nákupy sa nemenia:** StoreKit ani RevenueCat `BuildChannel` nečítajú; prod backend prijíma Sandbox nákupy (#193), takže App Review vie kúpiť.
- **CI:** `ios-release.yml` má vstup `store` (predvolene false). Len s `environment: production`, tag `ios/<verzia>-b<build>-store`, nikdy sa neposiela externej (verejnej) beta skupine.
- **Súhlas s AI (5.1.2(i)):** prvá obrazovka onboardingu vymenúva AI služby (OpenAI, Anthropic, ElevenLabs, Amazon, OpenRouter) s odkazom na Privacy Policy; Pokračovať aj Preskočiť = súhlas, uložený s verziou textu (`AIProcessingConsent`). Rovnaký text je v Nastaveniach pod O aplikácii. Kto už onboarding prešiel, nedostane nové okno.
- **Drobnosti:** schéma `hangs-test://` len v Debug buildoch; „premium“ → „Trubbo Plus“ (prihlásenie, zmazanie účtu, objednávka balíka bez „prémiová“); poznámky pre App Review: hranie pri zamknutom telefóne a AI súhlas.
- **Privacy štítky:** `PrivacyInfo.xcprivacy` a `app_privacy_details.json` sa zhodujú (12 typov, všetky prepojené s identitou, žiadne sledovanie); Sign in with Apple nežiada meno ani e-mail. Bez zmeny, aby sedeli s ASC (207.21).

## Ako urobiť build pre App Review

```
gh workflow run ios-release.yml --ref main -f environment=production -f store=true
```

V App Store Connect potom pri verzii vybrať tento build (tag končí `-store`). Interní testeri ho v TestFlight uvidia tiež, ale bez testerských prvkov.

## Otvorené

- Privacy policy na webe (`apps/website/src/legal/privacy.*.html`) ešte nemenuje Amazon (Bedrock spracúva témy balíkov) a pri ElevenLabs uvádza prepis reči, ktorý už robí OpenAI. Treba upraviť pred odoslaním (founder: právny text).
- Ak sa zmení zoznam AI služieb: zmeniť text v appke, zvýšiť `AIProcessingConsent.currentVersion`, upraviť policy.
