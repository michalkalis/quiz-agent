# #221 — Technická modernizácia (knižnice, Python, CI)

**Triage:** chore · ready-for-agent
**Status:** 2026-11-01 founder: smer schválený v prehľade „na čom ďalej“; technické rozhodnutia robí agent sám.
**Súvisí:** #217 — verejné vydanie v App Store · #218 — automatické crashe a feedback · #207 — pripravenosť na produkciu

## Cieľ

Nebyť na zastaraných verziách pred verejným vydaním. Každý krok je samostatný PR, appka ani hra sa pre hráča nemenia.

## Stav (audit 2026-11-01)

| Časť | Máme | Najnovšie | Riziko |
|---|---|---|---|
| Sentry v appke (sentry-cocoa) | 8.58.1 | 9.32.0 (2026-10-29) | stredné, nová hlavná verzia |
| RevenueCat (purchases-ios) | 5.94.0 | 5.99.x | nízke |
| Python v Dockerfiloch | 3.11.17 | 3.14.x | nízke až stredné (koniec podpory 3.11 ~10/2027) |
| FastAPI | 0.143.2 | ~0.153+ (neoverené presne) | nízke |
| `google-generativeai` v quiz-pack-api | závislosť bez jediného importu | balík zastaraný (nástupca `google-genai`) | nízke, zbytočná váha obrazu |
| Spodné hranice závislostí | napr. fastapi>=0.104, sentry-sdk>=2.0 | uzamknuté oveľa vyššie | nízke, hranice netestované |
| iOS CI | obraz `xcode-27` (public preview), 42–46 min na beh | Xcode 27 GA / 27.1 | stredné (pomalé, krehké) |
| Prekresľovanie obrazoviek | `ObservableObject` v 26 súboroch, `@Observable` 0 | Observation (iOS 17+) | nízke, výkon + menej kódu |
| Redis (quiz-pack-redis) | 7.4 | 8.x | nízke |

Už v poriadku: modely Claude 5.5, min. iOS 26, Swift 6 so striktnou súbežnosťou, Swift Testing (189 vs 23 XCTest súborov), Dependabot, GitHub secret scanning + push protection zapnuté, skriptové knižnice (gradio, geopandas…) mimo produkčného obrazu (#207 — 207.24).

## Úlohy

### 221.1 — Odstrániť nepoužívanú knižnicu Google, zdvihnúť spodné hranice (PR #659)
- Čo: vyhodiť `google-generativeai` z quiz-pack-api; spodné hranice v pyproject zdvihnúť na uzamknuté hlavné verzie (všetky 4 pyproject).
- Prečo: menší obraz, žiadny zastaraný balík; deklarované verzie zodpovedajú testovaným.
- Hotové: `uv lock` bez neho, testy oboch služieb zelené, Dockerfile zoznam 1:1 s pyproject (pamäť „Dockerfile drift“).

### 221.2 — Aktualizovať serverové knižnice
- Čo: FastAPI, uvicorn, pydantic, sentry-sdk, openai, anthropic, httpx cez `uv lock --upgrade-package`.
- Hotové: testy zelené, OpenAPI kompatibilita (oasdiff gate) zelená, nasadené, `/health` OK.

### 221.3 — Python 3.11 → 3.13
- Čo: nový digest-pinned obraz `python:3.13-slim-trixie` v oboch Dockerfiloch, `requires-python`, CI. 3.14 až keď budú mať wheely všetky závislosti (overiť pydantic-core, chromadb).
- Prečo: rýchlejší server na hlavnej ceste kvízu, dlhšia podpora.
- Hotové: CI zelené, nasadené, latencia `/health` a odpovede nehoršia ako pred zmenou (porovnať v Sentry).

### 221.4 — Sentry v appke 8 → 9
- Čo: prečítať oficiálny migračný návod, aktualizovať SPM, prispôsobiť nastavenie. Zachovať `beforeSend` cenzor reči hráča a zbierku spätnej väzby (shake-to-report). Zapnúť MetricKit diagnostiku a prílohy pri zamrznutí, ak sú v 9 nové.
- Prečo: lepšie hlásenia pádov a zamrznutí; predpoklad pre #218.
- Hotové: build + cielené testy zelené; testovací crash z Debug buildu dorazí do Sentry so zachovaným cenzorom. (PR #662; 9.32.0, MetricKit/hang prílohy sú len experimental → nezapnuté)

### 221.5 — RevenueCat menšia aktualizácia
- Hotové: build zelený, nákupné testy (StoreKit config) zelené (PR #662; 5.100.0). Ide spolu s 221.4 v jednom iOS PR, ak migrácia Sentry nie je veľká.

### 221.6 — iOS CI na stabilný Xcode
- Čo: keď GitHub vydá GA obraz s Xcode 27.x, prepnúť `runs-on` a `xcode-select`; inak skontrolovať, či `macos-26` obraz už nemá Xcode 27.1.
- Hotové: iOS CI beh kratší a zelený 3× za sebou.

### 221.7 — Prechod na `@Observable` (vo vlnách)
- Čo: ViewModely z `ObservableObject` na Observation, po skupinách (kvíz, domov, profil, balíky), každá vlna samostatný PR. Nie zmiešané napoly v jednej obrazovke.
- Prečo: menej zbytočných prekreslení počas kvízu, menej kódu.
- Hotové: cielené testy ViewModelov zelené, snapshoty bez zmeny, regresné RS scenáre pre dotknuté obrazovky prejdú.
- Pozn.: najnižšia priorita; robiť až po 221.1–221.6.

### 221.8 — Redis 7.4 → 8
- Čo: overiť kompatibilitu `arq`/`redis` klienta, prepnúť obraz v `infra/quiz-pack-redis`.
- Hotové: fronta objednávok balíkov beží, testovacia objednávka prejde.

### 221.9 — openai SDK 3.x
- Čo: dnes je `openai<3` a `langchain-openai<1.5`, lebo 3.x prešlo na httpx2 a testovacie mocky (respx) ho nezachytia. Prepísať mocky, potom zdvihnúť obe hranice v lockstepe (shared + obe appky).
- Hotové: integračné testy quiz-pack-api zachytia všetky HTTP volania (žiadne skutočné volanie API v teste), obrazy nasadené a zdravé.

## Pravidlá

- Žiadne zmeny modelov AI (pamäť: zmena modelu len s eval dátami a súhlasom).
- Každý PR prejde Claude review a CI; backend sa nasadzuje hneď po zlúčení.
