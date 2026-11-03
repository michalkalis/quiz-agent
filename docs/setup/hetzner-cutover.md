# Cutover: Fly.io → Hetzner (#222 — moving the backend to Hetzner)

Moves production from Fly to `trubbo-prod-1` (2.31.163.95, see [`infra/hetzner/README.md`](../../infra/hetzner/README.md)).
- Downtime: about 10 minutes (forwarder deploy + ~60 MB copy + start), behind maintenance mode.
- Run it from the agent Mac. `KEY` = prod admin key (root `.env` `ADMIN_API_KEY`). Always `env -u FLY_API_TOKEN fly …` (founder login).
- Server commands run in `~/trubbo/repo/infra/hetzner` (`ssh trubbo-prod`).
- **Data safety rule:** nothing may write to the old database once the copy starts. The freeze is the forwarder deploy (it replaces every old app machine, worker included). A `fly machine stop` alone is not a freeze: the Fly proxy restarts stopped machines on the next request. `db-copy.sh` refuses to copy while any old app machine could run.

## 0. Preconditions (all green before starting)

- [ ] `api.trubbo.app` and `pack.trubbo.app` resolve to 2.31.163.95 and pass `infra/deploy/smoke.sh`.
- [ ] GitHub, set by the founder: backups repo `HETZNER_BACKUP_SSH_KEY` + `HETZNER_KNOWN_HOSTS`, monorepo `HETZNER_DEPLOY_SSH_KEY` + `HETZNER_KNOWN_HOSTS`.
- [ ] Server on current `main`: `git pull`, then `install -m 755 deploy-ssh.sh backup-ssh.sh ~/trubbo/bin/`.
- [ ] PITR on (rehearsal data is fine): `infra/hetzner/pull-env.sh rehearsal` writes `env/wal.env`; then `docker compose build postgres && docker compose up -d postgres`. `select archived_count, failed_count from pg_stat_archiver` must show archived > 0, failed 0 after ~5 min.
- [ ] Forwarder rehearsal green: `infra/fly-forwarder/rehearse.sh` (throwaway Fly app, cents; passed 2026-11-03).
- [ ] Fly secret `FORWARDER_SECRET` staged on both apps, value straight from the server: `ssh trubbo-prod 'cat trubbo/repo/infra/hetzner/env/forwarder.env' | env -u FLY_API_TOKEN fly secrets import -a <app> --stage`.
- [ ] Note the rollback images: `fly releases -a <app> --image` for `quiz-agent-api` and `quiz-pack-api`.
- [ ] `CUT_SHA` = the newer of the tags `deployed/quiz-agent` and `deployed/quiz-pack-api` (the code Fly runs). Hetzner starts on exactly that code, so no migration runs and the way back stays open.
- [ ] No Backend Deploy run from step 1 until the go decision (step 6).
- [ ] Time: a quiet hour, outside 02:00–05:00 UTC (nightly backup 02:17, server auto-reboot 04:30) and not Wednesday 03:00 UTC (fresh top-up).

## 1. Prepare (players unaffected)

1. Wake the pack web machine (`curl -fsS https://quiz-pack-api.fly.dev/health`), then `infra/hetzner/pull-env.sh prod`. It reads the secrets from the running Fly machines, so it must run before the freeze; a failed read writes nothing.
2. Server: `docker compose stop quiz-agent pack-web` (rehearsal apps off; the worker is not running).
3. mba: `apps/quiz-pack-api/scripts/session_worker_local.sh uninstall-launchd` (the backup worker writes to the Fly DB).

## 2. Freeze Fly (outage starts)

