#!/bin/bash
# Session start hook - lightweight reminder only.
# Skill names are already surfaced via the standard skills list; no need to re-print them.

LAST_CHECK_FILE="$CLAUDE_PROJECT_DIR/.claude/.last-check"

if [ ! -f "$LAST_CHECK_FILE" ]; then
    echo "Best-practices check has never run — consider /best-practices."
    exit 0
fi

LAST_CHECK=$(cat "$LAST_CHECK_FILE" 2>/dev/null)
if [[ "$LAST_CHECK" =~ ^[0-9]+$ ]]; then
    DAYS_SINCE=$(( ( $(date +%s) - LAST_CHECK ) / 86400 ))
    if [ "$DAYS_SINCE" -ge 7 ]; then
        echo "Best-practices check is ${DAYS_SINCE} days overdue — consider /best-practices."
    fi
fi

exit 0
