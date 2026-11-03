# Hetzner server (#222 — moving the backend to Hetzner)

One VPS runs the whole backend with Docker Compose: Caddy (TLS + proxy), quiz-agent, quiz-pack-api web + worker, Postgres 17 + pgvector, Redis.
Plan: [`docs/issues/issue-222-hetzner-migration.md`](../../docs/issues/issue-222-hetzner-migration.md).

| | |
|---|---|
| Server | `trubbo-prod-1`, Hetzner CAX11 (Arm, 2 vCPU, 4 GB + 2 GB swap), Falkenstein `fsn1`, Ubuntu 24.04 |
| Access | `ssh trubbo-prod` (user `trubbo`, key `~/.ssh/trubbo_hetzner`; password and root login off) |
| Firewall | Hetzner firewall `trubbo-web`: 22, 80, 443, ICMP. Postgres/Redis bind to 127.0.0.1 only (use an SSH tunnel) |
| OS updates | unattended-upgrades, auto reboot 04:30 UTC when needed; fail2ban on SSH |
| Hetzner API | `HCLOUD_TOKEN` in root `.env` (founder-created) → `hcloud server list`. Delete + rebuild protection on (2026-11-03) |
| Backups | nightly encrypted dump (backups repo `backup.yml`) + WAL to R2 every ≤ 5 min with a nightly base backup, 7-day point-in-time window ([`postgres/`](postgres/), [db-backup.md](../../docs/setup/db-backup.md)) |

## Layout on the server

- `~/trubbo/repo`: git checkout; the stack runs from `infra/hetzner/`.
- `infra/hetzner/env/*.env` (mode 600, server only, never in git):
  - `postgres.env`, `redis.env`, `forwarder.env`: generated once on the server.
  - `quiz-agent.env`, `quiz-pack-api.env`: copied from the Fly apps by `pull-env.sh`.
  - `wal.env`: R2 access for the WAL archive, from the Fly DB's `S3_ARCHIVE_CONFIG` by `pull-env.sh` (barman server name `trubbo-prod`).
  - `caddy.env`: `AGENT_HOSTS`, `PACK_HOSTS`, `FORWARDER_SECRET`.
- Caddy refuses to start when `FORWARDER_SECRET` is empty (fails closed).

## Common tasks

| Task | Command (on the server, in `~/trubbo/repo/infra/hetzner`) |
|---|---|
| Status / memory | `docker compose ps` · `docker stats --no-stream` |
| Logs | `docker compose logs -f --since 10m quiz-agent` |
| Update code | `git fetch origin main && git checkout --detach origin/main && docker compose build quiz-agent pack-web && docker compose up -d` (deploys leave the checkout detached) |
| Migrations | `docker compose run --rm quiz-agent alembic upgrade head` (and `pack-web`) |
| Start the order worker | `docker compose --profile worker up -d pack-worker` (prod only: a copied DB would re-run real orders on paid keys) |
| psql | `docker compose exec postgres psql -U postgres -d quiz_pack` |
| Reload Caddy | `docker compose up -d --force-recreate caddy` (a checkout replaces the Caddyfile and the running container keeps seeing the old one, so `caddy reload` is not enough) |
| Refresh secrets (from a laptop) | `infra/hetzner/pull-env.sh rehearsal\|prod` |
| WAL archive status | `docker compose exec postgres psql -U postgres -c 'select * from pg_stat_archiver'` |
| Base backup now | `SSH_ORIGINAL_COMMAND=basebackup ~/trubbo/bin/backup-ssh.sh` |
| Copy the DB Fly ↔ Hetzner (laptop) | `infra/hetzner/db-copy.sh compare\|fly-to-hetzner\|hetzner-to-fly` |
| Prod tunnel for mba tools (laptop) | `infra/hetzner/local-prod-env.sh hetzner\|fly` |

## Client IP

The apps rate-limit per `Fly-Client-IP`. Caddy overwrites that header with the real peer address. It keeps an incoming value only when the request carries `X-Trubbo-Forwarder: $FORWARDER_SECRET`, which the Fly forwarder sends for old builds that still call `*.fly.dev`.
Verified 2026-11-02: a spoofed header and a wrong secret are both overwritten; the right secret passes the forwarded IP.

## Deploy

`backend-deploy.yml` deploys to this server over SSH when the repo variable `BACKEND_HOST` is `hetzner` (unset = the Fly flow). After the tests it runs `ssh hetzner deploy <sha> <quiz-agent,pack>`; the deploy key is locked to [`deploy-ssh.sh`](deploy-ssh.sh) (forced command, `restrict`). The script takes a lock, refuses a sha that is not on `origin/main`, builds the touched images, runs `alembic upgrade head` before the swap, restarts the services (the worker only if it already runs), waits up to 120 s for health, and on failure rebuilds the previous sha without migrating (expand-only migrations; the older alembic would reject the newer revision) and exits non-zero. Containers stop with a 30 s grace period and Caddy holds requests (bodies up to 1 MB) for up to 30 s while one restarts, so a deploy is a pause, not a burst of errors. `ssh hetzner status` prints the live sha and `docker compose ps`. `ssh hetzner topup <langs> <count> <max_usd> <dry|write|cron>` runs the weekly fresh-question top-up (`fresh-topup.yml`) in a one-off 1 GB container, capped at $15. CI then smoke-tests `api.trubbo.app` and `pack.trubbo.app`.

Founder-set items (agents never create these):

1. Generate a deploy key pair; put the public key on the server in `~trubbo/.ssh/authorized_keys` as one line: `command="/home/trubbo/trubbo/bin/deploy-ssh.sh",restrict ssh-ed25519 AAAA... trubbo-ci-deploy`.
2. GitHub secret `HETZNER_DEPLOY_SSH_KEY` = the private key.
3. GitHub variable `HETZNER_KNOWN_HOSTS` = output of `ssh-keyscan -t ed25519 2.31.163.95`.
4. At cutover, GitHub variable `BACKEND_HOST` = `hetzner`. From then on CI no longer deploys app code to Fly.

## Rehearsal state (2026-11-02)

- Prod DB copy restored (3 507 questions, alembic heads match prod).
- Worker not started; mails and background checks off (`ENVIRONMENT=staging`).
- Test URLs (not used by the app): `agent.2-31-163-95.sslip.io`, `pack.2-31-163-95.sslip.io`. Both pass `infra/deploy/smoke.sh`.

**Forced-command scripts live outside the checkout** (`~/trubbo/bin/`), because a deploy checks out another commit and must not rewrite the script that is running it. After a change to `deploy-ssh.sh` or `backup-ssh.sh` lands, install it by hand: `install -m 755 infra/hetzner/{deploy,backup}-ssh.sh ~/trubbo/bin/`.
Verified 2026-11-02: a real deploy of `main` through the CI key took 28 s, and bad input was rejected.
