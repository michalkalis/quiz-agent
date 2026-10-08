# Session worker na mba (#172 — Session worker: custom packy v bete cez subscription)

Objednávky custom packov z TestFlightu spracuje `mba` cez Claude Code subscription (`LLM_GATEWAY=session`), nie platené API na Fly. Prod backend sa nemení: prijatie objednávky, StoreKit, stavy, SSE progres aj uloženie packu ostávajú rovnaké. Mení sa len stroj, ktorý pipeline počíta.

**Pred začiatkom:** na `mba` musí byť checkout `main` zhodný s nasadeným prodom, inak worker odmietne štart na Alembic boot checku (kontrola hlavy migrácií proti prod DB). Skontroluj `git log -1` na mba a na Fly deployi.

## A. Prepni prod na session frontu

1. Na svojom Macu: `export FLY_API_TOKEN=$FLY_API_TOKEN_QUIZ_PACK_API` (token je app scoped, pozri `.env`).
2. `fly secrets set ORDER_QUEUE_NAME=quiz-pack:session -a quiz-pack-api`
   Od tejto chvíle API aj sweep zaraďujú nové objednávky na frontu `quiz-pack:session`.
3. `fly machine stop <id> -a quiz-pack-api` (id worker stroja z `fly status -a quiz-pack-api`).
   Fly worker sa uspí. Nič nemaže, je to len záloha pre rollback. Pozor: ďalší `fly deploy` ho znova naštartuje, po deployi ho zastav znova (deploy skill to pripomína).

## B. Spusti worker (tento Mac alebo mba)

4. Jednorazovo ulož heslo prod Redisu do koreňového `.env` (heslo sa nevypíše):
   `printf 'PROD_REDIS_URL=redis://:%s@localhost:16379/0\n' "$(env -u FLY_API_TOKEN fly ssh console -a quiz-pack-redis -C 'printenv REDIS_PASSWORD' | tr -d '\r\n')" >> .env`
   `PROD_DATABASE_URL` (tvar `localhost:15432`) a `OPENAI_API_KEY` už v `.env` sú. `OPENAI_API_KEY` treba aj v session režime: embeddingy a obrázky ostávajú na OpenAI (#169).
5. Spusti všetko jedným príkazom: `apps/quiz-pack-api/scripts/session_worker_local.sh start`
   Otvorí tunely na `quiz-pack-db` (15432) a `quiz-pack-redis` (16379), nastaví env (session brána, fronta `quiz-pack:session`, 1 job naraz, 4 h limit, sudcovia vypnutí) a spustí `run_session_worker.sh` na pozadí. Ten najprv preverí `claude` login a premenné; ak niečo chýba, vypíše presný dôvod a skončí.
6. Stav a log: `... session_worker_local.sh status`, zastavenie workera aj tunelov: `... session_worker_local.sh stop`. Logy: `~/Library/Logs/quiz-session-worker/`.
7. V logu hľadaj riadok `worker on_startup: collaborators initialised gateway=session queue_name=quiz-pack:session max_jobs=1 job_timeout=14400`.

### Trvalý beh na mba: launchd (#193 — beta hardening)

`start` je jednorazový beh: keď worker spadne (2026-10-08 ho zabil výpadok Redis tunela a ~20 h ležal mŕtvy), nikto ho nenaštartuje. Na mba preto bež cez LaunchAgent:

- Inštalácia (aj opakovaná, je idempotentná): `apps/quiz-pack-api/scripts/session_worker_local.sh install-launchd`. Zastaví prípadný ručný worker, zapíše `~/Library/LaunchAgents/com.missinghue.quiz-session-worker.plist` a načíta ho do `gui/<uid>` (claude.ai login je v Keychaine, raw ssh kontext ho nevidí). Spúšťaj z prihláseného GUI používateľa, napr. z Remote Control session. `PATH` sa do plistu zapíše z aktuálneho shellu, takže `fly` aj `claude` musia byť na PATH.
- launchd spúšťa `supervise`: otvorí tunely a worker beží v popredí. Keď skončí, launchd ho do 30 s spustí znova aj s novými tunelmi (KeepAlive, ThrottleInterval 30). Log ostáva v `~/Library/Logs/quiz-session-worker/worker.log`.
- Krátky výpadok Redisu (do ~90 s) worker prečká sám, reconnect s backoffom. Dlhší výpadok ho ukončí a reštartuje launchd.
- `status` ukáže aj stav launchd (`state`, `runs`, `last exit code`). `start`/`stop` pri nainštalovanom agentovi odmietnu bežať; zastavenie = `uninstall-launchd` (odstráni agenta, worker aj tunely).
- Po reštarte mba agent naštartuje až po GUI prihlásení používateľa `agent` (auto-login je vypnutý).

**Upozornenie pri mŕtvom workeri:** worker každých 60 s obnovuje v Redise kľúč `quiz-pack:session:health-check`. `prod-monitor.yml` (každých 30 min) volá `GET /api/v1/admin/worker/heartbeat`; keď orders idú na session frontu a kľúč chýba ani po ~3 min opakovaní, beh zlyhá a GitHub pošle e-mail, aj keď nečaká žiadna objednávka. Pri Fly worker režime (fronta `arq:queue`) sa nič nekontroluje, ten stroj je zámerne zastavený.

Sudcovia sú v session režime vždy vypnutí, worker sa s nimi odmietne naštartovať. Na mba platí to isté, len tam najprv zosynchronizuj checkout s prodom (pozri hore).

## C. Over objednávkou

8. V TestFlight appke kúp custom pack (sandbox).
9. Sleduj log (`status`) alebo admin UI so stavom objednávky: `pending` prejde na `in_progress` a nakoniec `delivered`.
10. Ak je worker offline alebo tunel spadne, job počká v Redise a po štarte workera sa spracuje; čakanie vo fronte (aj za iným dlhým packom) nemíňa pokusy. Sweep znova zaradí len objednávku, ktorej worker zomrel uprostred behu (bez heartbeatu 15 min). Každé takéto zaradenie míňa jeden pokus z rozpočtu objednávky, po vyčerpaní stav skončí ako `failed` s `refund_eligible`.

## D. Rollback

11. `fly secrets unset ORDER_QUEUE_NAME -a quiz-pack-api`
12. `fly machine start <id> -a quiz-pack-api` (worker stroj)
13. Zastav worker aj tunely: `apps/quiz-pack-api/scripts/session_worker_local.sh uninstall-launchd` (pri ručnom behu `stop`).

Objednávky, ktoré v tej chvíli ležia na fronte `quiz-pack:session`, si buď nechaj dobehnúť na mba pred krokom 13, alebo ich po prepnutí pošli znova cez `POST /v1/orders/{id}/retry`.
