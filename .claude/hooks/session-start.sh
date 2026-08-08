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

# Monthly external news scan (Claude Code changelog, blogs, community tools).
LAST_NEWS_FILE="$CLAUDE_PROJECT_DIR/.claude/.last-news-scan"
if [ ! -f "$LAST_NEWS_FILE" ]; then
    echo "Agentic-coding news scan has never run — consider /news-scan."
else
    LAST_NEWS=$(cat "$LAST_NEWS_FILE" 2>/dev/null)
    if [[ "$LAST_NEWS" =~ ^[0-9]+$ ]]; then
        NEWS_DAYS=$(( ( $(date +%s) - LAST_NEWS ) / 86400 ))
        if [ "$NEWS_DAYS" -ge 30 ]; then
            echo "Agentic-coding news scan is ${NEWS_DAYS} days old (monthly cadence) — consider /news-scan."
        fi
    fi
fi

exit 0
