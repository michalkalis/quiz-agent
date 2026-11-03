#!/usr/bin/env bash
# Point this Mac's prod tools at the Hetzner server or back at Fly (#222 — moving
# the backend to Hetzner). Rewrites three lines of the repo-root .env:
#   PROD_TUNNEL        hetzner | fly  (session_worker_local.sh picks the tunnel)
#   PROD_DATABASE_URL  localhost:15432 form, password of the chosen side
#   PROD_REDIS_URL     localhost:16379 form, password of the chosen side
# The Fly values are kept as PROD_*_URL_FLY on the first switch, so `fly`
# restores them (rollback). Passwords go server -> file over stdin and are never
# printed or put on a command line.
#
# Usage: infra/hetzner/local-prod-env.sh <hetzner|fly> [ssh-host]
# Afterwards restart the mba backup worker: session_worker_local.sh install-launchd
set -euo pipefail
MODE="${1:?hetzner|fly}"
HOST="${2:-trubbo-prod}"
ENV_FILE="${TRUBBO_ENV_FILE:-$(cd "$(dirname "$0")/../.." && pwd)/.env}"
[ -f "$ENV_FILE" ] || { echo "no $ENV_FILE" >&2; exit 1; }
[[ "$MODE" =~ ^(hetzner|fly)$ ]] || { echo "mode must be hetzner or fly" >&2; exit 2; }

case "$MODE" in
  hetzner)
    # Two lines on stdin: Postgres password, Redis password.
    ssh "$HOST" 'cd trubbo/repo/infra/hetzner/env && . ./postgres.env && . ./redis.env &&
      printf "%s\n%s\n" "$POSTGRES_PASSWORD" "$REDIS_PASSWORD"' ;;
  fly) : ;;
esac | MODE="$MODE" ENV_FILE="$ENV_FILE" python3 -c '
import os, re, sys
mode, path = os.environ["MODE"], os.environ["ENV_FILE"]
lines = open(path).read().splitlines()
env = {}
for line in lines:
    m = re.match(r"([A-Z_]+)=(.*)$", line)
    if m:
        env[m.group(1)] = m.group(2)
want = {}
if mode == "hetzner":
    pg, redis = (sys.stdin.readline().strip(), sys.stdin.readline().strip())
    if not pg or not redis:
        sys.exit("could not read the server passwords")
    for k in ("PROD_DATABASE_URL", "PROD_REDIS_URL"):
        if k + "_FLY" not in env and k in env and env.get("PROD_TUNNEL", "fly") != "hetzner":
            want[k + "_FLY"] = env[k]
    want["PROD_DATABASE_URL"] = f"postgres://postgres:{pg}@localhost:15432/quiz_pack"
    want["PROD_REDIS_URL"] = f"redis://:{redis}@localhost:16379/0"
    want["PROD_TUNNEL"] = "hetzner"
else:
    for k in ("PROD_DATABASE_URL", "PROD_REDIS_URL"):
        if k + "_FLY" not in env:
            sys.exit(f"{k}_FLY missing: nothing to restore")
        want[k] = env[k + "_FLY"]
    want["PROD_TUNNEL"] = "fly"
out, done = [], set()
for line in lines:
    m = re.match(r"([A-Z_]+)=", line)
    if m and m.group(1) in want:
        out.append(f"{m.group(1)}={want[m.group(1)]}")
        done.add(m.group(1))
    else:
        out.append(line)
out += [f"{k}={v}" for k, v in want.items() if k not in done]
tmp = path + ".tmp"
with open(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
    f.write("\n".join(out) + "\n")
os.replace(tmp, path)
print(f".env now points at {mode} (" + ", ".join(sorted(want)) + ")")
'
