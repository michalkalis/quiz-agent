#!/usr/bin/env bash
# CI deploy entry point for the Hetzner server (#222). Runs as an SSH forced
# command: the deploy key can do nothing but this script.
#
# Install on the server (~trubbo/.ssh/authorized_keys), one line:
#   command="/home/trubbo/trubbo/bin/deploy-ssh.sh",restrict ssh-ed25519 AAAA... trubbo-ci-deploy
#
# Accepted SSH_ORIGINAL_COMMAND:
#   deploy <40-hex sha> <services>   services: comma list of quiz-agent,pack
#   status                           current sha + docker compose ps
#
# Deploy: sha must be an ancestor of origin/main -> checkout -> build ->
# migrate (like Fly's release_command, before the swap) -> up -> wait healthy.
# On failure the previous sha is rebuilt and restarted, exit code non-zero.
set -euo pipefail

REPO="${TRUBBO_REPO:-/home/trubbo/trubbo/repo}"
COMPOSE_DIR="$REPO/infra/hetzner"
LOCK="${TRUBBO_DEPLOY_LOCK:-/home/trubbo/trubbo/deploy.lock}"
HEALTH_TIMEOUT=120

log() { echo "[deploy] $*"; }
die() { echo "[deploy] ERROR: $*" >&2; exit 2; }

cmd="${SSH_ORIGINAL_COMMAND:-}"
verb="" sha="" services="" extra=""
read -r verb sha services extra <<<"$cmd" || true

cd "$COMPOSE_DIR"

case "$verb" in
  status)
    [ -z "$sha" ] || die "status takes no arguments"
    echo "sha: $(git -C "$REPO" rev-parse HEAD)"
    docker compose ps
    exit 0
    ;;
  deploy) ;;
  *) die "usage: deploy <40-hex sha> <quiz-agent,pack> | status" ;;
esac

[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "sha must be 40 lowercase hex chars"
[ -z "$extra" ] || die "too many arguments"
[[ "$services" =~ ^(quiz-agent|pack)(,(quiz-agent|pack))*$ ]] || die "services must be a comma list of quiz-agent,pack"

want_pack=0
build_svcs=()
migrate_svcs=()
IFS=',' read -ra parts <<<"$services"
for s in "${parts[@]}"; do
  case "$s" in
    quiz-agent) build_svcs+=(quiz-agent) ;;
    pack) build_svcs+=(pack-web); want_pack=1 ;;
    *) die "unknown service: $s" ;;
  esac
done
migrate_svcs=("${build_svcs[@]}")
up_svcs=("${build_svcs[@]}")

exec 9>"$LOCK"
flock -w 600 9 || die "another deploy holds the lock"

# The worker shares the pack-web image; restart it only if it already runs, so a
# rehearsal server (worker off on purpose) never starts it.
worker_running=0
if [ "$want_pack" = 1 ] && [ -n "$(docker compose --profile worker ps --status running -q pack-worker)" ]; then
  worker_running=1
fi

cid() { docker compose --profile worker ps -q "$1"; }

# wait_healthy: every touched service healthy within HEALTH_TIMEOUT.
wait_healthy() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT)) s id state
  local check=("${up_svcs[@]}")
  [ "$worker_running" = 0 ] || check+=(pack-worker)
  for s in "${check[@]}"; do
    while :; do
      id="$(cid "$s")"
      state=missing
      if [ -n "$id" ]; then
        # The worker has no HTTP check (the image's healthcheck targets the web port): "running" is all we can ask.
        if [ "$s" = pack-worker ]; then
          state="$(docker inspect -f '{{.State.Status}}' "$id")"
          [ "$state" != running ] || break
        else
          state="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id")"
          [ "$state" != healthy ] || break
        fi
      fi
      if [ "$SECONDS" -ge "$deadline" ]; then
        echo "[deploy] $s not healthy after ${HEALTH_TIMEOUT}s (state: $state)" >&2
        return 1
      fi
      sleep 3
    done
    log "$s ok"
  done
  # A crash-looping worker can look "running" for a moment: confirm it stays up.
  if [ "$worker_running" = 1 ]; then
    sleep 10
    [ "$(docker inspect -f '{{.State.Status}}' "$(cid pack-worker)")" = running ] || {
      echo "[deploy] pack-worker is not staying up" >&2
      return 1
    }
  fi
}

# apply <label>: build, migrate, swap, wait healthy. Called inside `if`, where
# set -e is off, so every step ends in an explicit `|| return 1`.
apply() {
  local s
  log "$1: build ${build_svcs[*]}"
  docker compose build "${build_svcs[@]}" || return 1
  for s in "${migrate_svcs[@]}"; do
    log "$1: migrate $s"
    docker compose run --rm "$s" alembic upgrade head || return 1
  done
  log "$1: up ${up_svcs[*]}"
  docker compose up -d "${up_svcs[@]}" || return 1
  if [ "$worker_running" = 1 ]; then
    docker compose --profile worker up -d pack-worker || return 1
  fi
  wait_healthy
}

prev="$(git -C "$REPO" rev-parse HEAD)"
log "current ${prev:0:8}, target ${sha:0:8}, services: $services"

git -C "$REPO" fetch -q origin main
git -C "$REPO" cat-file -e "$sha^{commit}" 2>/dev/null || die "commit $sha not found after fetch"
git -C "$REPO" merge-base --is-ancestor "$sha" origin/main || die "$sha is not an ancestor of origin/main; refusing"

git -C "$REPO" checkout -q --detach "$sha"
if apply deploy; then
  log "OK: ${sha:0:8} live"
  exit 0
fi

echo "[deploy] FAILED, rolling back to ${prev:0:8}" >&2
git -C "$REPO" checkout -q --detach "$prev"
if apply rollback; then
  echo "[deploy] rolled back to ${prev:0:8} (${sha:0:8} was NOT deployed)" >&2
else
  echo "[deploy] ROLLBACK ALSO FAILED: inspect the server" >&2
fi
exit 1