1. Maintenance on, orders off: PUT `https://quiz-agent-api.fly.dev/api/v1/admin/app-switches` with `{"set": {"maintenance_enabled": true, "orders_enabled": false, "maintenance_sk": "Sťahujeme sa na nový server, o pár minút sme späť.", "notice_sk": "Krátka údržba, o pár minút sme späť."}}` (plus `_cs` / `_en`). Note the time (`FREEZE_AT`, UTC).
2. Wait 90 s (the clients' switch cache is 60 s).
3. Deploy the forwarder onto both apps, from `infra/fly-forwarder/`: `fly deploy -c fly.<app>.toml -a <app> --yes`. For `quiz-pack-api` flyctl lists that it destroys the `web` and `worker` machines: that is the point. From here on `*.fly.dev` reaches the stopped Hetzner apps, so Apple and RevenueCat get errors and retry later: nothing is acknowledged that the new database would miss.

## 3. Move the data

`infra/hetzner/db-copy.sh fly-to-hetzner --yes`. It checks that no old app machine can run, replaces `quiz_pack` on Hetzner in one transaction (stops at the first error), then compares the exact row count of every table and both alembic heads. Any mismatch = it exits 1: go to **Back**.

## 4. Start on Hetzner

1. Server: `SSH_ORIGINAL_COMMAND="deploy <CUT_SHA> quiz-agent,pack" ~/trubbo/bin/deploy-ssh.sh` (builds that code, migrations are a no-op, waits for health).
2. Server: `docker compose --profile worker up -d pack-worker`.
3. Maintenance off: PUT `https://api.trubbo.app/api/v1/admin/app-switches` with `{"set": {"maintenance_enabled": false, "orders_enabled": true}, "reset": ["maintenance_sk", "maintenance_cs", "maintenance_en", "notice_sk", "notice_cs", "notice_en"]}`.
4. `infra/deploy/smoke.sh` against `https://api.trubbo.app`, `https://pack.trubbo.app`, `https://quiz-agent-api.fly.dev` and `https://quiz-pack-api.fly.dev`.

## 5. Right after

1. Purchases: `docker compose exec pack-web python -m app.storekit.reconcile --since <FREEZE_AT>` (dry run). It lists App Store purchases without an order; expected: none. Anything listed goes to the founder before `--apply`. Subscriptions need nothing: RevenueCat is the source of truth and the app syncs it on its own.
2. First PITR base backup of the real data: `SSH_ORIGINAL_COMMAND=basebackup ~/trubbo/bin/backup-ssh.sh`.
3. mba: `infra/hetzner/local-prod-env.sh hetzner`, then `session_worker_local.sh install-launchd` (worker and prod tools now tunnel to Hetzner).

## 6. Go / no-go (first ~2 h)

- Watch Sentry (new errors), `docker stats`, a real order on TestFlight, and webhooks arriving in the `pack-web` / `quiz-agent` logs (Apple and RevenueCat still call fly.dev; the forwarder passes them on).
- No-go → **Back**.
- Go → set the CI variables: monorepo `BACKEND_HOST=hetzner` (deploys and the weekly top-up now go to Hetzner); backups repo `DB_SOURCE=hetzner` and `PITR_SERVER_NAME=trubbo-prod`. Run the backup workflow and the PITR restore verify once by hand; both must be green. After this point, fix forward only.

## Back (rollback, inside the window)

1. Maintenance on through `https://api.trubbo.app` (fly.dev reaches it too), wait 90 s, then on the server `docker compose --profile worker stop quiz-agent pack-web pack-worker`.
2. `infra/hetzner/db-copy.sh hetzner-to-fly --yes`: the same guarantees the other way. Every write made on Hetzner (orders, purchases, credit) goes back, nothing is lost.
3. Redeploy the old apps from the noted images: `fly deploy -c apps/<app>/fly.toml --image <noted image> --yes` (from the repo root). This replaces the forwarder. Their migration step is a no-op because Hetzner ran `CUT_SHA`.
4. Maintenance off through fly.dev, smoke tests against fly.dev.
5. mba: `infra/hetzner/local-prod-env.sh fly`, then `session_worker_local.sh install-launchd`.
6. Purchases: `fly ssh console -a quiz-pack-api -C "python -m app.storekit.reconcile --since <FREEZE_AT>"` (dry run, as in 5.1).
7. The CI variables stay unset (they are only set at go).

## 7. After 7 quiet days

- Delete the Fly DB, the Fly Redis and the staging apps. Delete the old `quiz-pack-db/` prefix in the R2 bucket `quiz-pack-db-wal` (the Hetzner archive is `trubbo-prod/`).
- Repoint ASC App Store Server Notifications and the RevenueCat webhook to `pack.trubbo.app` / `api.trubbo.app`.
- Ship the build with our own domain. Once `min_version` retires the builds that call fly.dev, delete the forwarder apps.
