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

# Resolve a pytest runner for the scoped gate (#57 57.2). The headless overnight
# shell does not auto-activate a venv, so bare `pytest` is often off PATH on mba —
# that would turn a green change red (command-not-found). Prefer the repo venv,
# then a PATH pytest, then `uv run`. Empty means "cannot verify" → gate fails loud.
PYTEST_CMD=""
if [[ -x "$REPO_ROOT/.venv/bin/pytest" ]]; then
    PYTEST_CMD="$REPO_ROOT/.venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST_CMD="pytest"
elif command -v uv >/dev/null 2>&1; then
    PYTEST_CMD="uv run pytest"
fi

# Per-iteration model routing. Set RALPH_ROUTER=0 to disable (always use $DEFAULT_MODEL).
RALPH_ROUTER="${RALPH_ROUTER:-1}"
DEFAULT_MODEL="${RALPH_DEFAULT_MODEL:-sonnet}"
ROUTER_MODEL="${RALPH_ROUTER_MODEL:-sonnet}"
ROUTER_BUDGET_USD="${RALPH_ROUTER_BUDGET_USD:-0.50}"

# Independent reviewer pass (#57 57.5 — maker ≠ checker). Set RALPH_REVIEWER=0 to
# disable. Runs after the scoped gate is green, on a fixed capable model (not the
# router) so the "no" is consistent and independent of the worker's model.
RALPH_REVIEWER="${RALPH_REVIEWER:-1}"
REVIEWER_MODEL="${RALPH_REVIEWER_MODEL:-sonnet}"
REVIEWER_BUDGET_USD="${RALPH_REVIEWER_BUDGET_USD:-1.00}"
REVIEW_TEMPLATE="$SCRIPT_DIR/prompts/review-task.md"

# Goal stop-condition checker (#57 57.7 — the "/goal" pattern). The STOP decision
# for a single-issue run is owned by a checker, NOT the worker's prose self-report:
# a separate `claude -p` (sonnet, fixed model — independent of the worker's router
# choice, like the 57.5 reviewer) re-checks the focus file's machine-evaluable
# `## Acceptance` block (#57 57.6) against the repo state — each accepted iteration
# and on the worker's no-tasks claim — and emits GOAL_MET: YES|NO. The loop stops
# only when the stated done-condition actually holds. Set RALPH_GOALCHECK=0 to
# disable (revert to trusting the worker's no-tasks cue).
RALPH_GOALCHECK="${RALPH_GOALCHECK:-1}"
GOALCHECK_MODEL="${RALPH_GOALCHECK_MODEL:-sonnet}"
GOALCHECK_BUDGET_USD="${RALPH_GOALCHECK_BUDGET_USD:-0.50}"
GOALCHECK_TEMPLATE="$SCRIPT_DIR/prompts/goal-check.md"

# Plan-readiness pre-flight gate (#57 57.13 — verify the INPUT, symmetric to the
# 57.2/57.5 gates on the output). Before a LONG autonomous run starts, enforce the
# Definition-of-Ready: a perfect verification backbone cannot rescue a badly-scoped
# issue (garbage in, garbage out). Applied DIFFERENTIALLY by run length (the #57
# anti-bureaucracy scaling rule) — short reversible runs skip it:
#   MAX_ITERS <  FIELD_MIN              → soft tier: skipped (small reversible work).
#   FIELD_MIN ≤ MAX_ITERS < REVIEW_MIN  → fields tier: hard DoR field checks only
#                                         (## Acceptance present, Reversibility=a).
#   MAX_ITERS ≥ REVIEW_MIN OR overnight → full tier: fields + an independent
#                                         /ready-check (claude -p) READY verdict.
# A NOT-READY verdict or a missing hard field blocks the run START: append a
# ## BLOCKER, withhold the branch (exit 8 — symmetric to 57.3). Set RALPH_READYCHECK=0
# to disable. overnight.sh sets RALPH_OVERNIGHT=1 to force the full tier.
RALPH_READYCHECK="${RALPH_READYCHECK:-1}"
READYCHECK_MODEL="${RALPH_READYCHECK_MODEL:-sonnet}"
READYCHECK_BUDGET_USD="${RALPH_READYCHECK_BUDGET_USD:-0.50}"
READYCHECK_TEMPLATE="$SCRIPT_DIR/prompts/ready-check.md"
READYCHECK_FIELD_MIN_ITERS="${RALPH_READYCHECK_FIELD_MIN_ITERS:-10}"
READYCHECK_REVIEW_MIN_ITERS="${RALPH_READYCHECK_REVIEW_MIN_ITERS:-30}"

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

