# Postgres 17 + pgvector + barman-cloud for point-in-time recovery (#222 — moving
# the backend to Hetzner). Same tool and R2 bucket as the Fly DB (postgres-flex's
# built-in barman-cloud, docs/setup/db-backup.md), under its own server name.
FROM pgvector/pgvector:0.8.2-pg17
RUN apt-get update \
 && apt-get install -y --no-install-recommends barman-cli-cloud python3-boto3 \
 && rm -rf /var/lib/apt/lists/*
COPY wal-archive.sh /usr/local/bin/wal-archive
