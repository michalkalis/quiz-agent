#!/usr/bin/env bash
# Ralph Overnight — chain multiple issues through ralph.sh on a throwaway branch.
#
# Usage:
#   scripts/ralph/overnight.sh [focus-file ...]
#
# With no args it reads the priority queue at docs/issues/overnight-queue.md
# (the triage output). With args, each positional is a focus file run at the
# default iteration cap — handy for dry-runs:
#   scripts/ralph/overnight.sh docs/issues/issue-49-daily-limit-cost-research.md
#
# What it does:
#   1. Preflight: clean tree, on main, ff-only pull, single-instance lock.
#   2. Cuts a ralph/overnight-YYYYMMDD-HHMM branch — every iteration commit lands
#      here, so main on this machine stays clean.
#   3. Runs ralph.sh per focus file sequentially, honoring a global time budget.
#   4. Generates a consolidated self-contained HTML report and commits it.
#   5. Pushes the ralph/* branch (and ONLY a ralph/* branch) to origin.
#   6. Returns to main and prints the laptop follow-up.
#
# Push is restricted to ralph/* — main is never pushed by this script.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT_DIR="$REPO_ROOT/scripts/ralph"
RALPH="$SCRIPT_DIR/ralph.sh"
QUEUE_FILE="${OVERNIGHT_QUEUE:-$REPO_ROOT/docs/issues/overnight-queue.md}"
REPORT_TEMPLATE="$SCRIPT_DIR/prompts/report.md"
LOG_DIR="$SCRIPT_DIR/logs"
LOCK_DIR="$SCRIPT_DIR/.overnight.lock"

DEFAULT_ITERS="${OVERNIGHT_DEFAULT_ITERS:-12}"
# Global wall-clock budget for the whole run. ~6h leaves margin before morning.
MAX_SECONDS="${OVERNIGHT_MAX_SECONDS:-21600}"

mkdir -p "$LOG_DIR"

# ── Single-instance lock (atomic mkdir; works without flock on macOS).
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "[overnight] another run holds the lock at $LOCK_DIR — aborting." >&2
    echo "[overnight] if no run is active, remove it: rmdir '$LOCK_DIR'" >&2
    exit 4
fi
cleanup() { rmdir "$LOCK_DIR" 2>/dev/null || true; }
trap cleanup EXIT

cd "$REPO_ROOT"

# ── Preflight.
if [[ -n "$(git status --porcelain)" ]]; then
    echo "[overnight] working tree dirty — commit or stash first:" >&2
    git status --short >&2
    exit 3
fi

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$CURRENT_BRANCH" != "main" ]]; then
    echo "[overnight] must start from main (on '$CURRENT_BRANCH') — aborting." >&2
    exit 3
fi

echo "[overnight] pulling main (ff-only)…"
git pull --ff-only

if ! command -v claude >/dev/null 2>&1; then
    echo "[overnight] claude CLI not on PATH — aborting." >&2
    exit 5
fi

# ── Build the work list: positional args win, else parse the queue file.
#    Queue format (one per line, '#'/blank ignored, leading '- ' bullet stripped):
#        docs/issues/issue-44-screenshot-verify.md | 8
#        docs/issues/issue-45-pencil-theme.md            # iters omitted → default
declare -a FOCUS_FILES=()
declare -a FOCUS_ITERS=()

add_focus() {
    local path="$1" iters="$2"
    [[ -z "$iters" ]] && iters="$DEFAULT_ITERS"
    if [[ ! -f "$REPO_ROOT/$path" && ! -f "$path" ]]; then
        echo "[overnight] WARNING: focus file not found, skipping: $path" >&2
        return
    fi
    FOCUS_FILES+=("$path")
    FOCUS_ITERS+=("$iters")
}

