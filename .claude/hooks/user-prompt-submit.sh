#!/bin/bash
# User prompt submit hook - adds context for Claude when best practices check is overdue
# This hook injects a reminder into Claude's context (not visible to user)

LAST_CHECK_FILE="$CLAUDE_PROJECT_DIR/.claude/.last-check"
SESSION_FLAG="/tmp/claude-best-practices-asked-$$"

# Only show reminder once per session
if [ -f "$SESSION_FLAG" ]; then
    exit 0
fi

# Check if last check file exists
if [ ! -f "$LAST_CHECK_FILE" ]; then
    # No check ever run - suggest running it
    DAYS_SINCE="never"
else
    LAST_CHECK=$(cat "$LAST_CHECK_FILE" 2>/dev/null)
    NOW=$(date +%s)

    # Validate timestamp
    if ! [[ "$LAST_CHECK" =~ ^[0-9]+$ ]]; then
        DAYS_SINCE="unknown"
    else
        SECONDS_SINCE=$((NOW - LAST_CHECK))
        DAYS_SINCE=$((SECONDS_SINCE / 86400))
    fi
fi

# Only remind if check is overdue (7+ days) or never run
if [ "$DAYS_SINCE" = "never" ] || [ "$DAYS_SINCE" = "unknown" ] || [ "$DAYS_SINCE" -ge 7 ]; then
    # Create session flag to avoid repeated reminders
    touch "$SESSION_FLAG"

    # Output context that Claude will see
    if [ "$DAYS_SINCE" = "never" ]; then
        echo "Best practices check has never been run for this project. Consider asking the user if they'd like to run /best-practices to review their Claude Code setup."
    else
        echo "It's been ${DAYS_SINCE} days since the last best practices check. Consider asking the user if they'd like to run /best-practices to review their Claude Code setup."
    fi
fi

exit 0
