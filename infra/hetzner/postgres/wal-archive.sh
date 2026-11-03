#!/bin/sh
# archive_command (#222): ship one WAL segment to R2. Settings come from the
# container env (env/wal.env). A non-zero exit makes Postgres keep the segment
# and retry; app/monitoring/wal_watch.py alerts and, past 1.5 GB of pg_wal,
# switches archiving off with ALTER SYSTEM (which overrides trubbo.conf).
set -eu
exec barman-cloud-wal-archive --gzip --endpoint-url "$WAL_S3_ENDPOINT" \
  "$WAL_S3_ARCHIVE" "$WAL_SERVER_NAME" "$1"
