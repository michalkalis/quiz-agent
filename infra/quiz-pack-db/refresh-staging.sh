#!/usr/bin/env bash
# Refresh the staging logical DB `quiz_pack_staging` (same cluster as prod) with
# prod data. #193 task 193.10. Only `quiz_pack_staging` is dropped/recreated;
# prod `quiz_pack` is only ever read (pg_dump / size / alembic heads).
#
#   refresh-staging.sh backup [<release-tag>]   restore a nightly encrypted backup
#                                               (default: newest) = restore drill.
#                                               Needs BACKUP_KEY (default
#                                               ~/quiz-pack-db-backup-key/backup-private-key.pem)
#   refresh-staging.sh prod                     fresh pg_dump of prod, piped on the DB
#                                               machine straight into staging
#
# pg_restore runs ON the DB machine via `fly ssh` (no proxy, no password, no
# Docker); the decrypted dump only ever exists as a pipe.
#
# Staging isolation re-applied every run (idempotent):
#   - the staging login roles lose pg_read_all_data / pg_write_all_data, which
#     `fly postgres attach --superuser=false` grants cluster-wide (= read AND
#     write on prod `quiz_pack`); without them they have no rights on any prod table;
#   - everything in `quiz_pack_staging` is owned by NOLOGIN role `quiz_staging`
#     and both staging roles default to `SET ROLE quiz_staging` there, so
#     objects created by either app's migrations stay usable by the other.
set -euo pipefail

APP=quiz-pack-db
STG=quiz_pack_staging
LOGINS="quiz_agent_api_staging, quiz_pack_api_staging"
MAX_PCT=60
mode="${1:?usage: refresh-staging.sh backup [<tag>] | prod}"

remote() { fly ssh console -a "$APP" --pty=false -C "$1" 2>/dev/null; }
psql_in() { remote "psql -p 5433 -U postgres -d $1 -v ON_ERROR_STOP=1 -Atq"; }

# 1. Disk headroom: projected use (now + prod size - current staging) must stay <= 60 %.
read -r used size <<<"$(remote "df --output=used,size -B1 /data" | tail -1)"
read -r prod_b stg_b <<<"$(echo "select pg_database_size('quiz_pack'), coalesce((select pg_database_size('$STG') from pg_database where datname='$STG'), 0)" | psql_in postgres | tr '|' ' ')"
projected=$(( (used + prod_b - stg_b) * 100 / size ))
echo "volume now $(( used * 100 / size ))%, projected after refresh ${projected}%"
if (( projected > MAX_PCT )); then
  echo "projected use above ${MAX_PCT}% — extend the volume first (docs/setup/db-backup.md)" >&2
  exit 1
fi

# 2. Staging roles + empty staging DB.
psql_in postgres <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'quiz_staging') THEN CREATE ROLE quiz_staging NOLOGIN; END IF;
END \$\$;
REVOKE pg_read_all_data, pg_write_all_data FROM $LOGINS;
GRANT quiz_staging TO $LOGINS;
DROP DATABASE IF EXISTS $STG WITH (FORCE);
CREATE DATABASE $STG OWNER quiz_staging;
ALTER ROLE quiz_agent_api_staging IN DATABASE $STG SET role = 'quiz_staging';
ALTER ROLE quiz_pack_api_staging IN DATABASE $STG SET role = 'quiz_staging';
SQL

# 3. Restore.
restore="pg_restore -p 5433 -U postgres -d $STG --no-owner --no-privileges --exit-on-error"
case "$mode" in
  backup)
    key="${BACKUP_KEY:-$HOME/quiz-pack-db-backup-key/backup-private-key.pem}"
    [[ -r "$key" ]] || { echo "backup key not readable: $key" >&2; exit 1; }
    tag="${2:-$(gh release list -R michalkalis/quiz-agent-db-backups --limit 1 --json tagName -q '.[0].tagName')}"
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    gh release download "$tag" -R michalkalis/quiz-agent-db-backups -D "$tmp"
    echo "restoring $tag"
    openssl cms -decrypt -binary -inform DER -inkey "$key" -in "$tmp"/*.dump.cms | remote "$restore"
    ;;
  prod)
    echo "restoring a fresh dump of quiz_pack"
    remote "bash -c 'set -o pipefail; pg_dump -p 5433 -U postgres -d quiz_pack --format=custom | $restore'"
    ;;
  *) echo "unknown mode: $mode" >&2; exit 1 ;;
esac

# 4. Hand every restored object to quiz_staging (pg_restore ran as postgres).
psql_in "$STG" <<'SQL'
DO $$ DECLARE r record; BEGIN
  FOR r IN SELECT c.oid::regclass AS obj, c.relkind FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm')
        AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e')
  LOOP
    EXECUTE format('ALTER %s %s OWNER TO quiz_staging',
      CASE r.relkind WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW' ELSE 'TABLE' END, r.obj);
  END LOOP;
  -- Standalone sequences only; column-owned ones moved with their table above.
  FOR r IN SELECT c.oid::regclass AS obj FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relkind = 'S' AND c.relowner <> 'quiz_staging'::regrole
  LOOP EXECUTE format('ALTER SEQUENCE %s OWNER TO quiz_staging', r.obj); END LOOP;
  FOR r IN SELECT t.oid::regtype AS obj FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
      WHERE n.nspname = 'public' AND t.typtype = 'e'
  LOOP EXECUTE format('ALTER TYPE %s OWNER TO quiz_staging', r.obj); END LOOP;
  FOR r IN SELECT p.oid::regprocedure AS obj FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public'
        AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
  LOOP EXECUTE format('ALTER ROUTINE %s OWNER TO quiz_staging', r.obj); END LOOP;
END $$;
SQL

# 5. Report (prod is only read here).
echo "select 'staging questions', count(*) from questions;
  select 'staging heads', (select version_num from alembic_version), (select version_num from alembic_version_quiz_agent);
  select 'objects not owned by quiz_staging', count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r','S','v','m') and c.relowner <> 'quiz_staging'::regrole;" | psql_in "$STG"
echo "select 'prod questions', count(*) from questions;
  select 'prod heads', (select version_num from alembic_version), (select version_num from alembic_version_quiz_agent);" | psql_in quiz_pack
echo "done: $(remote "df --output=pcent /data" | tail -1 | tr -d ' ') of the volume used"
