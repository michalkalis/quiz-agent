# quiz-pack-redis — self-hosted Redis on Fly

Replaces Upstash Redis (free tier hit its 500k requests/month quota on
2026-07-17 — ARQ queue polling from prod + staging exhausted it; workers
crash-looped and pack generation was down).

- **App:** `quiz-pack-redis`, region `cdg`, one always-on 256 MB machine,
  1 GB volume (`/data`, AOF persistence). Cost ~$2/mo, no request metering.
- **Access:** private network only — `quiz-pack-redis.internal:6379`,
  password in Fly secret `REDIS_PASSWORD` (same value mirrored into the
  consumers' `REDIS_URL`). No public IP.
- **Consumers:** `quiz-pack-api` (prod, logical DB `/0`) and
  `quiz-pack-api-staging` (DB `/1`). Set via
  `fly secrets set REDIS_URL=redis://:<password>@quiz-pack-redis.internal:6379/<db> -a <app>`.
- **Durability:** queue contents are transient (orders live in Postgres;
  the stuck-order sweep re-drives anything lost), so AOF + single machine
  is deliberately good enough. Portable 1:1 to Hetzner later.

## Redeploy / config change

```bash
fly deploy -c infra/quiz-pack-redis/fly.toml
```

Consumers reconnect automatically (ARQ retries; SSE bridge reopens).

## Rotate password

```bash
fly secrets set REDIS_PASSWORD=<new> -a quiz-pack-redis
fly secrets set REDIS_URL=redis://:<new>@quiz-pack-redis.internal:6379/0 -a quiz-pack-api
fly secrets set REDIS_URL=redis://:<new>@quiz-pack-redis.internal:6379/1 -a quiz-pack-api-staging
```

Issue trail: Upstash outage noted in `docs/todo/TODO.md` 2026-07-17; decision
(founder): self-host on Fly, Hetzner-portable, instead of Upstash PAYG.