if [[ $# -gt 0 ]]; then
    for f in "$@"; do add_focus "$f" ""; done
else
    if [[ ! -f "$QUEUE_FILE" ]]; then
        echo "[overnight] no focus files given and queue missing: $QUEUE_FILE" >&2
        echo "[overnight] run triage to produce the queue, or pass focus files as args." >&2
        exit 2
    fi
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"          # ltrim
        line="${line%"${line##*[![:space:]]}"}"          # rtrim
        [[ -z "$line" || "$line" == \#* ]] && continue
        line="${line#- }"                                # strip markdown bullet
        path="${line%%|*}"
        iters=""
        if [[ "$line" == *"|"* ]]; then iters="${line#*|}"; fi
        # trim path + iters
        path="${path#"${path%%[![:space:]]*}"}"; path="${path%"${path##*[![:space:]]}"}"
        iters="${iters//[!0-9]/}"
        [[ -z "$path" ]] && continue
        add_focus "$path" "$iters"
    done < "$QUEUE_FILE"
fi

if [[ ${#FOCUS_FILES[@]} -eq 0 ]]; then
    echo "[overnight] queue resolved to zero runnable focus files — nothing to do." >&2
    exit 2
fi

# ── Cut the throwaway branch.
TS="$(date +%Y%m%d-%H%M)"
BRANCH="ralph/overnight-$TS"
BASE_SHA="$(git rev-parse HEAD)"
git checkout -b "$BRANCH"

RUN_LOG="$LOG_DIR/overnight-$TS.log"
log() { echo "[overnight $(date +%H:%M:%S)] $*" | tee -a "$RUN_LOG"; }

log "branch:      $BRANCH"
log "base sha:    $BASE_SHA"
log "queue:       ${#FOCUS_FILES[@]} focus file(s)"
log "time budget: ${MAX_SECONDS}s"

START_EPOCH="$(date +%s)"
DEADLINE=$((START_EPOCH + MAX_SECONDS))

for i in "${!FOCUS_FILES[@]}"; do
    focus="${FOCUS_FILES[$i]}"
    iters="${FOCUS_ITERS[$i]}"
    now="$(date +%s)"
    remaining=$((DEADLINE - now))
    if [[ $remaining -le 60 ]]; then
        log "⏱ time budget exhausted (${remaining}s left) — stopping before $focus"
        break
    fi
    log "─── focus $((i + 1))/${#FOCUS_FILES[@]}: $focus (iters=$iters, ${remaining}s left)"

    TIMEOUT_CMD=""
    if command -v gtimeout >/dev/null 2>&1; then
        TIMEOUT_CMD="gtimeout ${remaining}s"
    elif command -v timeout >/dev/null 2>&1; then
        TIMEOUT_CMD="timeout ${remaining}s"
    fi

    set +e
    $TIMEOUT_CMD "$RALPH" "$focus" "$iters"
    rc=$?
    set -e
    log "    ralph.sh exit=$rc for $focus"
done

# ── Consolidated report.
COMMITS="$(git rev-list --count "$BASE_SHA..HEAD" 2>/dev/null || echo 0)"
log "─── run finished: $COMMITS commit(s) on $BRANCH"

REPORT_REL="docs/artifacts/ralph-report-$TS.html"
REPORT_ABS="$REPO_ROOT/$REPORT_REL"
mkdir -p "$REPO_ROOT/docs/artifacts"

if [[ -f "$REPORT_TEMPLATE" ]]; then
    log "generating report → $REPORT_REL"
    REPORT_PROMPT="$(sed \
        -e "s|__REPORT_PATH__|$REPORT_REL|g" \
        -e "s|__BRANCH__|$BRANCH|g" \
        -e "s|__BASE_SHA__|$BASE_SHA|g" \
        -e "s|__RUN_TS__|$TS|g" \
        "$REPORT_TEMPLATE")"
    set +e
    claude \
        -p "Write the Ralph overnight report HTML to $REPORT_REL. Read the run logs and git history first." \
        --model haiku \
        --permission-mode bypassPermissions \
        --max-budget-usd "${OVERNIGHT_REPORT_BUDGET_USD:-1.00}" \
        --no-session-persistence \
        --append-system-prompt "$REPORT_PROMPT" \
        > "$LOG_DIR/report-$TS.log" 2>&1
    set -e
fi

if [[ ! -f "$REPORT_ABS" ]]; then
    log "⚠ report not produced by writer — emitting minimal fallback HTML"
    {
        echo "<!doctype html><meta charset=utf-8><title>Ralph $TS</title>"
        echo "<h1>Ralph overnight $TS</h1>"
        echo "<p>Branch: <code>$BRANCH</code> · commits: $COMMITS</p>"
        echo "<p>Report writer failed — see scripts/ralph/logs/report-$TS.log and overnight-$TS.log.</p>"
        echo "<pre>"
        git log "$BASE_SHA..HEAD" --oneline 2>/dev/null
        echo "</pre>"
    } > "$REPORT_ABS"
fi

# docs/artifacts/ is gitignored — force-add so the report travels with the branch.
git add -f "$REPORT_REL"
git commit -m "docs(ralph): overnight report $TS" >/dev/null 2>&1 || log "  (no report changes to commit)"

# ── Push the ralph/* branch only. Never main.
log "pushing $BRANCH to origin"
set +e
git push -u origin "$BRANCH" > "$LOG_DIR/push-$TS.log" 2>&1
push_rc=$?
set -e
if [[ $push_rc -ne 0 ]]; then
    log "⚠ push failed (rc=$push_rc) — see scripts/ralph/logs/push-$TS.log. Branch stays local."
fi

git checkout main >/dev/null 2>&1

log "─── done. On the laptop, run: scripts/ralph/morning.sh"
log "    branch:  origin/$BRANCH"
log "    report:  $REPORT_REL (on the branch)"
log "    commits: git log main..origin/$BRANCH --stat"
