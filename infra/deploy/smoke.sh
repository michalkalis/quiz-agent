#!/usr/bin/env bash
# Post-deploy smoke test for one backend app (#207 task 207.16).
#
#   infra/deploy/smoke.sh quiz-agent    https://quiz-agent-api.fly.dev
#   infra/deploy/smoke.sh quiz-pack-api https://quiz-pack-api-staging.fly.dev
#
# Fails (exit 1) when the app does not answer like a working deploy. Checks
# only public, data-free endpoints: the repo is public and so are CI logs.
# Retries allow a cold start (staging and quiz-pack-api web scale to zero).
set -euo pipefail

app="${1:?app: quiz-agent | quiz-pack-api}"
base="${2:?base URL}"
base="${base%/}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fetch() { # fetch <path> <outfile>: GET with cold-start retries, fail on non-2xx
  curl -fsS --retry 4 --retry-all-errors --retry-delay 10 --max-time 60 "$base$1" -o "$2"
}

case "$app" in
  quiz-agent)
    fetch /api/v1/health "$tmp/health.json"
    # The health route probes the DB; "healthy" means Postgres answered too.
    python3 - "$tmp/health.json" <<'EOF'
import json, sys
b = json.load(open(sys.argv[1]))
assert b.get("status") == "healthy", f"health: {b}"
print("health: healthy (DB reachable)")
EOF
    # Shipped iOS builds read this at every launch; its shape is the contract
    # the live 1.0/1.1 clients depend on (RemoteAppConfig.swift).
    fetch /api/v1/app-config "$tmp/app-config.json"
    python3 - "$tmp/app-config.json" <<'EOF'
import json, sys
b = json.load(open(sys.argv[1]))
assert isinstance(b.get("orders_enabled"), bool), "app-config: orders_enabled missing or not bool"
for k in ("min_version_app_store", "min_version_testflight"):
    assert k in b and (b[k] is None or isinstance(b[k], str)), f"app-config: bad {k}"
assert b.get("notice") is None or isinstance(b["notice"], dict), "app-config: bad notice"
print(f"app-config: orders_enabled={b['orders_enabled']} min_app_store={b['min_version_app_store']} "
      f"notice={'set' if b.get('notice') else 'none'}")
EOF
    fetch /openapi.json "$tmp/openapi.json"
    python3 - "$tmp/openapi.json" <<'EOF'
import json, sys
paths = json.load(open(sys.argv[1]))["paths"]
for p in ("/api/v1/health", "/api/v1/app-config", "/api/v1/sessions"):
    assert any(k.startswith(p) for k in paths), f"openapi: route {p} missing"
print(f"openapi: {len(paths)} routes")
EOF
    ;;
  quiz-pack-api)
    fetch /health "$tmp/health.json"
    echo "health: $(cat "$tmp/health.json")"
    fetch /openapi.json "$tmp/openapi.json"
    python3 - "$tmp/openapi.json" <<'EOF'
import json, sys
paths = json.load(open(sys.argv[1]))["paths"]
assert any(k.startswith("/api/v1/orders") for k in paths), "openapi: orders routes missing"
print(f"openapi: {len(paths)} routes")
EOF
    ;;
  *)
    echo "unknown app: $app" >&2
    exit 2
    ;;
esac
echo "smoke OK: $app at $base"
