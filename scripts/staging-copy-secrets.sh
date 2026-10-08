#!/usr/bin/env bash
# Copy named Fly secrets from a prod app to its staging app without printing
# any value (#193 task 193.10, docs/setup/staging.md). Values are staged, so they
# take effect on the next staging deploy.
#
#   scripts/staging-copy-secrets.sh <prod-app> <staging-app> NAME [NAME...]
#
# Never copy DATABASE_URL, REDIS_URL, ORDER_QUEUE_NAME, WORKER_QUEUE_NAME,
# STOREKIT_ENVIRONMENT or RC_ALLOWED_ENVIRONMENT: those are what keep staging
# off prod data and queues. Single-line values only.
set -euo pipefail
prod="${1:?prod app}"; stg="${2:?staging app}"; shift 2
[[ $# -gt 0 ]] || { echo "name at least one secret" >&2; exit 1; }

for n in "$@"; do
  case "$n" in
    DATABASE_URL|REDIS_URL|ORDER_QUEUE_NAME|WORKER_QUEUE_NAME|STOREKIT_ENVIRONMENT|RC_ALLOWED_ENVIRONMENT)
      echo "refusing to copy $n: it isolates staging from prod" >&2; exit 1 ;;
  esac
done

# Wake a prod web machine (apps scale to zero) so `fly ssh` has a target.
curl -s -o /dev/null -m 60 "https://$prod.fly.dev/health" || true
curl -s -o /dev/null -m 60 "https://$prod.fly.dev/api/v1/health" || true

lines=""
for n in "$@"; do
  v=$(fly ssh console -a "$prod" --pty=false -C "printenv $n" 2>/dev/null | tr -d '\r')
  [[ -n "$v" ]] || { echo "$n is not set on $prod" >&2; exit 1; }
  [[ "$v" != *$'\n'* ]] || { echo "$n is multi-line, set it by hand" >&2; exit 1; }
  lines+="$n=$v"$'\n'
done
printf '%s' "$lines" | fly secrets import --stage -a "$stg" >/dev/null
echo "staged on $stg: $*"