# ── Scoped post-iteration test gate (#57 — loop verification backbone, 57.2).
# After a "done" iteration commits, run ONLY the suites relevant to the changed
# top-level scope — diff-level, not whole-repo (TDAD: targeted > whole-suite).
# This is the enforced "something that can say no": prompt-only test guidance is
# not enough, so the harness itself re-runs the relevant tests and refuses to
# advance on red. Sets two globals read by the caller:
#   GATE_KIND           — human label of which suites ran (backend/ios/…)
#   GATE_SNAPSHOT_ONLY  — 1 when an iOS failure is only .stableDump snapshot
#                         drift (a re-record signal, not a logic break — #57
#                         verification altitude); best-effort heuristic.
# Returns 0 green (or no gate-relevant changes), 1 red.
scoped_gate() {
    local pre="$1" post="$2"
    local changed rc=0
    changed="$(git -C "$REPO_ROOT" diff --name-only "$pre..$post")"
    GATE_KIND=""
    GATE_SNAPSHOT_ONLY=0

    # Backend (quiz-agent) — shared Pydantic models feed it, so packages/shared
    # changes gate here too (Rule #5: read the immediate callers).
    if echo "$changed" | grep -qE '^(apps/quiz-agent/|packages/shared/)'; then
        GATE_KIND="backend"
        if [[ -z "$PYTEST_CMD" ]]; then
            log "  ✗ scoped gate RED (backend) — no pytest runner found; cannot verify"
            rc=1
        else
            local glog="$LOG_DIR/gate-$START_TS-$(printf '%02d' "$iter")-backend.log"
            set +e
            (cd "$REPO_ROOT/apps/quiz-agent" && $PYTEST_CMD tests/ -q) > "$glog" 2>&1
            local brc=$?
            set -e
            if [[ $brc -ne 0 ]]; then log "  ✗ scoped gate RED (backend, exit=$brc) — $glog"; rc=1; fi
        fi
    fi

    # quiz-pack-api (order/generation) — its own suite.
    if echo "$changed" | grep -qE '^apps/quiz-pack-api/'; then
        GATE_KIND="${GATE_KIND:+$GATE_KIND+}quiz-pack-api"
        if [[ -z "$PYTEST_CMD" ]]; then
            log "  ✗ scoped gate RED (quiz-pack-api) — no pytest runner found; cannot verify"
            rc=1
        else
            local glog="$LOG_DIR/gate-$START_TS-$(printf '%02d' "$iter")-qpack.log"
            set +e
            (cd "$REPO_ROOT/apps/quiz-pack-api" && $PYTEST_CMD tests/ -q) > "$glog" 2>&1
            local prc=$?
            set -e
            if [[ $prc -ne 0 ]]; then log "  ✗ scoped gate RED (quiz-pack-api, exit=$prc) — $glog"; rc=1; fi
        fi
    fi

    # iOS — flow/state/structure suite only (HangsTests = ViewInspector +
    # state dumps). NOT pixel/.pen design-fidelity (#57 verification altitude):
    # the design is still moving, so 1:1-with-.pen would trip on cosmetic drift.
    # RS click-through UI tests are too slow/flaky for a per-iteration gate;
    # push-CI + the end-of-run gate cover them.
    if echo "$changed" | grep -qE '^apps/ios-app/'; then
        GATE_KIND="${GATE_KIND:+$GATE_KIND+}ios"
        local glog="$LOG_DIR/gate-$START_TS-$(printf '%02d' "$iter")-ios.log"
        local gt=""
        if command -v gtimeout >/dev/null 2>&1; then gt="gtimeout 2400"
        elif command -v timeout >/dev/null 2>&1; then gt="timeout 2400"; fi
        set +e
        (cd "$REPO_ROOT/apps/ios-app/Hangs" && $gt xcodebuild test \
            -scheme Hangs-Local \
            -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
            -only-testing:HangsTests \
            -quiet) > "$glog" 2>&1
        local irc=$?
        set -e
        if [[ $irc -ne 0 ]]; then
            # Re-record signal vs real break: if the only failure markers are
            # snapshot dumps (no XCTAssert/compile/fatal), it's intentional-UI
            # drift to be re-recorded by a human, not silently auto-fixed.
            if grep -qiE 'stableDump|snapshot' "$glog" \
               && ! grep -qE 'XCTAssert|error:|Fatal error|Compilation failed' "$glog"; then
                GATE_SNAPSHOT_ONLY=1
                log "  ✗ scoped gate RED (ios, exit=$irc) — snapshot drift, needs human re-record — $glog"
            else
                log "  ✗ scoped gate RED (ios, exit=$irc) — $glog"
            fi
            rc=1
        fi
    fi

    if [[ -z "$GATE_KIND" ]]; then
        log "  scoped gate: no gate-relevant changes — skipped"
    elif [[ $rc -eq 0 ]]; then
        log "  ✓ scoped gate GREEN ($GATE_KIND)"
    fi
    return $rc
}

