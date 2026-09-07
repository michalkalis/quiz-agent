#!/usr/bin/env bash
# #172 — session worker on a Mac (founder MacBook now, mba later): opens the
# prod Fly tunnels (Postgres + Redis) and runs the ARQ worker on the Claude
# Code subscription via run_session_worker.sh. Everything runs detached
# (nohup); logs + pids in ~/Library/Logs/quiz-session-worker/.
#
#   session_worker_local.sh start | stop | status
#
# Needs in repo-root .env: PROD_DATABASE_URL (localhost:15432 form),
# PROD_REDIS_URL (redis://:<REDIS_PASSWORD>@localhost:16379/0), OPENAI_API_KEY.
# Tunnels use the founder's `fly auth login` (app-scoped tokens do not cover
# quiz-pack-db / quiz-pack-redis), hence `env -u FLY_API_TOKEN`.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
RUN_DIR="$HOME/Library/Logs/quiz-session-worker"
mkdir -p "$RUN_DIR"

alive() { [ -f "$RUN_DIR/$1.pid" ] && kill -0 "$(cat "$RUN_DIR/$1.pid")" 2>/dev/null; }
listening() { lsof -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

start_proxy() {  # name local_port remote_port fly_app
  if listening "$2"; then echo "$1 tunnel already listening on :$2"; return; fi
  env -u FLY_API_TOKEN nohup fly proxy "$2:$3" -a "$4" >"$RUN_DIR/$1-proxy.log" 2>&1 &
  echo $! >"$RUN_DIR/$1-proxy.pid"
  for _ in $(seq 1 30); do listening "$2" && break; sleep 1; done
  listening "$2" || { echo "$1 tunnel failed — see $RUN_DIR/$1-proxy.log" >&2; exit 1; }
  echo "$1 tunnel up on :$2"
}

cmd_start() {
  set -a; source "$REPO/.env"; set +a
  for var in PROD_DATABASE_URL PROD_REDIS_URL OPENAI_API_KEY; do
    [ -n "${!var:-}" ] || { echo "$var missing in $REPO/.env" >&2; exit 1; }
  done
  alive worker && { echo "worker already running (pid $(cat "$RUN_DIR/worker.pid"))"; exit 0; }

  start_proxy db 15432 5432 quiz-pack-db
  start_proxy redis 16379 6379 quiz-pack-redis

  export PATH="$REPO/.venv/bin:$HOME/.local/bin:$PATH"
  # The shared venv also has apps/quiz-agent installed editable, whose `app`
  # package would shadow quiz-pack-api's (`arq` is a console script, so the
  # cwd is not on sys.path). Pin the import root explicitly.
  export PYTHONPATH="$REPO/apps/quiz-pack-api${PYTHONPATH:+:$PYTHONPATH}"
  export DATABASE_URL="$PROD_DATABASE_URL"
  export REDIS_URL="$PROD_REDIS_URL"
  export ORDER_QUEUE_NAME="quiz-pack:session"
  export WORKER_QUEUE_NAME="quiz-pack:session"
  export WORKER_MAX_JOBS="${WORKER_MAX_JOBS:-1}"
  export WORKER_JOB_TIMEOUT_S="${WORKER_JOB_TIMEOUT_S:-14400}"
  export ENVIRONMENT=production
  unset JUDGE_GATE JUDGE_MODELS ANTHROPIC_API_KEY CLAUDECODE CLAUDE_CODE_ENTRYPOINT

  nohup "$REPO/apps/quiz-pack-api/scripts/run_session_worker.sh" >"$RUN_DIR/worker.log" 2>&1 &
  echo $! >"$RUN_DIR/worker.pid"
  sleep 10
  if alive worker; then
    echo "worker running (pid $(cat "$RUN_DIR/worker.pid")) — log: $RUN_DIR/worker.log"
    tail -5 "$RUN_DIR/worker.log"
  else
    echo "worker exited — last log lines:" >&2; tail -20 "$RUN_DIR/worker.log" >&2; exit 1
  fi
}

cmd_stop() {
  for name in worker redis-proxy db-proxy; do
    if alive "$name"; then kill "$(cat "$RUN_DIR/$name.pid")" && echo "stopped $name"; fi
    rm -f "$RUN_DIR/$name.pid"
  done
}

cmd_status() {
  for name in db-proxy redis-proxy worker; do
    alive "$name" && echo "$name: running (pid $(cat "$RUN_DIR/$name.pid"))" || echo "$name: stopped"
  done
  [ -f "$RUN_DIR/worker.log" ] && { echo "--- worker.log (tail)"; tail -15 "$RUN_DIR/worker.log"; }
}

case "${1:-}" in
  start) cmd_start ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  *) echo "usage: $0 start|stop|status" >&2; exit 2 ;;
esac
