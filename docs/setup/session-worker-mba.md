# Session worker na mba (#172 — Session worker: custom packy v bete cez subscription)

Objednávky custom packov z TestFlightu spracuje `mba` cez Claude Code subscription (`LLM_GATEWAY=session`), nie platené API na Fly. Prod backend sa nemení: prijatie objednávky, StoreKit, stavy, SSE progres aj uloženie packu ostávajú rovnaké. Mení sa len stroj, ktorý pipeline počíta.

**Pred začiatkom:** na `mba` musí byť checkout `main` zhodný s nasadeným prodom, inak worker odmietne štart na Alembic boot checku (kontrola hlavy migrácií proti prod DB). Skontroluj `git log -1` na mba a na Fly deployi.

## A. Prepni prod na session frontu

1. Na svojom Macu: `export FLY_API_TOKEN=$FLY_API_TOKEN_QUIZ_PACK_API` (token je app scoped, pozri `.env`).
2. `fly secrets set ORDER_QUEUE_NAME=quiz-pack:session -a quiz-pack-api`
   Od tejto chvíle API aj sweep zaraďujú nové objednávky na frontu `quiz-pack:session`.
3. `fly scale count worker=0 -a quiz-pack-api`
   Fly worker sa uspí. Nič nemaže, je to len záloha pre rollback.

## B. Spusti worker na mba

4. `ssh mba-lan` a `tmux new -s packworker`.
5. Okno 1 (Postgres tunel), nechaj bežať: `fly proxy 15432:5432 -a quiz-pack-db`
6. Okno 2 (Redis tunel, `Ctrl-b c` vytvorí nové okno), nechaj bežať: `fly proxy 16379:6379 -a quiz-pack-redis`
7. Heslo k prod Redisu si vypíš takto (celé URL aj s heslom): `fly ssh console -a quiz-pack-api -C "printenv REDIS_URL"`. Prod DB URL máš v `apps/quiz-pack-api/.env` ako `PROD_DATABASE_URL`.
8. Okno 3, exporty (hostitele prepíš na localhost, aby išli cez tunely z krokov 5 a 6):

```bash
cd ~/quiz-agent
export DATABASE_URL='postgresql+asyncpg://postgres:<heslo>@localhost:15432/quiz_pack'
export REDIS_URL='redis://:<heslo>@localhost:16379/0'
export OPENAI_API_KEY="$(grep '^OPENAI_API_KEY=' .env | cut -d= -f2-)"
export LLM_GATEWAY=session
export ORDER_QUEUE_NAME=quiz-pack:session
export WORKER_QUEUE_NAME=quiz-pack:session
export WORKER_MAX_JOBS=1
export WORKER_JOB_TIMEOUT_S=14400
unset JUDGE_GATE JUDGE_MODELS
```

`OPENAI_API_KEY` treba aj v session režime: embeddingy a obrázky ostávajú na OpenAI (#169). Sudcovia sú v session režime vždy vypnutí, worker sa s nimi odmietne naštartovať.

9. Spusti worker: `apps/quiz-pack-api/scripts/run_session_worker.sh`
   Skript najprv preverí `claude` login, premenné a frontu, potom spustí `arq`. Ak niečo chýba, vypíše presný dôvod a skončí.
10. V logu hľadaj riadok `worker on_startup: collaborators initialised gateway=session queue_name=quiz-pack:session max_jobs=1 job_timeout=14400`.
11. Odpoj sa z tmuxu cez `Ctrl-b d`. Worker beží ďalej, tunely tiež.

## C. Over objednávkou

12. V TestFlight appke kúp custom pack (sandbox).
13. Sleduj log v tmuxe alebo admin UI so stavom objednávky: `pending` prejde na `in_progress` a nakoniec `delivered`.
14. Ak je mba offline alebo tunel spadne, job počká v Redise a sweep ho znova zaradí. Každé takéto zaradenie míňa jeden pokus z rozpočtu objednávky, po vyčerpaní stav skončí ako `failed` s `refund_eligible`.

## D. Rollback

15. `fly secrets unset ORDER_QUEUE_NAME -a quiz-pack-api`
16. `fly scale count worker=1 -a quiz-pack-api`
17. Na mba zastav worker (`tmux attach -t packworker`, `Ctrl-c`) a obidva tunely.

Objednávky, ktoré v tej chvíli ležia na fronte `quiz-pack:session`, si buď nechaj dobehnúť na mba pred krokom 17, alebo ich po prepnutí pošli znova cez `POST /v1/orders/{id}/retry`.