# Append a machine-written ## BLOCKER to the focus file when a gate refuses an
# otherwise-"done" iteration, and commit it so it travels with the branch. The
# bad commit is kept (not reverted) for human review on the throwaway branch —
# reverting risks an infinite redo loop and discards salvageable work.
append_gate_blocker() {
    local d kind extra head
    d="$(date +%F)"
    kind="${GATE_KIND:-unknown}"
    head="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
    extra=""
    [[ "$GATE_SNAPSHOT_ONLY" == "1" ]] && extra=" The failing assertions are snapshot (.stableDump) drift — if the UI change was intentional, re-record the snapshot by hand; do NOT auto-edit it."
    {
        printf '\n## BLOCKER (%s) — automated test gate (%s)\n\n' "$d" "$kind"
        printf -- '- The post-iteration scoped test gate failed after iteration %s committed `%s` (reported task: %s).\n' "$iter" "$head" "$TASK"
        printf -- '- The change is on this branch but the relevant **%s** suite is RED, so the run halted and the branch was NOT pushed.%s\n' "$kind" "$extra"
        printf -- '- Next human-touch: read the gate log under `scripts/ralph/logs/gate-%s-*`, fix or revert the commit, then re-run.\n' "$START_TS"
    } >> "$REPO_ROOT/$FOCUS_FILE"
    git -C "$REPO_ROOT" add "$FOCUS_FILE"
    git -C "$REPO_ROOT" commit -m "chore(ralph): #57 gate-red BLOCKER on $(basename "$FOCUS_FILE")" >/dev/null 2>&1 || true
    log "  appended ## BLOCKER to $FOCUS_FILE"
}

