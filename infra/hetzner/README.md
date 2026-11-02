# Hetzner server (#222 — moving the backend to Hetzner)

One VPS runs the whole backend with Docker Compose: Caddy (TLS + proxy), quiz-agent, quiz-pack-api web + worker, Postgres 17 + pgvector, Redis.
Plan: [`docs/issues/issue-222-hetzner-migration.md`](../../docs/issues/issue-222-hetzner-migration.md).

| | |
|---|---|
| Server | `trubbo-prod-1`, Hetzner CAX11 (Arm, 2 vCPU, 4 GB + 2 GB swap), Falkenstein `fsn1`, Ubuntu 24.04 |
| Access | `ssh trubbo-prod` (user `trubbo`, key `~/.ssh/trubbo_hetzner`; password and root login off) |
| Firewall | Hetzner firewall `trubbo-web`: 22, 80, 443, ICMP. Postgres/Redis bind to 127.0.0.1 only (use an SSH tunnel) |
| OS updates | unattended-upgrades, auto reboot 04:30 UTC when needed; fail2ban on SSH |
| Hetzner API | `HCLOUD_TOKEN` in root `.env` (founder-created) → `hcloud server list` |

## Layout on the server

- `~/trubbo/repo`: git checkout; the stack runs from `infra/hetzner/`.
- `infra/hetzner/env/*.env` (mode 600, server only, never in git):
  - `postgres.env`, `redis.env`, `forwarder.env`: generated once on the server.
  - `quiz-agent.env`, `quiz-pack-api.env`: copied from the Fly apps by `pull-env.sh`.
  - `caddy.env`: `AGENT_HOSTS`, `PACK_HOSTS`, `FORWARDER_SECRET`.
- Caddy refuses to start when `FORWARDER_SECRET` is empty (fails closed).

## Common tasks

| Task | Command (on the server, in `~/trubbo/repo/infra/hetzner`) |
|---|---|
| Status / memory | `docker compose ps` · `docker stats --no-stream` |
| Logs | `docker compose logs -f --since 10m quiz-agent` |
| Update code | `git pull && docker compose build quiz-agent pack-web && docker compose up -d` |
| Migrations | `docker compose run --rm quiz-agent alembic upgrade head` (and `pack-web`) |
| Start the order worker | `docker compose --profile worker up -d pack-worker` (prod only: a copied DB would re-run real orders on paid keys) |
| psql | `docker compose exec postgres psql -U postgres -d quiz_pack` |
| Reload Caddy | `docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile` |
| Refresh secrets (from a laptop) | `infra/hetzner/pull-env.sh rehearsal\|prod` |

## Client IP

The apps rate-limit per `Fly-Client-IP`. Caddy overwrites that header with the real peer address. It keeps an incoming value only when the request carries `X-Trubbo-Forwarder: $FORWARDER_SECRET`, which the Fly forwarder sends for old builds that still call `*.fly.dev`.
Verified 2026-11-02: a spoofed header and a wrong secret are both overwritten; the right secret passes the forwarded IP.

## Deploy

`backend-deploy.yml` deploys to this server over SSH when the repo variable `BACKEND_HOST` is `hetzner` (unset = the Fly flow). After the tests it runs `ssh hetzner deploy <sha> <quiz-agent,pack>`; the deploy key is locked to [`deploy-ssh.sh`](deploy-ssh.sh) (forced command, `restrict`). The script takes a lock, refuses a sha that is not on `origin/main`, builds the touched images, runs `alembic upgrade head` before the swap, restarts the services (the worker only if it already runs), waits up to 120 s for health, and on failure rebuilds the previous sha and exits non-zero. `ssh hetzner status` prints the live sha and `docker compose ps`. CI then smoke-tests `api.trubbo.app` and `pack.trubbo.app`.

Founder-set items (agents never create these):

1. Generate a deploy key pair; put the public key on the server in `~trubbo/.ssh/authorized_keys` as one line: `command="/home/trubbo/trubbo/repo/infra/hetzner/deploy-ssh.sh",restrict ssh-ed25519 AAAA... trubbo-ci-deploy`.
2. GitHub secret `HETZNER_DEPLOY_SSH_KEY` = the private key.
3. GitHub variable `HETZNER_KNOWN_HOSTS` = output of `ssh-keyscan -t ed25519 2.31.163.95`.
4. At cutover, GitHub variable `BACKEND_HOST` = `hetzner`. From then on CI no longer deploys app code to Fly.

## Rehearsal state (2026-11-02)

- Prod DB copy restored (3 507 questions, alembic heads match prod).
- Worker not started; mails and background checks off (`ENVIRONMENT=staging`).
- Test URLs (not used by the app): `agent.2-31-163-95.sslip.io`, `pack.2-31-163-95.sslip.io`. Both pass `infra/deploy/smoke.sh`.
