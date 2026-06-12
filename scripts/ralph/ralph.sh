#!/usr/bin/env bash
# Ralph Loop — autonomous task burndown for Claude Code
#
# Usage:
#   scripts/ralph/ralph.sh <focus-file> [max-iters] [max-cost-usd-per-iter]
#
# Example:
#   scripts/ralph/ralph.sh docs/issues/issue-30-batch-generate-categories.md 20 5
#
# Each iteration spawns a fresh `claude -p` session, scoped to one atomic task.
# Commits land on the current branch. Push is intentionally NOT done — human
# reviews in the morning.

set -euo pipefail

FOCUS_FILE="${1:?Usage: ralph.sh <focus-file> [max-iters=20] [budget-usd=5]}"
MAX_ITERS="${2:-20}"
BUDGET_USD="${3:-5}"

if [[ ! -f "$FOCUS_FILE" ]]; then
    echo "[ralph] focus file not found: $FOCUS_FILE" >&2
    exit 2
fi

# Resolve absolute paths
REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT_DIR="$REPO_ROOT/scripts/ralph"
PROMPT_TEMPLATE="$SCRIPT_DIR/prompts/work-next.md"
ROUTER_TEMPLATE="$SCRIPT_DIR/prompts/route-model.md"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"

if [[ ! -f "$PROMPT_TEMPLATE" ]]; then
    echo "[ralph] prompt template missing: $PROMPT_TEMPLATE" >&2
    exit 2
fi

# Per-iteration model routing. Set RALPH_ROUTER=0 to disable (always use $DEFAULT_MODEL).
RALPH_ROUTER="${RALPH_ROUTER:-1}"
DEFAULT_MODEL="${RALPH_DEFAULT_MODEL:-sonnet}"
ROUTER_BUDGET_USD="${RALPH_ROUTER_BUDGET_USD:-0.50}"

# Map a ROUTE: token to a --model value. Aliases work for the latest models;
# fable is spelled in full to be explicit about the premium tier.
route_to_model() {
    case "$1" in
        haiku)  echo "haiku" ;;
        sonnet) echo "sonnet" ;;
        opus)   echo "opus" ;;
        fable)  echo "claude-fable-5" ;;
        *)      echo "" ;;
    esac
}

# Safety preflight: working tree must be clean (avoid mixing autonomous + manual changes)
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
    echo "[ralph] working tree dirty — commit or stash before starting:" >&2
    git -C "$REPO_ROOT" status --short >&2
    exit 3
fi

START_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
START_TS="$(date +%Y%m%d-%H%M%S)"
RUN_LOG="$LOG_DIR/run-$START_TS.log"

CONSECUTIVE_FAILS=0
MAX_CONSEC_FAILS=3
COMPLETED=0
BLOCKED=0

log() {
    echo "[ralph $(date +%H:%M:%S)] $*" | tee -a "$RUN_LOG"
}

log "starting Ralph run"
log "  focus:       $FOCUS_FILE"
log "  max iters:   $MAX_ITERS"
log "  budget/iter: \$$BUDGET_USD"
log "  start sha:   $START_SHA"
log "  run log:     $RUN_LOG"

# iOS focus files need XcodeBuildMCP (build_sim / screenshot / snapshot_ui) for the
# screenshot-verify + regression steps. The headless `claude -p` does NOT pick up
# ~/.claude.json MCP servers on mba (the agent user's config has none), so attach a
# repo-tracked config explicitly — gated to iOS focus files so backend runs don't
# spawn the npx server every iteration. Empty-array expansion is guarded for bash 3.2.
MCP_ARGS=()
if grep -qE "apps/ios-app|xcodebuild" "$REPO_ROOT/$FOCUS_FILE" 2>/dev/null; then
    XCODE_MCP_CONFIG="$SCRIPT_DIR/xcodebuildmcp.mcp.json"
    if [[ -f "$XCODE_MCP_CONFIG" ]]; then
        MCP_ARGS=(--mcp-config "$XCODE_MCP_CONFIG")
        log "  iOS focus detected → attaching XcodeBuildMCP ($XCODE_MCP_CONFIG)"
    else
        log "  ⚠ iOS focus but $XCODE_MCP_CONFIG missing — screenshot-verify unavailable"
    fi
fi

# Build the system prompt (substitute focus file path)
SYSTEM_PROMPT="$(sed "s|__FOCUS_FILE__|$FOCUS_FILE|g" "$PROMPT_TEMPLATE")"