# ── Independent reviewer pass (#57 — loop verification backbone, 57.5).
# The scoped gate proves the tests pass; it does NOT prove the change actually
# meets its acceptance criteria (maker = checker is the whole problem). So after
# the gate is GREEN, a SEPARATE `claude -p` — fresh context, no memory of how the
# change was made — sees ONLY the iteration's diff + the focus file's acceptance,
# and is prompted to flag *only* correctness / stated-requirement gaps (Anthropic:
# reviewers over-report, so constrain them). Returns PASS / CONCERNS.
#   - PASS                → accept the iteration.
#   - CONCERNS            → block acceptance (the change misses its acceptance).
#   - no parseable verdict / template missing → block too: "could not confirm"
#     is not "confirmed" (fail loud, same stance as the gate's missing-pytest).
# Sets REVIEW_REASON (one line, for the BLOCKER note). Returns 0 PASS, 1 otherwise.
reviewer_pass() {
    local pre="$1" post="$2"
    REVIEW_REASON=""
    if [[ "$RALPH_REVIEWER" != "1" ]]; then
        log "  reviewer: disabled (RALPH_REVIEWER=0) — skipped"
        return 0
    fi
    if [[ ! -f "$REVIEW_TEMPLATE" ]]; then
        REVIEW_REASON="reviewer prompt template missing ($REVIEW_TEMPLATE)"
        log "  ✗ reviewer RED — $REVIEW_REASON (cannot confirm acceptance)"
        return 1
    fi

    # Write the exact iteration diff to a file so the reviewer sees ONLY the diff
    # (+ the focus file's acceptance), not the worker's reasoning trail.
    local diff_file="$LOG_DIR/review-$START_TS-$(printf '%02d' "$iter").diff"
    local rlog="$LOG_DIR/review-$START_TS-$(printf '%02d' "$iter").log"
    git -C "$REPO_ROOT" diff "$pre..$post" > "$diff_file" 2>/dev/null

    local rprompt
    rprompt="$(sed -e "s|__FOCUS_FILE__|$FOCUS_FILE|g" -e "s|__DIFF_FILE__|$diff_file|g" "$REVIEW_TEMPLATE")"
    set +e
    claude \
        -p "Review the diff at $diff_file against the acceptance criteria in $FOCUS_FILE. End with the REVIEW_VERDICT line." \
        --model "$REVIEWER_MODEL" \
        --permission-mode bypassPermissions \
        --allowed-tools "Read" "Grep" "Glob" \
        --max-budget-usd "$REVIEWER_BUDGET_USD" \
        --no-session-persistence \
        --append-system-prompt "$rprompt" \
        > "$rlog" 2>&1
    set -e

    local verdict
    verdict="$(grep -oE 'REVIEW_VERDICT:[[:space:]]*(PASS|CONCERNS)' "$rlog" | tail -1 | sed -E 's/REVIEW_VERDICT:[[:space:]]*//' || true)"
    if [[ "$verdict" == "PASS" ]]; then
        log "  ✓ reviewer PASS"
        return 0
    elif [[ "$verdict" == "CONCERNS" ]]; then
        REVIEW_REASON="$(grep -oE 'REVIEW_VERDICT:[[:space:]]*CONCERNS.*' "$rlog" | tail -1 | sed -E 's/REVIEW_VERDICT:[[:space:]]*CONCERNS[[:space:]]*[—-]*[[:space:]]*//' || true)"
        [[ -z "$REVIEW_REASON" ]] && REVIEW_REASON="see $rlog"
        log "  ✗ reviewer CONCERNS — $REVIEW_REASON ($rlog)"
        return 1
    else
        REVIEW_REASON="reviewer produced no parseable REVIEW_VERDICT (see $rlog)"
        log "  ✗ reviewer RED — $REVIEW_REASON"
        return 1
    fi
}

# Append a machine-written ## BLOCKER when the independent reviewer (57.5) refuses
# an otherwise gate-green iteration, and commit it so it travels with the branch.
append_review_blocker() {
    local d head
    d="$(date +%F)"
    head="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
    {
        printf '\n## BLOCKER (%s) — independent reviewer (CONCERNS)\n\n' "$d"
        printf -- '- The independent reviewer pass (maker ≠ checker, #57 57.5) returned **CONCERNS** for iteration %s (`%s`, reported task: %s).\n' "$iter" "$head" "$TASK"
        printf -- '- The scoped test gate was GREEN, but the change does not clearly meet its acceptance criteria: %s\n' "${REVIEW_REASON:-see reviewer log}"
        printf -- '- The commit is on this branch but NOT accepted; the run halted and the branch was NOT pushed.\n'
        printf -- '- Next human-touch: read the reviewer log under `scripts/ralph/logs/review-%s-*`, address the concern (or override if it is a false positive), then re-run.\n' "$START_TS"
    } >> "$REPO_ROOT/$FOCUS_FILE"
    git -C "$REPO_ROOT" add "$FOCUS_FILE"
    git -C "$REPO_ROOT" commit -m "chore(ralph): #57 reviewer CONCERNS BLOCKER on $(basename "$FOCUS_FILE")" >/dev/null 2>&1 || true
    log "  appended ## BLOCKER (reviewer) to $FOCUS_FILE"
}

