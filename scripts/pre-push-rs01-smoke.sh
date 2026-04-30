#!/usr/bin/env bash
# Pre-push smoke gate: lite RS-01 verifying the UI-test HTTP listener path.
#
# Triggered only on pushes to refs/heads/main. Bypass with `git push --no-verify`.
#
# Constraints (see scripts/install-pre-push-hook.sh):
#   - 5s timeout to find a booted simulator; skip if none.
#   - Never block on environment availability — only block on a clear FAIL.
#   - Hard cap total runtime at 90s.
#   - Verdict line always goes to stderr.
#
# What "clear FAIL" means here: Hangs.app is installed and was launched in
# --ui-test mode, but the DEBUG-Local HTTP listener never bound on
# 127.0.0.1:9999, OR didn't accept a /stt/committed event. That signals the
# UI-test surface is broken on main and the regression suite cannot run.

set -u

BUNDLE_ID="com.missinghue.hangs"
LISTENER_HOST="127.0.0.1"
LISTENER_PORT="9999"
HARD_CAP_SECS=90
START_TS=$SECONDS

log() { printf '[pre-push:RS-01] %s\n' "$*" >&2; }
verdict() { printf '[pre-push:RS-01] VERDICT: %s\n' "$*" >&2; }

elapsed() { echo $((SECONDS - START_TS)); }
remaining() { echo $((HARD_CAP_SECS - $(elapsed))); }

# Portable timeout. macOS doesn't ship `timeout`; perl is always present.
# Returns the wrapped command's exit status, or 142 on alarm.
run_with_timeout() {
    local secs="$1"; shift
    if command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$secs" "$@"
    elif command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift @ARGV; exec @ARGV' "$secs" "$@"
    fi
}

# --- 1. Only smoke on pushes to main (skip delete pushes) -------------------
ZERO_OID="0000000000000000000000000000000000000000"
PUSHING_TO_MAIN=0
while IFS=' ' read -r lref lsha rref rsha; do
    [ -z "${rref:-}" ] && continue
    [ "${lsha:-}" = "$ZERO_OID" ] && continue   # delete push, nothing to smoke
    if [ "$rref" = "refs/heads/main" ]; then
        PUSHING_TO_MAIN=1
    fi
done

if [ "$PUSHING_TO_MAIN" -eq 0 ]; then
    exit 0
fi

# --- 2. Find a booted iPhone simulator (5s budget) --------------------------
SIM_LIST=""
SIM_LIST=$(run_with_timeout 5 xcrun simctl list devices booted 2>/dev/null || true)

BOOTED_SIM=$(printf '%s\n' "$SIM_LIST" \
    | grep -Ei "iPhone .*\(Booted\)" \
    | head -1 \
    | grep -oE "[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}" \
    | head -1 || true)

if [ -z "${BOOTED_SIM:-}" ]; then
    log "no booted iPhone simulator within 5s — skipping"
    verdict "SKIP — no booted simulator (run 'open -a Simulator' to enable)"
    exit 0
fi

# --- 3. Confirm Hangs.app is installed -------------------------------------
if ! run_with_timeout 5 xcrun simctl get_app_container "$BOOTED_SIM" "$BUNDLE_ID" app >/dev/null 2>&1; then
    log "Hangs.app ($BUNDLE_ID) not installed on $BOOTED_SIM — skipping"
    verdict "SKIP — Hangs.app not installed on booted sim"
    exit 0
fi

# --- 4. Stop any prior instance, then launch in --ui-test mode -------------
xcrun simctl terminate "$BOOTED_SIM" "$BUNDLE_ID" >/dev/null 2>&1 || true

if ! run_with_timeout 10 xcrun simctl launch "$BOOTED_SIM" "$BUNDLE_ID" --ui-test >/dev/null 2>&1; then
    log "failed to launch Hangs.app with --ui-test — skipping"
    verdict "SKIP — launch failed (env issue, not RS-01)"
    exit 0
fi

cleanup() {
    xcrun simctl terminate "$BOOTED_SIM" "$BUNDLE_ID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- 5. Poll for HTTP listener ---------------------------------------------
LISTENER_READY=0
while [ "$(elapsed)" -lt $((HARD_CAP_SECS - 10)) ]; do
    code=$(curl -sf -o /dev/null -w '%{http_code}' \
        --max-time 1 \
        "http://${LISTENER_HOST}:${LISTENER_PORT}/stt/connected" 2>/dev/null || true)
    if [ "$code" = "200" ]; then
        LISTENER_READY=1
        break
    fi
    sleep 1
done

if [ "$LISTENER_READY" -ne 1 ]; then
    verdict "FAIL — HTTP listener never bound on ${LISTENER_HOST}:${LISTENER_PORT} after $(elapsed)s (Debug-Local build broken? UITestSupport regression?). Bypass with: git push --no-verify"
    exit 1
fi

# --- 6. Inject one committed event to prove the event path is alive --------
if [ "$(remaining)" -lt 5 ]; then
    verdict "PASS — listener bound (skipped event-path probe, near time cap)"
    exit 0
fi

INJECT_CODE=$(curl -sf -o /dev/null -w '%{http_code}' \
    --max-time 3 \
    "http://${LISTENER_HOST}:${LISTENER_PORT}/stt/committed?text=Paris" 2>/dev/null || true)

if [ "$INJECT_CODE" != "200" ]; then
    verdict "FAIL — listener bound but /stt/committed returned ${INJECT_CODE:-no-response}. Bypass with: git push --no-verify"
    exit 1
fi

verdict "PASS — listener bound, /stt/committed accepted ($(elapsed)s elapsed)"
exit 0