for iter in $(seq 1 "$MAX_ITERS"); do
    ITER_LOG="$LOG_DIR/iter-$START_TS-$(printf '%02d' "$iter").log"
    log "─── iteration $iter/$MAX_ITERS → $ITER_LOG"

    PRE_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"

    # ── Router pre-pass: a cheap Haiku call picks the model for THIS iteration.
    # It reads the focus file (read-only), finds the same "next task" the worker
    # will pick, applies the rubric in route-model.md, and prints `ROUTE: <model>`.
    CHOSEN_MODEL="$DEFAULT_MODEL"
    ROUTE_SOURCE="default"
    if [[ "$RALPH_ROUTER" == "1" && -f "$ROUTER_TEMPLATE" ]]; then
        ROUTER_LOG="$LOG_DIR/route-$START_TS-$(printf '%02d' "$iter").log"
        ROUTER_PROMPT="$(sed "s|__FOCUS_FILE__|$FOCUS_FILE|g" "$ROUTER_TEMPLATE")"
        set +e
        claude \
            -p "Route the next Ralph task on $FOCUS_FILE. End with the ROUTE: line." \
            --model haiku \
            --permission-mode bypassPermissions \
            --allowed-tools "Read" "Grep" "Glob" \
            --max-budget-usd "$ROUTER_BUDGET_USD" \
            --no-session-persistence \
            --append-system-prompt "$ROUTER_PROMPT" \
            > "$ROUTER_LOG" 2>&1
        set -e
        ROUTE_TOKEN="$(grep -oE 'ROUTE:[[:space:]]*[a-zA-Z0-9-]+' "$ROUTER_LOG" | tail -1 | sed -E 's/ROUTE:[[:space:]]*//' || true)"
        MAPPED_MODEL="$(route_to_model "$ROUTE_TOKEN")"
        if [[ -n "$MAPPED_MODEL" ]]; then
            CHOSEN_MODEL="$MAPPED_MODEL"
            ROUTE_SOURCE="router"
        else
            log "  router parse failed (token='$ROUTE_TOKEN') → fallback $DEFAULT_MODEL"
            ROUTE_SOURCE="fallback"
        fi
    fi
    log "  route=$CHOSEN_MODEL ($ROUTE_SOURCE)"

    # Degrade ladder on model-unavailable: the premium tier (fable) falls back to
    # opus, not all the way down to sonnet — a fable task was routed there because
    # it needs heavy reasoning, so opus is the right safety net. Every other tier
    # keeps the sonnet net.
    if [[ "$CHOSEN_MODEL" == "claude-fable-5" ]]; then
        FALLBACK_MODEL="opus"
    else
        FALLBACK_MODEL="sonnet"
    fi

    # Run one Claude iteration. 25 min hard timeout via gtimeout if installed,
    # otherwise rely on --max-budget-usd to bound cost.
    TIMEOUT_CMD=""
    if command -v gtimeout >/dev/null 2>&1; then
        TIMEOUT_CMD="gtimeout 1500"
    elif command -v timeout >/dev/null 2>&1; then
        TIMEOUT_CMD="timeout 1500"
    fi

    set +e
    # Allow long foreground Bash calls (generation batches) — see prompt rule #10.
    # 20 min < the 25 min gtimeout above, so the iteration cap still wins.
    BASH_MAX_TIMEOUT_MS=1200000 $TIMEOUT_CMD claude \
        -p "Run one Ralph iteration on $FOCUS_FILE. End with the RALPH_RESULT marker." \
        --model "$CHOSEN_MODEL" \
        --permission-mode bypassPermissions \
        --max-budget-usd "$BUDGET_USD" \
        --fallback-model "$FALLBACK_MODEL" \
        --effort high \
        --no-session-persistence \
        ${MCP_ARGS[@]+"${MCP_ARGS[@]}"} \
        --append-system-prompt "$SYSTEM_PROMPT" \
        > "$ITER_LOG" 2>&1
    EXIT_CODE=$?
    set -e

    POST_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"

    # Parse RALPH_RESULT from log. Use [[:space:]] (POSIX) not \s — BSD sed on
    # macOS does not recognize \s and silently returns the input unchanged,
    # which made every successful "done" iteration count as a failure.
    RESULT_LINE="$(grep -oE 'RALPH_RESULT:[[:space:]]*\{.*\}' "$ITER_LOG" | tail -1 || true)"
    if [[ -n "$RESULT_LINE" ]]; then
        STATUS="$(echo "$RESULT_LINE" | sed -E 's/.*"status":[[:space:]]*"([^"]+)".*/\1/')"
        TASK="$(echo "$RESULT_LINE" | sed -E 's/.*"task":[[:space:]]*"([^"]+)".*/\1/')"
    else
        STATUS="parse-fail"
        TASK="(no marker)"
    fi

    log "  exit=$EXIT_CODE status=$STATUS task=\"$TASK\""
    if [[ "$PRE_SHA" != "$POST_SHA" ]]; then
        log "  new commit: $(git -C "$REPO_ROOT" log -1 --oneline)"
    else
        log "  no new commit"
    fi

    case "$STATUS" in
        done)
            COMPLETED=$((COMPLETED + 1))
            CONSECUTIVE_FAILS=0
            ;;
        no-tasks)
            log "✓ focus file reports no remaining tasks — exiting cleanly"
            break
            ;;
        blocked)
            BLOCKED=$((BLOCKED + 1))
            CONSECUTIVE_FAILS=$((CONSECUTIVE_FAILS + 1))
            log "⚠ iteration blocked"
            ;;
        *)
            CONSECUTIVE_FAILS=$((CONSECUTIVE_FAILS + 1))
            log "✗ iteration failed (status=$STATUS, exit=$EXIT_CODE)"
            ;;
    esac

    if [[ $CONSECUTIVE_FAILS -ge $MAX_CONSEC_FAILS ]]; then
        log "✗ $MAX_CONSEC_FAILS consecutive failures — stopping for human review"
        exit 1
    fi

    if [[ $CONSECUTIVE_FAILS -gt 0 ]]; then
        BACKOFF=$((2 ** CONSECUTIVE_FAILS))
        log "  backoff ${BACKOFF}s before next iteration"
        sleep "$BACKOFF"
    fi