# ── Goal stop-condition checker (#57 — loop verification backbone, 57.7).
# Steinberger's "/goal" pattern: the loop "cannot mark the issue done unless the
# acceptance criteria are met." The worker reporting `no-tasks` (or running out of
# checkboxes) is a *request* to stop, not the authority to — maker = checker on the
# STOP decision is the same flaw 57.5 fixes on the work. So a SEPARATE `claude -p` on
# a fixed model (sonnet, fresh context, read-only) reads the focus file's machine-evaluable
# `## Acceptance` block (#57 57.6) + the repo state and decides whether the stated
# done-condition actually holds, emitting GOAL_MET: YES|NO. It is told to bias to NO
# when unsure — a false NO just keeps the (human-reviewed) loop working; a false YES
# would stop early.
#   - YES                       → goal met, the run may stop cleanly.
#   - NO / unparseable verdict   → not confirmed done (fail loud, same stance as the
#                                  reviewer's "could not confirm" ≠ "confirmed").
#   - no `## Acceptance` in focus → nothing machine-evaluable to gate on; accept the
#                                  worker's stop signal (backward-compat for queue /
#                                  legacy focus files), logged.
#   - disabled / template missing → see below.
# Sets GOAL_REASON (one line). Returns 0 = may-stop, 1 = not-done.
goal_check() {
    GOAL_REASON=""
    if [[ "$RALPH_GOALCHECK" != "1" ]]; then
        log "  goalcheck: disabled (RALPH_GOALCHECK=0) — trusting worker stop signal"
        return 0
    fi
    # Nothing to evaluate if the focus file carries no machine-evaluable acceptance
    # block (queue files, not-yet-standardized issues). Don't fail a run we cannot
    # judge — that would block every legacy focus file.
    if ! grep -qE '^## Acceptance[[:space:]]*$' "$REPO_ROOT/$FOCUS_FILE"; then
        log "  goalcheck: no '## Acceptance' block in $FOCUS_FILE — accepting worker stop signal"
        return 0
    fi
    if [[ ! -f "$GOALCHECK_TEMPLATE" ]]; then
        GOAL_REASON="goal-check prompt template missing ($GOALCHECK_TEMPLATE)"
        log "  ✗ goalcheck RED — $GOAL_REASON (cannot confirm done)"
        return 1
    fi

    local glog="$LOG_DIR/goal-$START_TS-$(printf '%02d' "$iter").log"
    local gprompt
    gprompt="$(sed "s|__FOCUS_FILE__|$FOCUS_FILE|g" "$GOALCHECK_TEMPLATE")"
    set +e
    claude \
        -p "Check whether the ## Acceptance criteria in $FOCUS_FILE are met by the current repo state. End with the GOAL_MET line." \
        --model "$GOALCHECK_MODEL" \
        --permission-mode bypassPermissions \
        --allowed-tools "Read" "Grep" "Glob" \
        --max-budget-usd "$GOALCHECK_BUDGET_USD" \
        --no-session-persistence \
        --append-system-prompt "$gprompt" \
        > "$glog" 2>&1
    set -e

    local verdict
    verdict="$(grep -oE 'GOAL_MET:[[:space:]]*(YES|NO)' "$glog" | tail -1 | sed -E 's/GOAL_MET:[[:space:]]*//' || true)"
    if [[ "$verdict" == "YES" ]]; then
        log "  ✓ goalcheck: GOAL_MET — ## Acceptance satisfied"
        return 0
    elif [[ "$verdict" == "NO" ]]; then
        GOAL_REASON="$(grep -oE 'GOAL_MET:[[:space:]]*NO.*' "$glog" | tail -1 | sed -E 's/GOAL_MET:[[:space:]]*NO[[:space:]]*[—-]*[[:space:]]*//' || true)"
        [[ -z "$GOAL_REASON" ]] && GOAL_REASON="see $glog"
        log "  ✗ goalcheck: GOAL_MET=NO — $GOAL_REASON ($glog)"
        return 1
    else
        GOAL_REASON="goal-check produced no parseable GOAL_MET verdict (see $glog)"
        log "  ✗ goalcheck RED — $GOAL_REASON"
        return 1
    fi
}

