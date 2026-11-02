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

## Rehearsal state (2026-11-02)

- Prod DB copy restored (3 507 questions, alembic heads match prod).
- Worker not started; mails and background checks off (`ENVIRONMENT=staging`).
- Test URLs (not used by the app): `agent.2-31-163-95.sslip.io`, `pack.2-31-163-95.sslip.io`. Both pass `infra/deploy/smoke.sh`.
