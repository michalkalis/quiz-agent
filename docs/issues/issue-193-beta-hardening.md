# #193 — Spevnenie pred betou a pred reálnymi používateľmi

**Triage:** chore · in-progress
**Založené:** 2026-10-08 (founder: „čo nám ešte chýba pred betou — security, testy, čistota kódu, migrácie, staging, stabilita dát, robustnosť; bez veľkých zmien“)
**Zdroj:** 5 read-only auditov nad `origin/main` bbc9e044 (bezpečnosť, testy, čistota kódu, pripravenosť na betu, prevádzka pri reálnych používateľoch)

## Rozhodnutia foundera (2026-10-08)

- Externí TF testeri vidia **všetko ako dnes** (aj pending_review otázky, preklady, štítky, rating panel). Žiadny allowlist.
- Vlastné balíčky v bete idú **cez session workera na `mba`** (ako dnes). Fly worker ostáva zastavený; pred App Store treba prepnúť späť na platený Fly worker (pravidlo z #172 — session worker len pre betu).
- **Vynútená aktualizácia + serverový vypínač áno**, už v prvej verejnej verzii.
- Bez veľkých refaktorov; každá zmena = malá samostatná PR.

## Stav auditu (zhrnutie)

- Bezpečnosť: nič kritické; ownership, webhooky, StoreKit/SIWA overenie OK.
- Testy: ~3 500, CI zelené (TODO riadok „2 iOS flakes držia CI červené“ je zastaraný). ~8 slabých testov (sleep/časovanie, assert len na mock).
- Kód: čistý, 4 TODO v zdrojákoch, žiadne debug veci v Release. Veľké súbory (QuizViewModel 2 708 r.) → po bete.
- Obsah: ~1 400 approved/jazyk.
- `apps/web-ui` nie je v main, nič od neho nezávisí → len upratať odkazy.

## Vlna 1 — malé bezpečné opravy (bez rozhodnutia foundera)

- [ ] 193.1 StoreKit pre custom packy prijíma Production **aj** Sandbox (dnes len Sandbox → reálny App Store nákup by zlyhal) — `apps/quiz-pack-api/app/config.py`, `storekit/verifier.py`
- [ ] 193.2 Limity vstupov: dĺžka hlasovej odpovede pred STT, `max_length` písanej odpovede a `category`/`theme` objednávky, porovnanie tajomstiev cez bytes (500 pri non-ASCII), `/admin/health` za admin kľúčom, prepis odpovede v logoch len dĺžka
- [ ] 193.3 Monitoring: health-check oboch služieb + upozornenie na zaseknuté objednávky (`in_progress` dlhšie ako N min — kritické, keď `mba` worker nebeží); overiť, či sweep beží aj v session workerovi
- [ ] 193.4 Nočná záloha `quiz-pack-db` mimo Fly (šifrovaná) + auto-extend volume
- [ ] 193.5 Pravidlo migrácií (len pridávať, mazať o verziu neskôr, `questions` tabuľka zdieľaná s quiz-agent) do `.claude/rules/backend.md` + rollback postup v deploy skille
- [ ] 193.6 Upratanie odkazov na `apps/web-ui` (workflow, CODEOWNERS, CLAUDE.md, README, start-local skill) + zastarané TODO riadky
- [ ] 193.7 iOS: `QuestionAvailability.Limiter` toleruje neznámu hodnotu (staré buildy nespadnú pri novej hodnote zo servera)
- [x] 193.8 Zmazanie účtu: overiť a doplniť mazanie dát z anonymného ID pred prihlásením (feedback, analytika); audity sa rozchádzajú, najprv overiť — potvrdené (pravdu mal bezpečnostný audit): zmazanie účtu teraz zmaže aj stopu prepojených anonymných ID a anonymný používateľ má funkčné „Delete my data“ (predtým 404)
- [x] 193.15 Kredit providerov: `GET /api/v1/admin/provider-balances` (OpenRouter účet + limit kľúča, ElevenLabs znaky) + denná kontrola v quiz-agent → Sentry issue pri low/critical (jeden e-mail na provider+stav) — `apps/quiz-agent/app/monitoring/provider_balances.py`

## Vlna 2 — po rozhodnutí foundera

- [ ] 193.9 Minimálna verzia + `/api/v1/config` (min verzia, objednávky on/off, oznam) na serveri; iOS obrazovka „Aktualizuj aplikáciu“ (sk/cs/en)

## Vlna 3 — pred reálnymi používateľmi

- [ ] 193.10 Staging: oživiť uspané staging appky (scale-to-zero), nahrať dump prodov → zároveň skúška obnovy zo zálohy
- [x] 193.11 Výpadok LLM: parser + evaluator max 1 retry, ~10 s timeout, fallback „nepodarilo sa vyhodnotiť, skús znova“ — pokus 6 s, 1 retry, strop 8 s na volanie (`app/hot_path_llm.py`); výpadok = existujúca „povedz znova“ 400 (`no_answer`, `reason: judge_unavailable`), nič sa neboduje ani neúčtuje; Sentry 1× za 10 min
- [ ] 193.12 iOS: 1 bezpečný retry pri 502/503/odpojení (deploy = ~18 s výpadok)
- [ ] 193.13 Cost abuse: denný limit znakov na `/tts/synthesize`, denný strop objednávok na používateľa
- [ ] 193.14 Chýbajúce testy: prechod mesačného limitu cez hranicu mesiaca, sk/cs hodnotenie odpovedí, refund pri zlyhanom balíčku; nahradiť `sleep` v testoch zámkov eventom

## Founder kroky

- Vekové hodnotenie v ASC; stropy výdavkov u OpenAI / ElevenLabs / OpenRouter / Anthropic.
- `mba` session worker na aktuálnom main a zapnutý počas bety (inak objednávky visia).
- Popis v obchode stále tvrdí „balíčky len po anglicky“ → rieši session #190 — Externý TestFlight beta + App Store listing.

## Po bete

Rozdeliť veľké súbory (QuizViewModel, AudioService, advanced_generator), ruff štýlový backlog, kontajnery ako non-root, odosielanie surovej reči testerov do Sentry Logs prehodnotiť pred App Store.