# Append a ## BLOCKER when the worker requested a stop (no-tasks) but the goal
# checker found the `## Acceptance` criteria unmet — the loop must not silently
# exit "clean" on an unfinished issue (#57: "a loop that silently stops running is
# not a loop"). Committed so it travels with the branch.
append_goal_blocker() {
    local d
    d="$(date +%F)"
    {
        printf '\n## BLOCKER (%s) — goal not met (## Acceptance unsatisfied)\n\n' "$d"
        printf -- '- The worker reported no remaining tasks, but the independent goal check (#57 57.7) found the `## Acceptance` criteria are NOT all met: %s\n' "${GOAL_REASON:-see goal-check log}"
        printf -- '- The run halted instead of exiting "clean" on an unfinished issue; the branch was NOT pushed.\n'
        printf -- '- Next human-touch: read the goal-check log under `scripts/ralph/logs/goal-%s-*`, finish the unmet criteria (or correct the `## Acceptance` block / override if it is a false negative), then re-run.\n' "$START_TS"
    } >> "$REPO_ROOT/$FOCUS_FILE"
    git -C "$REPO_ROOT" add "$FOCUS_FILE"
    git -C "$REPO_ROOT" commit -m "chore(ralph): #57 goal-unmet BLOCKER on $(basename "$FOCUS_FILE")" >/dev/null 2>&1 || true
    log "  appended ## BLOCKER (goal) to $FOCUS_FILE"
}

# ── Plan-readiness pre-flight gate (#57 — loop verification backbone, 57.13).
# Verifies the INPUT before the run starts (symmetric to 57.2/57.5 on the output).
# Tier is chosen by run length (the differential scaling rule). Sets PREFLIGHT_REASON
# (one line, for the BLOCKER note). Returns 0 ready/skip, 1 not-ready.
readiness_preflight() {
    PREFLIGHT_REASON=""
    if [[ "$RALPH_READYCHECK" != "1" ]]; then
        log "  readiness: disabled (RALPH_READYCHECK=0) — skipped"
        return 0
    fi

    # Differential tier from run length (+ overnight forces full). Below the field
    # threshold a run is short/reversible — skip the gate (anti-bureaucracy).
    local tier="soft"
    if [[ "${RALPH_OVERNIGHT:-0}" == "1" || "$MAX_ITERS" -ge "$READYCHECK_REVIEW_MIN_ITERS" ]]; then
        tier="full"
    elif [[ "$MAX_ITERS" -ge "$READYCHECK_FIELD_MIN_ITERS" ]]; then
        tier="fields"
    fi
    if [[ "$tier" == "soft" ]]; then
        log "  readiness: short run (iters=$MAX_ITERS < $READYCHECK_FIELD_MIN_ITERS) — soft tier, gate skipped"
        return 0
    fi
    log "  readiness pre-flight: $tier tier (iters=$MAX_ITERS, overnight=${RALPH_OVERNIGHT:-0})"

    # Hard DoR field checks — cheap, no model. C3: a machine-evaluable ## Acceptance
    # block must exist; the whole verification backbone reads it. C6: a Reversibility
    # class must be declared, and the autonomous loop only runs class `a` (b/c need a
    # human checkpoint).
    if ! grep -qE '^## Acceptance[[:space:]]*$' "$REPO_ROOT/$FOCUS_FILE"; then
        PREFLIGHT_REASON="no machine-evaluable '## Acceptance' block in the issue (C3) — nothing falsifiable for the loop to stop on"
        log "  ✗ readiness RED — $PREFLIGHT_REASON"
        return 1
    fi
    local rev
    rev="$(grep -oiE '^\*\*Reversibility:\*\*[[:space:]]*[abc]' "$REPO_ROOT/$FOCUS_FILE" | tail -1 | grep -oiE '[abc]$' | tr 'A-Z' 'a-z' || true)"
    if [[ -z "$rev" ]]; then
        PREFLIGHT_REASON="no '**Reversibility:**' class declared in the issue header (C6 undeclared)"
        log "  ✗ readiness RED — $PREFLIGHT_REASON"
        return 1
    fi
    if [[ "$rev" != "a" ]]; then
        PREFLIGHT_REASON="reversibility class '$rev' (schema/data migration or auth·payment·prod-deploy) is excluded from unattended runs (C6) — needs a human checkpoint"
        log "  ✗ readiness RED — $PREFLIGHT_REASON"
        return 1
    fi

    if [[ "$tier" != "full" ]]; then
        log "  ✓ readiness GREEN (fields tier: ## Acceptance present, reversibility=a)"
        return 0
    fi

    # Full tier — an independent /ready-check (maker ≠ checker on the input): a
    # SEPARATE claude -p (fixed model, fresh context) that sees ONLY the issue plan
    # and tries to DISPROVE autonomous-executability. NOT-READY / unparseable blocks.
    if [[ ! -f "$READYCHECK_TEMPLATE" ]]; then
        PREFLIGHT_REASON="ready-check prompt template missing ($READYCHECK_TEMPLATE)"
        log "  ✗ readiness RED — $PREFLIGHT_REASON (cannot confirm ready)"
        return 1
    fi
    local rclog="$LOG_DIR/ready-$START_TS.log"
    local rcprompt
    rcprompt="$(sed "s|__ISSUE_FILE__|$FOCUS_FILE|g" "$READYCHECK_TEMPLATE")"
    set +e
    claude \
        -p "Plan-readiness review of $FOCUS_FILE. Try to disprove it is autonomously executable. End with the READY_VERDICT line." \
        --model "$READYCHECK_MODEL" \
        --permission-mode bypassPermissions \
        --allowed-tools "Read" "Grep" "Glob" \
        --max-budget-usd "$READYCHECK_BUDGET_USD" \
        --no-session-persistence \
        --append-system-prompt "$rcprompt" \
        > "$rclog" 2>&1
    set -e

    local verdict
    verdict="$(grep -oE 'READY_VERDICT:[[:space:]]*(READY|NOT-READY)' "$rclog" | tail -1 | sed -E 's/READY_VERDICT:[[:space:]]*//' || true)"
    if [[ "$verdict" == "READY" ]]; then
        log "  ✓ readiness GREEN (full tier: /ready-check READY)"
        return 0
    elif [[ "$verdict" == "NOT-READY" ]]; then
        PREFLIGHT_REASON="$(grep -oE 'READY_VERDICT:[[:space:]]*NOT-READY.*' "$rclog" | tail -1 | sed -E 's/READY_VERDICT:[[:space:]]*NOT-READY[[:space:]]*[—-]*[[:space:]]*//' || true)"
        [[ -z "$PREFLIGHT_REASON" ]] && PREFLIGHT_REASON="see $rclog"
        log "  ✗ readiness NOT-READY — $PREFLIGHT_REASON ($rclog)"
        return 1
    else
        PREFLIGHT_REASON="ready-check produced no parseable READY_VERDICT (see $rclog)"
        log "  ✗ readiness RED — $PREFLIGHT_REASON"
        return 1
    fi
}

