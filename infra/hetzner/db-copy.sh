#!/usr/bin/env bash
# Copy the production database between Fly and Hetzner for the cutover and its
# rollback (#222 — moving the backend to Hetzner). Run from the agent Mac.
#
#   infra/hetzner/db-copy.sh fly-to-hetzner --yes   cutover: Fly quiz-pack-db -> Hetzner
#   infra/hetzner/db-copy.sh hetzner-to-fly --yes   rollback: Hetzner -> Fly quiz-pack-db
#   infra/hetzner/db-copy.sh compare                exact row counts of every table, both sides
#
# Guarantees, each checked before anything is dropped:
# - nothing can write to the source: on Fly, no machine of quiz-agent-api or
#   quiz-pack-api runs the app image any more (only the forwarder, or nothing);
#   on Hetzner, quiz-agent / pack-web / pack-worker / pack-topup are stopped;
# - the target is replaced in one transaction: pg_restore stops at the first
#   error and nothing is half-restored (--single-transaction --exit-on-error);
# - afterwards the exact row count of EVERY table and both alembic heads must be
#   identical on both sides (orders, purchases, credit included), else exit 1.
# Needs: founder `fly auth login` (runs with FLY_API_TOKEN unset), ssh alias trubbo-prod.
set -euo pipefail
DIR_ARG="${1:-}"
HOST="trubbo-prod"
COMPOSE="cd ~/trubbo/repo/infra/hetzner && docker compose"
FLY=(env -u FLY_API_TOKEN fly)
FLY_DB=(--app quiz-pack-db --pty=false)

die() { echo "[db-copy] ERROR: $*" >&2; exit 1; }
log() { echo "[db-copy] $*"; }

# Exact count per table + alembic heads, one "name|value" line each, sorted.
COUNT_SQL="$(cat <<'SQL'
SELECT t.schemaname || '.' || t.relname || '|' ||
       (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', t.schemaname, t.relname), false, true, '')))[1]::text
FROM pg_stat_user_tables t
UNION ALL SELECT 'alembic_version|' || version_num FROM alembic_version
UNION ALL SELECT 'alembic_version_quiz_agent|' || version_num FROM alembic_version_quiz_agent
ORDER BY 1;
SQL
)"
COUNT_B64="$(printf '%s' "$COUNT_SQL" | base64 | tr -d '\n')"

fly_psql_counts() {
  "${FLY[@]}" ssh console "${FLY_DB[@]}" \
    -C "bash -c 'echo $COUNT_B64 | base64 -d | psql -p 5433 -U postgres -d quiz_pack -At -v ON_ERROR_STOP=1'" 2>/dev/null | tr -d '\r'
}
hetzner_psql_counts() {
  printf '%s' "$COUNT_SQL" | ssh "$HOST" "$COMPOSE exec -T postgres psql -U postgres -d quiz_pack -At -v ON_ERROR_STOP=1"
}

compare() {
  local a b
  a="$(fly_psql_counts)" || die "count query failed on Fly"
  b="$(hetzner_psql_counts)" || die "count query failed on Hetzner"
  [ -n "$a" ] && [ -n "$b" ] || die "empty count result"
  if [ "$a" = "$b" ]; then
    log "identical: $(printf '%s\n' "$a" | wc -l | tr -d ' ') tables + alembic heads"
    printf '%s\n' "$a" | grep -E '^(public\.(generation_orders|users|questions)|alembic)' | sed 's/^/[db-copy]   /'
    return 0
  fi
  echo "[db-copy] MISMATCH (< Fly, > Hetzner):" >&2
  diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") >&2 || true
  return 1
}

# No old app machine may run on Fly, nor sit stopped where the Fly proxy would
# wake it on the next request (autostart). The forwarder (internal port 8080)
# and a stopped worker (no services) are fine.
fly_writers_stopped() {
  local app bad
  for app in quiz-agent-api quiz-pack-api; do
    bad="$("${FLY[@]}" machine list -a "$app" --json |
      jq -r '.[] | select(.state != "destroyed")
             | (.config.services // []) as $svc
             | select(($svc | map(.internal_port) | index(8080)) == null)
             | select((.state | test("^(started|starting|replacing|updating)$"))
                      or ($svc | map(.autostart // true) | any))
             | "\(.id) \(.config.metadata.fly_process_group // "app") \(.state)"')"
    [ -z "$bad" ] || die "$app still runs app machines (stop them / deploy the forwarder first): $bad"
  done
  log "Fly: no app machine running (forwarder only)"
}

hetzner_writers_stopped() {
  local running
  running="$(ssh "$HOST" "$COMPOSE --profile worker --profile topup ps --status running --services" |
    grep -E '^(quiz-agent|pack-web|pack-worker|pack-topup)$' || true)"
  [ -z "$running" ] || die "Hetzner still runs: $(echo $running) (docker compose stop them first)"
  log "Hetzner: apps stopped"
}

case "$DIR_ARG" in
  compare) compare; exit $? ;;
  fly-to-hetzner|hetzner-to-fly) [ "${2:-}" = "--yes" ] || die "this replaces the target database; add --yes" ;;
  *) die "usage: db-copy.sh fly-to-hetzner|hetzner-to-fly --yes | compare" ;;
esac

fly_writers_stopped
hetzner_writers_stopped

if [ "$DIR_ARG" = fly-to-hetzner ]; then
  log "recreate quiz_pack on Hetzner"
  ssh "$HOST" "$COMPOSE exec -T postgres sh -c 'dropdb -U postgres --force --if-exists quiz_pack && createdb -U postgres quiz_pack'"
  log "copy Fly -> Hetzner (one transaction)"
  "${FLY[@]}" ssh console "${FLY_DB[@]}" -C "pg_dump -p 5433 -U postgres -d quiz_pack --format=custom" 2>/dev/null |
    ssh "$HOST" "$COMPOSE exec -T postgres pg_restore -U postgres -d quiz_pack --no-owner --no-acl --single-transaction --exit-on-error"
else
  log "recreate quiz_pack on Fly"
  "${FLY[@]}" ssh console "${FLY_DB[@]}" \
    -C "bash -c 'dropdb -p 5433 -U postgres --force --if-exists quiz_pack && createdb -p 5433 -U postgres quiz_pack'"
  log "copy Hetzner -> Fly (one transaction)"
  ssh "$HOST" "$COMPOSE exec -T postgres pg_dump -U postgres -d quiz_pack --format=custom" |
    "${FLY[@]}" ssh console "${FLY_DB[@]}" \
      -C "pg_restore -p 5433 -U postgres -d quiz_pack --no-owner --no-acl --single-transaction --exit-on-error"
fi

compare || die "row counts differ after the copy: do not start the apps"
log "OK: $DIR_ARG complete"
