#!/usr/bin/env bash
# Copy app secrets from the Fly prod machines straight to the Hetzner server
# (#222 — moving the backend to Hetzner). Values are piped Fly -> server and never
# printed or written locally.
#
# Usage: infra/hetzner/pull-env.sh <rehearsal|prod> [ssh-host]
#   rehearsal: background jobs and alert mails off, ENVIRONMENT=staging (copied prod
#              data must not send mails, check providers or run paid generation).
#   prod:      same settings as the Fly prod apps.
# Needs: founder `fly auth login` (runs with FLY_API_TOKEN unset), ssh alias, and
# running Fly machines (wake the pack web machine first: curl its /health).
set -euo pipefail
MODE="${1:?rehearsal|prod}"
HOST="${2:-trubbo-prod}"
DIR="trubbo/repo/infra/hetzner/env"
FLY=(env -u FLY_API_TOKEN fly)

# Names only, never values. Fly-internal vars (FLY_*, PRIMARY_REGION, ...) are dropped.
secret_names() { "${FLY[@]}" secrets list -a "$1" --json | jq -r '.[].name' | grep -v '^FLY_' ; }
toml_env() { sed -n '/^\[env\]/,/^\[/p' "$1" | grep -E '^[[:space:]]*[A-Z_]+[[:space:]]*=' | sed -E 's/^[[:space:]]*([A-Z_]+)[[:space:]]*=[[:space:]]*"?([^"]*)"?.*/\1=\2/'; }

# Server side: create DB/Redis/forwarder secrets once, then rewrite the
# connection URLs in an app env file to point at the Compose services.
ssh "$HOST" "mkdir -p $DIR && chmod 700 $DIR && cd $DIR && umask 077 &&
  { [ -s postgres.env ] || echo POSTGRES_PASSWORD=\$(openssl rand -hex 24) > postgres.env; } &&
  { [ -s redis.env ] || echo REDIS_PASSWORD=\$(openssl rand -hex 24) > redis.env; } &&
  { [ -s forwarder.env ] || echo FORWARDER_SECRET=\$(openssl rand -hex 32) > forwarder.env; }"

# Runs on the Fly machine: prints the named vars in Compose env_file syntax.
# Plain values are single-quoted (literal); multi-line values (the Apple .p8 PEM)
# are double-quoted with \n escapes, which Compose turns back into newlines.
DUMP_PY="$(base64 <<'PY' | tr -d '\n'
import os, sys
for k in sys.argv[1].split("|"):
    v = os.environ.get(k)
    if v is None:
        continue
    if "\n" in v:
        assert not any(c in v for c in '"$\\'), k
        print(k + '="' + v.replace("\n", "\\n") + '"')
    else:
        assert "'" not in v, k
        print(k + "='" + v + "'")
PY
)"

push_app() { # <fly app> <machine or ''> <toml> <env file> <redis db>
  local app="$1" machine="$2" toml="$3" out="$4" redis_db="$5" names dump
  names="$(secret_names "$app" | paste -sd'|' -)"
  # Read first (memory only), write after: a failed read (stopped machine,
  # network) must never replace a good env file on the server with a partial one.
  dump="$("${FLY[@]}" ssh console -a "$app" ${machine:+--machine "$machine"} \
      -C "python3 -c 'import base64;exec(base64.b64decode(\"$DUMP_PY\"))' '$names'" 2>/dev/null \
      | tr -d '\r' | grep -vE '^(DATABASE_URL|REDIS_URL)=')" \
    || { echo "reading the secrets of $app failed (machine stopped?): nothing written" >&2; exit 1; }
  {
    printf '%s\n' "$dump"
    toml_env "$toml"
    # Same on rehearsal and prod: watchers talk to the Compose services and read host metrics.
    printf '%s\n' OPS_METRICS_SOURCE=local PACK_API_HEALTH_URL=http://pack-web:8003/health \
      QUIZ_AGENT_URL=http://quiz-agent:8002
    if [ "$MODE" = rehearsal ]; then
      printf '%s\n' ENVIRONMENT=staging OPS_WATCH_ENABLED=false PROVIDER_BALANCE_CHECK_ENABLED=false \
        QUESTION_STOCK_CHECK_ENABLED=false ALERT_EMAIL_TO= GITHUB_TRIAGE_DISPATCH_TOKEN=
    fi
  } | ssh "$HOST" "cd $DIR && umask 077 && . ./postgres.env && . ./redis.env &&
      { tac | awk -F= '!seen[\$1]++' | tac;  # last value of a name wins (overrides below)
        echo DATABASE_URL=postgres://postgres:\$POSTGRES_PASSWORD@postgres:5432/quiz_pack;
        echo REDIS_URL=redis://:\$REDIS_PASSWORD@redis:6379/$redis_db; } > $out.tmp && mv $out.tmp $out &&
      echo \"$out: \$(wc -l < $out) vars\""
}

# PITR (WAL to R2): the Fly DB's own R2 write token (secret S3_ARCHIVE_CONFIG on
# quiz-pack-db, scoped to the WAL bucket) under a new barman server name, so the
# Hetzner archive never mixes with Fly's during the rollback week.
WAL_PY="$(base64 <<'PY' | tr -d '\n'
import os, urllib.parse as u
c = u.urlparse(os.environ["S3_ARCHIVE_CONFIG"])
bucket = c.path.strip("/").split("/")[0]
for k, v in [("AWS_ACCESS_KEY_ID", u.unquote(c.username)), ("AWS_SECRET_ACCESS_KEY", u.unquote(c.password)),
             ("AWS_DEFAULT_REGION", "auto"), ("WAL_S3_ENDPOINT", "https://" + c.hostname),
             ("WAL_S3_ARCHIVE", "s3://" + bucket), ("WAL_SERVER_NAME", "trubbo-prod")]:
    assert v and "'" not in v, k
    print(k + "='" + v + "'")
PY
)"
wal="$("${FLY[@]}" ssh console -a quiz-pack-db --pty=false \
  -C "python3 -c 'import base64;exec(base64.b64decode(\"$WAL_PY\"))'" 2>/dev/null | tr -d '\r')" \
  || { echo "reading the R2 archive config from quiz-pack-db failed: nothing written" >&2; exit 1; }
printf '%s\n' "$wal" | ssh "$HOST" "cd $DIR && umask 077 && cat > wal.env.tmp && [ \$(wc -l < wal.env.tmp) = 6 ] && mv wal.env.tmp wal.env && echo 'wal.env: 6 vars'"

push_app quiz-agent-api "" apps/quiz-agent/fly.toml quiz-agent.env 0
push_app quiz-pack-api "$("${FLY[@]}" machine list -a quiz-pack-api --json | jq -r '[.[] | select(.config.metadata.fly_process_group=="web")][0].id')" \
  apps/quiz-pack-api/fly.toml quiz-pack-api.env 0