done

END_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
log "─── Ralph run finished"
log "  completed iterations: $COMPLETED"
log "  blocked iterations:   $BLOCKED"
log "  commits this run:     $(git -C "$REPO_ROOT" rev-list --count "$START_SHA..$END_SHA")"
log "  start → end:          $START_SHA → $END_SHA"

# ── End-of-run iOS test gate (#54 §54.8 item 1): a run that touched iOS code
# must not end "green" with a red unit suite — that's how the #54 design-refresh
# branch landed red unnoticed. Unit target only (HangsTests): UI tests are too
# slow/flaky for an unattended headless gate; CI covers them on push.
GATE_STATUS="skipped"
if git -C "$REPO_ROOT" diff --name-only "$START_SHA..$END_SHA" | grep -q '^apps/ios-app/'; then
    log "─── iOS files changed this run → test gate (xcodebuild test, HangsTests)"
    GATE_LOG="$LOG_DIR/test-gate-$START_TS.log"
    GATE_TIMEOUT_CMD=""
    if command -v gtimeout >/dev/null 2>&1; then
        GATE_TIMEOUT_CMD="gtimeout 2400"
    elif command -v timeout >/dev/null 2>&1; then
        GATE_TIMEOUT_CMD="timeout 2400"
    fi
    set +e
    (cd "$REPO_ROOT/apps/ios-app/Hangs" && $GATE_TIMEOUT_CMD xcodebuild test \
        -scheme Hangs-Local \
        -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
        -only-testing:HangsTests \
        -quiet) > "$GATE_LOG" 2>&1
    GATE_EXIT=$?
    set -e
    if [[ $GATE_EXIT -eq 0 ]]; then
        GATE_STATUS="green"
        log "✓ TEST GATE GREEN (HangsTests)"
    else
        GATE_STATUS="red"
        log "✗ TEST GATE RED (exit=$GATE_EXIT) — do NOT push before fixing"
        log "  gate log: $GATE_LOG"
        grep -E "Failing tests:|Test [Cc]ase .* failed|error:" "$GATE_LOG" | head -20 | while IFS= read -r line; do
            log "  $line"
        done
    fi
fi

log ""
log "Next steps (human):"
log "  git log $START_SHA..HEAD --oneline    # review commits"
log "  git push                              # push if happy"

# Red gate = failed run: nonzero exit so the nightly scheduler surfaces it.
if [[ "$GATE_STATUS" == "red" ]]; then
    exit 4
fi
