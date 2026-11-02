#!/usr/bin/env bash
# Copy app secrets from the Fly prod machines straight to the Hetzner server
# (#222 — moving the backend to Hetzner). Values are piped Fly -> server and never
# printed or written locally.
#
# Usage: infra/hetzner/pull-env.sh <rehearsal|prod> [ssh-host]
#   rehearsal: background jobs and alert mails off, ENVIRONMENT=staging (copied prod
#              data must not send mails, check providers or run paid generation).
#   prod:      same settings as the Fly prod apps.
# Needs: founder `fly auth login` (runs with FLY_API_TOKEN unset), ssh alias.
set -euo pipefail
MODE="${1:?rehearsal|prod}"
HOST="${2:-trubbo-prod}"
DIR="trubbo/repo/infra/hetzner/env"
FLY=(env -u FLY_API_TOKEN fly)

# Names only, never values. Fly-internal vars (FLY_*, PRIMARY_REGION, ...) are dropped.
secret_names() { "${FLY[@]}" secrets list -a "$1" --json | jq -r '.[].name' | grep -v '^FLY_' ; }
toml_env() { sed -n '/^\[env\]/,/^\[/p' "$1" | grep -E '^\s*[A-Z_]+\s*=' | sed -E 's/^\s*([A-Z_]+)\s*=\s*"?([^"]*)"?.*/\1=\2/'; }

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
  local app="$1" machine="$2" toml="$3" out="$4" redis_db="$5" names
  names="$(secret_names "$app" | paste -sd'|' -)"
  {
    "${FLY[@]}" ssh console -a "$app" ${machine:+--machine "$machine"} \
      -C "python3 -c 'import base64;exec(base64.b64decode(\"$DUMP_PY\"))' '$names'" 2>/dev/null \
      | tr -d '\r' | grep -vE '^(DATABASE_URL|REDIS_URL)='
    toml_env "$toml"
    if [ "$MODE" = rehearsal ]; then
      printf '%s\n' ENVIRONMENT=staging OPS_WATCH_ENABLED=false PROVIDER_BALANCE_CHECK_ENABLED=false \
        QUESTION_STOCK_CHECK_ENABLED=false ALERT_EMAIL_TO=
    fi
  } | ssh "$HOST" "cd $DIR && umask 077 && . ./postgres.env && . ./redis.env &&
      { tac | awk -F= '!seen[\$1]++' | tac;  # last value of a name wins (overrides below)
        echo DATABASE_URL=postgres://postgres:\$POSTGRES_PASSWORD@postgres:5432/quiz_pack;
        echo REDIS_URL=redis://:\$REDIS_PASSWORD@redis:6379/$redis_db; } > $out.tmp && mv $out.tmp $out &&
      echo \"$out: \$(wc -l < $out) vars\""
}

push_app quiz-agent-api "" apps/quiz-agent/fly.toml quiz-agent.env 0
push_app quiz-pack-api "$("${FLY[@]}" machine list -a quiz-pack-api --json | jq -r '[.[] | select(.config.metadata.fly_process_group=="web")][0].id')" \
  apps/quiz-pack-api/fly.toml quiz-pack-api.env 0
