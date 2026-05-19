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
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"

if [[ ! -f "$PROMPT_TEMPLATE" ]]; then
    echo "[ralph] prompt template missing: $PROMPT_TEMPLATE" >&2
    exit 2
fi

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

# Build the system prompt (substitute focus file path)
SYSTEM_PROMPT="$(sed "s|__FOCUS_FILE__|$FOCUS_FILE|g" "$PROMPT_TEMPLATE")"

for iter in $(seq 1 "$MAX_ITERS"); do
    ITER_LOG="$LOG_DIR/iter-$START_TS-$(printf '%02d' "$iter").log"
    log "─── iteration $iter/$MAX_ITERS → $ITER_LOG"

    PRE_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"

    # Run one Claude iteration. 25 min hard timeout via gtimeout if installed,
    # otherwise rely on --max-budget-usd to bound cost.
    TIMEOUT_CMD=""
    if command -v gtimeout >/dev/null 2>&1; then
        TIMEOUT_CMD="gtimeout 1500"
    elif command -v timeout >/dev/null 2>&1; then
        TIMEOUT_CMD="timeout 1500"
    fi

    set +e
    $TIMEOUT_CMD claude \
        -p "Run one Ralph iteration on $FOCUS_FILE. End with the RALPH_RESULT marker." \
        --permission-mode bypassPermissions \
        --max-budget-usd "$BUDGET_USD" \
        --fallback-model sonnet \
        --effort high \
        --no-session-persistence \
        --append-system-prompt "$SYSTEM_PROMPT" \
        > "$ITER_LOG" 2>&1
    EXIT_CODE=$?
    set -e

    POST_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"

    # Parse RALPH_RESULT from log
    RESULT_LINE="$(grep -oE 'RALPH_RESULT:\s*\{.*\}' "$ITER_LOG" | tail -1 || true)"
    if [[ -n "$RESULT_LINE" ]]; then
        STATUS="$(echo "$RESULT_LINE" | sed -E 's/.*"status":\s*"([^"]+)".*/\1/')"
        TASK="$(echo "$RESULT_LINE" | sed -E 's/.*"task":\s*"([^"]+)".*/\1/')"
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
log ""
log "Next steps (human):"
log "  git log $START_SHA..HEAD --oneline    # review commits"
log "  git push                              # push if happy"