# Append a ## BLOCKER when the readiness pre-flight refuses to START a run (#57 57.13).
# Committed so it travels with the (withheld) branch, like the other gate blockers.
append_preflight_blocker() {
    local d
    d="$(date +%F)"
    {
        printf '\n## BLOCKER (%s) — plan-readiness pre-flight (NOT-READY)\n\n' "$d"
        printf -- '- The readiness gate (#57 57.13) refused to start an autonomous run on this issue: %s\n' "${PREFLIGHT_REASON:-see ready-check log}"
        printf -- '- No iteration ran; the branch was NOT pushed. Verifying the loop output cannot rescue an unready input (garbage in, garbage out).\n'
        printf -- '- Next human-touch: clear the Definition-of-Ready (`/triage` C1–C7: add the `## Acceptance` block, declare `**Reversibility:**`, run `/ready-check`), then re-run. Override only by setting `RALPH_READYCHECK=0` for a deliberate exception.\n'
    } >> "$REPO_ROOT/$FOCUS_FILE"
    git -C "$REPO_ROOT" add "$FOCUS_FILE"
    git -C "$REPO_ROOT" commit -m "chore(ralph): #57 readiness-NOT-READY BLOCKER on $(basename "$FOCUS_FILE")" >/dev/null 2>&1 || true
    log "  appended ## BLOCKER (readiness) to $FOCUS_FILE"
}

# Build the system prompt (substitute focus file path)
SYSTEM_PROMPT="$(sed "s|__FOCUS_FILE__|$FOCUS_FILE|g" "$PROMPT_TEMPLATE")"

