#!/usr/bin/env bash
# Run the frozen RS-NN regression suite (HangsUITests) on a simulator and write
# a per-run report to docs/testing/runs/RS-suite-<date>.md (#180 track D).
#
# Usage: scripts/run-rs-suite.sh [SIM_UDID]
#   SIM_UDID  simulator to use; default = first booted iPhone, else the
#             `iPhone 17 Pro` destination by name.
#
# Exit status: 0 when every scenario passed, 1 otherwise (or on build failure).
# No LLM in the loop — this is the suite the /regression skill explores with,
# frozen. Deliberately on-demand: there is no scheduled/nightly runner
# (founder 2026-09-16).

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PROJECT_DIR="$ROOT/apps/ios-app/Hangs"
RUNS_DIR="$ROOT/docs/testing/runs"
DATE=$(date +%Y-%m-%d)
REPORT="$RUNS_DIR/RS-suite-$DATE.md"
n=2
while [ -e "$REPORT" ]; do REPORT="$RUNS_DIR/RS-suite-$DATE-$n.md"; n=$((n + 1)); done

SIM="${1:-}"
if [ -z "$SIM" ]; then
    SIM=$(xcrun simctl list devices booted 2>/dev/null \
        | grep -Ei "iPhone .*\(Booted\)" | head -1 \
        | grep -oE "[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}" || true)
fi
if [ -n "$SIM" ]; then
    DEST="platform=iOS Simulator,id=$SIM"
else
    DEST="platform=iOS Simulator,name=iPhone 17 Pro"
fi

LOG=$(mktemp -t rs-suite.XXXXXX)
START=$SECONDS
echo "RS suite: destination '$DEST', log $LOG" >&2

# Every RS-NN class plus the slug-named originals; new classes must be added here.
(cd "$PROJECT_DIR" && xcodebuild test -scheme Hangs-Local -destination "$DEST" \
    -parallel-testing-enabled NO \
    -only-testing:HangsUITests/RegressionTests \
    -only-testing:HangsUITests/RSRecordingTests \
    -only-testing:HangsUITests/RSEditTests \
    -only-testing:HangsUITests/RSMCQTests \
    -only-testing:HangsUITests/RSResultTests \
    -only-testing:HangsUITests/RSPaywallTests \
    > "$LOG" 2>&1)
XC_EXIT=$?
ELAPSED=$((SECONDS - START))

TREE=$(cd "$ROOT" && git rev-parse --short HEAD 2>/dev/null || echo "?")
DIRTY=$(cd "$ROOT" && [ -n "$(git status --porcelain 2>/dev/null)" ] && echo " + WIP" || true)
PASSED=$(grep -cE "^Test Case .* passed" "$LOG" || true)
FAILED=$(grep -cE "^Test Case .* failed" "$LOG" || true)
if [ "$XC_EXIT" -eq 0 ] && [ "$FAILED" -eq 0 ] && [ "$PASSED" -gt 0 ]; then
    VERDICT="PASS"
else
    VERDICT="FAIL"
fi

{
    echo "# RS suite — $DATE"
    echo
    echo "**Build:** Hangs-Local · $DEST"
    echo "**Tree:** $TREE$DIRTY"
    echo "**Driver:** xcodebuild (frozen XCUITest suite, no LLM)"
    echo "**Wall clock:** ${ELAPSED}s · xcodebuild exit $XC_EXIT"
    echo
    echo "## VERDICT: $VERDICT — $PASSED passed, $FAILED failed"
    echo
    echo "| Test | Result | Seconds |"
    echo "|---|---|---|"
    grep -E "^Test Case .* (passed|failed)" "$LOG" \
        | sed -E "s/^Test Case '-\[HangsUITests\.([A-Za-z]+) ([A-Za-z0-9_]+)\]' (passed|failed) \(([0-9.]+) seconds\)\./| \1.\2 | \3 | \4 |/" \
        | sort -u
    if [ "$FAILED" -gt 0 ] || [ "$XC_EXIT" -ne 0 ]; then
        echo
        echo "## Failures"
        echo
        echo '```'
        grep -E "error: -\[|XCTAssert|Assertion Failure|\*\* TEST" "$LOG" | sed -E 's/^[^:]*:[0-9]+: //' | sort -u | head -40
        echo '```'
    fi
    echo
    echo "VERDICT: $VERDICT"
} > "$REPORT"

echo "RS suite: $VERDICT ($PASSED passed, $FAILED failed, ${ELAPSED}s) → $REPORT" >&2
[ "$VERDICT" = "PASS" ]
