# #172 — Session worker: custom packy v bete cez Claude Code subscription (mba ako worker na prod fronte)

**Triage:** feature · ready-for-agent (founder GO 2026-09-06)
**Status:** Plán + implementácia 2026-09-06. Zapnutie v prode + spustenie na `mba` = founder krok (mba nedostupný cez Tailscale, Remote Control).
**Created:** 2026-09-06
**Reversibility:** `a` — prepínač v env; rollback = odstrániť `ORDER_QUEUE_NAME` + vrátiť Fly worker na 1.

## Cieľ

Objednávky custom packov z appky (TestFlight beta) sa nespracúvajú na Fly workeri (platené API), ale na `mba`, kde beží ten istý ARQ worker s `LLM_GATEWAY=session` (#169 — Claude Code subscription cez `claude -p`). Prod backend zostáva zdrojom pravdy: prijatie objednávky, StoreKit, stavy, SSE progres, retry, refund logika, uloženie packu — všetko 1:1. Mení sa len stroj, ktorý pipeline počíta.

**Founder rozhodnutia (2026-09-06):**
- Riziko podmienok používania prijaté: beta = vlastné použitie (testeri zadávajú prompty, founder všetko overuje); do App Store sa session režim nepoužije.
- Verifikácia faktov ide tiež cez subscription (rovnako ako korpus; v session mape `gpt-5-mini → session:sonnet`). Žiadna API výnimka.
- Čas doručenia packu v bete nie je podstatný (mba môže byť offline; pack príde neskôr).
- Sudcovia v session režime VŽDY OFF (#169) — worker to vynucuje.
- Kvalita sa nesmie zmeniť: pred zapnutím pre testerov slepé porovnanie session vs. API packov (founder test).

## Ako to funguje (mechanizmus)

GitHub review akcia aj #169 používajú to isté: Claude Code CLI v headless režime prihlásené na subscription (akcia cez OAuth token z `claude setup-token`, mba cez lokálny login). Tento issue nepridáva nový transport — len smeruje prod objednávky do fronty, ktorú obsluhuje mba.

```
iOS → POST /v1/orders (Fly web) ──enqueue──▶ Redis queue ORDER_QUEUE_NAME
                                                   │
                     Fly worker: WORKER_QUEUE_NAME = default (idle / scale 0)
                     mba worker: WORKER_QUEUE_NAME = session queue, LLM_GATEWAY=session
                                                   │
                                     Postgres (fly proxy) ← stavy, progres, pack
```

## Zmeny (apps/quiz-pack-api)

1. **Config** (`app/config.py`): `order_queue_name` (kam API a sweep zaraďujú; default ARQ `arq:queue`), `worker_queue_name` (čo worker konzumuje; default `arq:queue`), `worker_max_jobs` (default 2), `worker_job_timeout_s` (default 3600). Všetko env.
2. **Enqueue** (`app/api/v1/orders.py` 2 miesta, `app/worker/sweep.py` recovery): `_queue_name=settings.order_queue_name`. Deterministické `attempt_job_id` zostáva.
3. **Worker** (`app/worker/worker.py`): `queue_name`, `max_jobs`, `job_timeout` zo settings. V `on_startup`, ak `llm_factory.gateway() == "session"`: `ensure_subscription_login()` (fail loud, žiadny API kľúč), odmietnuť boot ak sú zapnutí sudcovia (`JUDGE_GATE`/`JUDGE_MODELS`) — rovnaké pravidlo ako `scripts/generate_pack.py --session`; zalogovať banner (gateway, queue, max_jobs, timeout).
4. **Cost accounting** (`app/worker/tasks.py`): v session režime OpenRouter snapshot nedáva zmysel — `llm_cost_usd` ostáva `None`/0 a log to povie explicitne (žiadna falošná nula bez poznámky).
5. **Spúšťač pre mba**: `scripts/run_session_worker.sh` — kontroly (claude login, `fly proxy` tunely na `quiz-pack-db` 15432 a `quiz-pack-redis` 16379, env), potom `arq app.worker.WorkerSettings`. Env: `LLM_GATEWAY=session`, `DATABASE_URL`/`REDIS_URL` cez proxy, `ORDER_QUEUE_NAME=WORKER_QUEUE_NAME=quiz-pack:session`, `WORKER_MAX_JOBS=1`, `WORKER_JOB_TIMEOUT_S=14400`, `OPENAI_API_KEY` (embeddings/obrázky ostávajú na OpenAI — #169 carve-out), bez `JUDGE_*`.
6. **Setup guide** `docs/setup/session-worker-mba.md`: číslované kroky pre foundera (Remote Control): prod prepnutie (`fly secrets set ORDER_QUEUE_NAME=quiz-pack:session -a quiz-pack-api`, `fly scale count worker=0 -a quiz-pack-api`), spustenie na mba v tmux, overenie (objednávka z TF → stav `in_progress` → `delivered`), rollback.
7. **Testy**: enqueue posiela `_queue_name` zo settings (orders + sweep); WorkerSettings číta env; `on_startup` v session režime volá login check a odmieta sudcov. Existujúca sada zelená.

## Nemení sa

- Pipeline stages, prompty, flagy — zdieľané s prodom a s `generate_pack.py --session` (PR #71 parita).
- iOS: žiadna zmena (SSE progres z DB funguje odkiaľkoľvek). Copy „pack príde neskôr“ = produktová otázka pre foundera, mimo tohto issue.
- Fly worker sa nemaže — je záloha; s `ORDER_QUEUE_NAME` nastaveným ju nič nezaťažuje.

## Prevádzkové vlastnosti / riziká

- **mba offline:** job čaká v Redis (AOF, expirácia ARQ 1 deň). Po expirácii ho sweep na štarte mba workera znovu zaradí (`pending` > 3 min) — každé takéto zaradenie je 1 pokus z rozpočtu objednávky (#145); po vyčerpaní → `failed` + `refund_eligible`. Pre betu OK, founder vidí v admin UI.
- **Kvóta subscription** je zdieľaná (interaktívna práca, nočné korpusové behy, GH review). `WORKER_MAX_JOBS=1` + session semafor 4. Denný strop packov = prevádzkové pravidlo, nie kód.
- **Migrácie:** mba worker robí boot-check na hlavu Alembic proti prod DB — mba musí bežať kód z `main` zhodný s nasadeným prodom.
- **Proxy tunel spadne** → job zlyhá na DB/Redis chybe → ARQ retry / sweep. Bez tichého zlyhania.

## Hotovo, keď

- [ ] PR merged; testy zelené.
- [ ] Prod: `ORDER_QUEUE_NAME` nastavený, Fly worker na 0 (founder GO pred prepnutím).
- [ ] mba: worker beží, testovacia objednávka z TF doručená cez session.
- [ ] Slepé porovnanie session vs. API packov (founder).