# Pre-flight readiness gate — runs ONCE before any iteration (#57 57.13). A NOT-READY
# input halts before the run starts: append the BLOCKER, withhold the branch (exit 8).
if ! readiness_preflight; then
    append_preflight_blocker
    log "✗ plan-readiness pre-flight NOT-READY — refusing to start the run (exit 8)"
    exit 8
fi

for iter in $(seq 1 "$MAX_ITERS"); do
    ITER_LOG="$LOG_DIR/iter-$START_TS-$(printf '%02d' "$iter").log"
    log "─── iteration $iter/$MAX_ITERS → $ITER_LOG"

    PRE_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"

    # ── Router pre-pass: a cheap read-only call (sonnet) picks the model for THIS iteration.
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
            --model "$ROUTER_MODEL" \
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
            # Enforced verification (#57 57.2): a "done" iteration that committed
            # code must pass the scoped gate before it counts. The gate, not the
            # agent's self-report, decides success.
            if [[ "$PRE_SHA" != "$POST_SHA" ]]; then
                if scoped_gate "$PRE_SHA" "$POST_SHA"; then
                    # Gate is green (tests pass). Now the independent reviewer
                    # (#57 57.5) checks the diff against its acceptance criteria —
                    # a green gate does not prove the change met its requirements.
                    if reviewer_pass "$PRE_SHA" "$POST_SHA"; then
                        COMPLETED=$((COMPLETED + 1))
                        CONSECUTIVE_FAILS=0
                    else
                        CONSECUTIVE_FAILS=$((CONSECUTIVE_FAILS + 1))
                        append_review_blocker
                        log "✗ independent reviewer CONCERNS on a gate-green iteration — halting run for human review (exit 6)"
                        exit 6
                    fi
                else
                    CONSECUTIVE_FAILS=$((CONSECUTIVE_FAILS + 1))
                    append_gate_blocker
                    log "✗ scoped gate RED on a 'done' iteration — halting run for human review (exit 5)"
                    exit 5
                fi
            else
                # "done" with no commit (e.g. doc reconcile) — nothing to gate.
                COMPLETED=$((COMPLETED + 1))
                CONSECUTIVE_FAILS=0
            fi
            ;;
        no-tasks)
            # The worker requests a stop. The goal checker — not the worker's
            # prose self-report — decides whether the issue is actually done
            # (#57 57.7). On an unmet goal the loop fails loud rather than exiting
            # "clean" on an unfinished issue.
            if goal_check; then
                log "✓ goal stop-condition met (no-tasks + ## Acceptance satisfied) — exiting cleanly"
                break
            else
                CONSECUTIVE_FAILS=$((CONSECUTIVE_FAILS + 1))
                append_goal_blocker
                log "✗ worker reported no-tasks but ## Acceptance is NOT met — halting for human review (exit 7)"
                exit 7
            fi
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

    # Goal stop-condition (#57 57.7): after a genuinely-accepted "done" iteration
    # (gate GREEN + reviewer PASS), re-check whether the issue's ## Acceptance is now
    # fully met — stop the moment the stated goal holds rather than looping until the
    # worker happens to report no-tasks. A "done" that passed both checks leaves
    # CONSECUTIVE_FAILS at 0; gate-red / reviewer-CONCERNS already exited above.
    if [[ "$STATUS" == "done" && $CONSECUTIVE_FAILS -eq 0 ]]; then
        if goal_check; then
            log "✓ goal stop-condition met (## Acceptance satisfied) — exiting cleanly"
            break
        fi
    fi

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
        # Document the block in the focus file so the chain (#57 57.3) and the
        # human both see why the branch is unpushable.
        {
            printf '\n## BLOCKER (%s) — end-of-run iOS test gate\n\n' "$(date +%F)"
            printf -- '- The HangsTests unit suite is RED at the end of this run; the run touched `apps/ios-app/` so the branch is NOT pushable.\n'
            printf -- '- Next human-touch: read the gate log `%s`, fix the failure, then re-run.\n' "$GATE_LOG"
        } >> "$REPO_ROOT/$FOCUS_FILE"
        git -C "$REPO_ROOT" add "$FOCUS_FILE" >/dev/null 2>&1 || true
        git -C "$REPO_ROOT" commit -m "chore(ralph): #57 end-gate BLOCKER on $(basename "$FOCUS_FILE")" >/dev/null 2>&1 || true
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
