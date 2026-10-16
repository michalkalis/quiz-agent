# Záložný worker na mba (#207 — Fly worker primárne, mba záloha)

Platené vlastné balíčky generuje **Fly `worker`** aplikácie `quiz-pack-api` cez priame Anthropic API (mesačný Max kredit; rezervu $25 pre balíčky drží `credit_gate` korpusu). `mba` beží ako **záloha** na Claude Code predplatnom (`LLM_GATEWAY=session`, #172). Rozhodnutie foundera 2026-10-16.

## Ako záloha funguje

- Oba workery počúvajú na **tej istej** fronte (`arq:queue`, `ORDER_QUEUE_NAME` ani `WORKER_QUEUE_NAME` sa nikde nenastavujú).
- Záložný worker (`python -m app.worker.backup`) je pripojený, ale objednávky **neberie**, kým Fly worker žije. Berie ich až keď:
  - Fly worker nemá heartbeat (`arq:queue:health-check`) aspoň 5 min (`BACKUP_FLY_DOWN_GRACE_S`, reštart pri deployi trvá ~1–2 min), alebo
  - objednávka čaká vo fronte nevyzdvihnutá aspoň 15 min (`BACKUP_QUEUE_WAIT_S`), napr. Fly má obsadené obe miesta dlhými balíčkami.
- Keď sa Fly worker vráti, záloha prestane brať nové objednávky; rozbehnutú dokončí.
- Dvojité generovanie nehrozí: úlohu si worker zaberá atomicky cez ARQ (`arq:in-progress:<id>`), `process_order` preskočí prekonaný pokus (#193) a sweep pred obnovou objednávky znova overí pod zámkom riadku, že je stále zaseknutá.
- Pri prevzatí pošle záloha udalosť do Sentry („mba backup worker took over pack orders“). Vlastný heartbeat zapisuje do `quiz-pack:backup:health-check`.
- Fly worker s inou frontou, než na ktorú idú objednávky, odmietne štart (zlý deploy je vidieť hneď, nie ako hromadiace sa objednávky).

## A. Spusti zálohu na mba (jednorazovo, keď je mba dostupný)

Spúšťaj z prihláseného GUI používateľa `agent` (napr. Remote Control session), claude.ai login je v Keychaine.

1. Na mba: `git -C <repo> fetch origin && git -C <repo> switch main && git -C <repo> pull`. Checkout musí byť zhodný s nasadeným prodom, inak worker odmietne štart na Alembic boot checku.
2. Over koreňový `.env` na mba: `PROD_DATABASE_URL` (tvar `localhost:15432`), `PROD_REDIS_URL` (`redis://:<heslo>@localhost:16379/0`), `OPENAI_API_KEY` (embeddingy a obrázky ostávajú na OpenAI). Chýbajúce heslo Redisu doplníš (nevypíše sa):
   `printf 'PROD_REDIS_URL=redis://:%s@localhost:16379/0\n' "$(env -u FLY_API_TOKEN fly ssh console -a quiz-pack-redis -C 'printenv REDIS_PASSWORD' | tr -d '\r\n')" >> .env`
3. `apps/quiz-pack-api/scripts/session_worker_local.sh install-launchd` (idempotentné; preinštaluje aj starý session worker z #172). Zapíše `~/Library/LaunchAgents/com.missinghue.quiz-session-worker.plist`, launchd spustí `supervise`: tunely na `quiz-pack-db` (15432) a `quiz-pack-redis` (16379), potom záložný worker v popredí. Keď spadne, launchd ho do 30 s spustí znova aj s novými tunelmi.
4. `apps/quiz-pack-api/scripts/session_worker_local.sh status` a log `~/Library/Logs/quiz-session-worker/worker.log`. Hľadaj riadky `worker on_startup: collaborators initialised gateway=session queue_name=arq:queue max_jobs=1 job_timeout=14400` a `backup worker ready: queue=arq:queue, takes jobs only after 300 s ...`.
5. Over z laptopu: `GET https://quiz-pack-api.fly.dev/api/v1/admin/worker/heartbeat` (hlavička `X-Admin-Key`) vracia `backup_heartbeat_age_s` ako číslo, nie `null`.

Po reštarte mba agent naštartuje až po GUI prihlásení používateľa `agent` (auto-login je vypnutý). Odinštalovanie: `... session_worker_local.sh uninstall-launchd`.

## B. Prevádzka

- `prod-monitor.yml` (každých 30 min) zlyhá a GitHub pošle e-mail, keď Fly worker nemá heartbeat ani po ~3 min opakovaní, aj keď záloha práve kryje. V logu behu je aj stav zálohy.
- `fly deploy` workera len reštartuje; po deployi musí byť `worker` v `fly status -a quiz-pack-api` `started`. Nič sa ručne nezastavuje.
- Krátky výpadok Redisu (do ~90 s) worker prečká, dlhší ho ukončí a reštartuje launchd (mba) alebo Fly.
- Sudcovia sú na predplatnom vždy vypnutí, worker sa s nimi odmietne naštartovať.

## C. Núdzové prepnutie len na mba (napr. dlhý výpadok Fly workera)

Netreba nič prepínať: záloha prevezme objednávky sama do 5 min. Ak má Fly worker ostať vypnutý dlhšie: `fly machine stop <id worker stroja> -a quiz-pack-api`. Späť: `fly machine start <id> -a quiz-pack-api`. Starý režim s oddelenou frontou (`ORDER_QUEUE_NAME=quiz-pack:session`) sa už nepoužíva; Fly worker by s ním odmietol štart.
