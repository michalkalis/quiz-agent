# quiz-pack-db custom image (pgvector)

The Fly Postgres app `quiz-pack-db` (region `cdg`, 1 GB RAM) runs this custom
image instead of `flyio/postgres-flex:17.2` because the default image lacks
the `pgvector` apt package and runtime `apt install` does not persist across
machine restarts (immutable container, overlay fs is wiped). Custom image is
the only stable path on unmanaged Fly Postgres; alternatives we considered
and rejected: `fly mpg` (Basic = ~$38/mo) and Supabase (platform change).

Current published tag: `registry.fly.io/quiz-pack-db:pgvector-0.8.2`
(pgvector v0.8.2 from Debian Bookworm `postgresql-17-pgvector`).

Issue trail: `docs/issues/issue-33-quiz-pack-api-phase-1.md` Task 1.1.

## Rebuilding the image

When `pgvector` upstream ships a relevant version, rebuild and roll forward:

```bash
# 1. Authenticate Docker with the Fly registry
fly auth docker

# 2. Build for linux/amd64 (Fly machines are amd64) and push
docker buildx build \
  --platform linux/amd64 \
  -t registry.fly.io/quiz-pack-db:pgvector-<NEW_TAG> \
  --push \
  infra/quiz-pack-db/

# 3. Find the postgres machine ID
fly machines list -a quiz-pack-db

# 4. Roll the machine to the new image (Fly keeps the volume attached)
fly machine update <MACHINE_ID> \
  --image registry.fly.io/quiz-pack-db:pgvector-<NEW_TAG> \
  -a quiz-pack-db

# 5. Verify the extension version inside the prod DB
fly ssh console -a quiz-pack-db -C \
  'psql -U postgres -d quiz_pack -c "SELECT extversion FROM pg_extension WHERE extname='\''vector'\'';"'
```

Choose `<NEW_TAG>` as the pgvector version pinned by the Debian package
(e.g. `pgvector-0.8.2`). Don't use `:latest` — Fly machines pin by digest, but
the tag is what humans read in `fly logs` and `fly status`.

## Why a single-line apt install

`postgresql-17-pgvector` ships a precompiled extension matching the
`flyio/postgres-flex:17.2` base. Building pgvector from source would also work
but adds ~2 minutes to every rebuild and pulls in `build-essential` +
`postgresql-server-dev-17`, which we'd then have to clean up to keep the image
slim. The apt route is simpler and the version cadence is fine for our needs.
