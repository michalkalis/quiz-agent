#!/bin/bash
# Session start hook - lightweight reminder only.
# Skill names are already surfaced via the standard skills list; no need to re-print them.

# #204.9: the weekly voice-experiment job opens an issue labelled
# voice-experiment when it switches a voice setting on or off by itself. The
# founder hears about it from the agent here, not from an email that gets lost.
# Quiet on any failure (no gh, no auth, offline); capped so startup stays fast.
TIMEOUT_CMD=$(command -v timeout || command -v gtimeout)
if command -v gh >/dev/null 2>&1 && [ -n "$TIMEOUT_CMD" ]; then
    VOICE_ISSUES=$(cd "$CLAUDE_PROJECT_DIR" && "$TIMEOUT_CMD" 3 gh issue list \
        --label voice-experiment --state open --limit 5 \
        --json number,title,url --jq '.[] | "  #\(.number) \(.title) \(.url)"' 2>/dev/null)
    if [ -n "$VOICE_ISSUES" ]; then
        echo "Voice experiment decided something (issue #204 — answer recognition, task 204.9):"
        echo "$VOICE_ISSUES"
        echo "Tell the founder in plain words what changed in the app, then close each issue (gh issue close N)."
    fi
fi

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
