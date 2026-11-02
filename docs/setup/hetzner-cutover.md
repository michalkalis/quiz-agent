# Cutover: Fly.io → Hetzner (#222 — moving the backend to Hetzner)

Moves production from Fly to `trubbo-prod-1` (2.31.163.95, see [`infra/hetzner/README.md`](../../infra/hetzner/README.md)).
- Downtime: about 5 minutes (DB ~60 MB dump + restore), behind maintenance mode.
- Run it from the agent Mac, in a quiet hour.
- `KEY` = prod admin key (root `.env` `ADMIN_API_KEY`).
- Always `env -u FLY_API_TOKEN fly …` (founder login).

## 0. Preconditions (all green before starting)

- [ ] `api.trubbo.app` and `pack.trubbo.app` resolve to 2.31.163.95 and pass `infra/deploy/smoke.sh` (rehearsal stack).
- [ ] GitHub, set by the founder (agent auto mode cannot write secrets):
  - `quiz-agent-db-backups`: secret `HETZNER_BACKUP_SSH_KEY` and variable `HETZNER_KNOWN_HOSTS`.
  - monorepo: secret `HETZNER_DEPLOY_SSH_KEY` and variable `HETZNER_KNOWN_HOSTS`.
- [ ] Fly secret `FORWARDER_SECRET` staged on `quiz-agent-api` and `quiz-pack-api` (`--stage`, no restart). The value comes from the server's `env/forwarder.env`.
- [ ] Note the current Fly image of both apps (`fly releases -a <app> --image`). They are the rollback images.

## 1. Freeze Fly

1. Turn on maintenance mode with a notice for old builds, and turn orders off:
   PUT `https://quiz-agent-api.fly.dev/api/v1/admin/app-switches` with `{"set": {"maintenance_enabled": true, "orders_enabled": false, "maintenance_sk": "Sťahujeme sa na nový server, o pár minút sme späť.", "notice_sk": "Krátka údržba, o pár minút sme späť."}}` (plus `_cs` / `_en`).
2. Wait 90 s so the switch cache (60 s) reaches the clients.
3. Stop the Fly app machines so nothing writes during the dump: `fly machine stop` for every machine of `quiz-agent-api` and `quiz-pack-api` (web + worker). Leave `quiz-pack-db` running.

## 2. Move the data

1. On the server, stop the apps: `docker compose stop quiz-agent pack-web pack-worker`.
2. Recreate the database: `dropdb -U postgres quiz_pack && createdb -U postgres quiz_pack`, both inside the postgres container.
3. Copy the data: Fly `pg_dump -p 5433 -U postgres -d quiz_pack --format=custom` → `ssh trubbo-prod` → `pg_restore --no-owner --no-acl`. This is the same pipe as the rehearsal.
4. Compare `count(*)` of `questions`, `generation_orders`, `users` and the alembic heads on both sides. Any mismatch = stop and go to **Back**.

## 3. Start on Hetzner

1. `infra/hetzner/pull-env.sh prod` (production env, watchers and mails on).
2. `docker compose up -d` and `docker compose --profile worker up -d pack-worker`.
3. Turn maintenance off on the new server: PUT `https://api.trubbo.app/api/v1/admin/app-switches` with `{"set": {"maintenance_enabled": false, "orders_enabled": true}, "reset": ["maintenance_sk", "maintenance_cs", "maintenance_en", "notice_sk", "notice_cs", "notice_en"]}`.
4. `infra/deploy/smoke.sh` against `https://api.trubbo.app` and `https://pack.trubbo.app`.

## 4. Fly becomes the forwarder

1. Deploy the forwarder onto each app: `fly deploy -c infra/fly-forwarder/fly.<app>.toml -a <app> --yes`, from `infra/fly-forwarder/`.
2. Stop any leftover machine of the old app (pack `worker` group) with `fly machine stop`. Do not destroy it until step 6.
3. `infra/deploy/smoke.sh` against `https://quiz-agent-api.fly.dev` and `https://quiz-pack-api.fly.dev`. These are the old builds' path through the forwarder.
4. Set the CI variables: monorepo `BACKEND_HOST=hetzner`, backups repo `DB_SOURCE=hetzner`. Then run the backup workflow once by hand and check that a release appears.

## 5. Go / no-go (first ~2 h)

- Watch Sentry (new errors), `docker stats`, a real order on TestFlight, and Apple/RevenueCat webhooks (they still call fly.dev, which the forwarder passes on).
- No-go → **Back**. After this window, fix forward only.

## Back (rollback, inside the window)

1. Turn maintenance on through `api.trubbo.app`, wait 90 s, then `docker compose stop quiz-agent pack-web pack-worker`.
2. Copy the data the other way: Hetzner `pg_dump` → Fly `quiz-pack-db`. Recreate `quiz_pack` there first (port 5433 on the DB machine). This full copy carries every write made on Hetzner (orders, purchases, credit), so nothing is lost.
3. Redeploy the old apps from the noted images: `fly deploy -c apps/<app>/fly.toml --image <noted image> --yes`.
4. Turn maintenance off through fly.dev, unset `BACKEND_HOST` / `DB_SOURCE`, and run the smoke tests against fly.dev.
5. Run `reconcile` for App Store purchases.

## 6. After 7 quiet days

- Delete the Fly DB, the Fly Redis and the staging apps.
- Repoint ASC App Store Server Notifications and the RevenueCat webhook to `pack.trubbo.app` / `api.trubbo.app`.
- Ship the build with our own domain. Once `min_version` retires the builds that call fly.dev, delete the forwarder apps.
