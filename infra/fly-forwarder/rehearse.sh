#!/usr/bin/env bash
# Rehearse the Fly forwarder before the cutover (#222 — moving the backend to
# Hetzner), so its first real run is not during the outage. Deploys the same
# forwarder image to a throwaway Fly app pointed at api.trubbo.app (the Hetzner
# rehearsal stack), checks it, and destroys the app again (cost: cents).
#
# Usage: infra/fly-forwarder/rehearse.sh [org]     (run from the repo root)
# Checks: health + app-config through the forwarder (smoke.sh: TLS to the
# server, Host header, streaming) and that a POST arrives as a POST
# (422 validation error, not 405 / a GET). The IP trust chain itself is verified
# on the server (infra/hetzner/README.md, "Client IP").
# Needs: founder `fly auth login` (runs with FLY_API_TOKEN unset), ssh alias trubbo-prod.
set -euo pipefail
ORG="${1:-personal}"
APP="trubbo-fwd-rehearsal-$(date +%s)"
FLY=(env -u FLY_API_TOKEN fly)
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
cfg="$DIR/.fly.rehearsal.toml" # next to the Dockerfile: [build] paths are relative to the config
trap 'rm -f "$cfg"; "${FLY[@]}" apps destroy "$APP" --yes >/dev/null 2>&1 && echo "destroyed $APP"' EXIT

sed -e "s/^app = .*/app = \"$APP\"/" "$DIR/fly.quiz-agent-api.toml" >"$cfg"
"${FLY[@]}" apps create "$APP" --org "$ORG" >/dev/null
# Secret straight from the server into Fly, never printed.
ssh trubbo-prod 'cat trubbo/repo/infra/hetzner/env/forwarder.env' | "${FLY[@]}" secrets import -a "$APP" --stage >/dev/null
(cd "$DIR" && "${FLY[@]}" deploy -c "$cfg" -a "$APP" --ha=false --yes)

base="https://$APP.fly.dev"
"$REPO/infra/deploy/smoke.sh" quiz-agent "$base"
code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' "$base/api/v1/auth/refresh")"
[ "$code" = 422 ] || { echo "POST through the forwarder answered $code, expected 422" >&2; exit 1; }
echo "POST passes as POST (422)"
echo "forwarder rehearsal OK"
