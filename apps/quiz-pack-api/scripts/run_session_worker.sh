#!/usr/bin/env bash
# ARQ worker on the Claude Code subscription (#172 — session worker: custom
# packy v bete cez subscription). Run on `mba`, inside tmux, with the two
# `fly proxy` tunnels already up in their own windows:
#
#   fly proxy 15432:5432 -a quiz-pack-db
#   fly proxy 16379:6379 -a quiz-pack-redis
#
# Full founder procedure: docs/setup/session-worker-mba.md
set -euo pipefail

fail() { echo "run_session_worker: $*" >&2; exit 1; }

command -v claude >/dev/null 2>&1 || fail "the \`claude\` CLI is not on PATH — LLM_GATEWAY=session needs Claude Code."
auth_status="$(claude auth status 2>/dev/null || true)"
# Same rule the worker enforces via quiz_shared.llm.session_cli: logged in AND
# via claude.ai. API-key auth is refused on purpose — a session run must never
# bill the API.
grep -q '"loggedIn"[[:space:]]*:[[:space:]]*true' <<<"$auth_status" \
  && grep -q '"authMethod"[[:space:]]*:[[:space:]]*"claude.ai"' <<<"$auth_status" \
  || fail "\`claude auth status\` shows no claude.ai subscription login (got: ${auth_status:0:120}). Run \`claude\` and log in."

for var in DATABASE_URL REDIS_URL OPENAI_API_KEY; do
  [ -n "${!var:-}" ] || fail "$var is not set (see docs/setup/session-worker-mba.md)."
done

# Judges are always OFF on the subscription (#169): the panel added no signal
# and ate most of the quota. The worker refuses to boot with them set; catch it
# here too so the mistake is named before anything connects.
[ -z "${JUDGE_GATE:-}" ] && [ -z "${JUDGE_MODELS:-}" ] || fail "JUDGE_GATE/JUDGE_MODELS must be unset for a session run (#169)."

export LLM_GATEWAY=session

cd "$(dirname "$0")/.."
echo "run_session_worker: queue=${WORKER_QUEUE_NAME:-arq:queue} max_jobs=${WORKER_MAX_JOBS:-2} timeout=${WORKER_JOB_TIMEOUT_S:-3600}"
exec arq app.worker.WorkerSettings
