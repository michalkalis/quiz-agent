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

Sudcovia sú v session režime vždy vypnutí, worker sa s nimi odmietne naštartovať. Na mba platí to isté, len tam najprv zosynchronizuj checkout s prodom (pozri hore).

## C. Over objednávkou

8. V TestFlight appke kúp custom pack (sandbox).
9. Sleduj log (`status`) alebo admin UI so stavom objednávky: `pending` prejde na `in_progress` a nakoniec `delivered`.
10. Ak je worker offline alebo tunel spadne, job počká v Redise a sweep ho znova zaradí. Každé takéto zaradenie míňa jeden pokus z rozpočtu objednávky, po vyčerpaní stav skončí ako `failed` s `refund_eligible`.

## D. Rollback

11. `fly secrets unset ORDER_QUEUE_NAME -a quiz-pack-api`
12. `fly machine start <id> -a quiz-pack-api` (worker stroj)
13. Zastav worker aj tunely: `apps/quiz-pack-api/scripts/session_worker_local.sh stop`.

Objednávky, ktoré v tej chvíli ležia na fronte `quiz-pack:session`, si buď nechaj dobehnúť na mba pred krokom 13, alebo ich po prepnutí pošli znova cez `POST /v1/orders/{id}/retry`.
