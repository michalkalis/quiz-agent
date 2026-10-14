#!/usr/bin/env bash
# Launch Ralph against the #42 question-quality + multichoice plan from agent Mac.
#
# Designed to be invoked over SSH without any quote escaping:
#
#   ssh mba bash code/quiz-agent/scripts/ralph/launch-issue42.sh
#
# Tracks A–D (42.1–42.13) are Ralph-suitable; Track E (42.14–42.18) uses
# `- [HUMAN]` checkboxes so the harness skips them — iOS work lands manually
# on the laptop after Ralph finishes.
#
# Pre-flight on agent Mac:
#   1. `.env` synced (see laptop session handoff)
#   2. `uv pip install -e apps/quiz-pack-api[test] && uv pip install -e packages/shared`
#      (picks up `respx` and any other test deps that landed with #36)
#   3. `claude --version` matches laptop
#
# Robust to:
#   - broken/unsourced ~/.zprofile (hard-codes homebrew PATH)
#   - TERM=xterm-ghostty terminfo missing on agent Mac
#   - existing tmux session (idempotent: re-attach instead of crash)
set -euo pipefail

# Don't rely on .zprofile being loaded — hard-code homebrew first.
export PATH=/opt/homebrew/bin:/opt/homebrew/sbin:$PATH

# Force a tmux-safe TERM. xterm-ghostty terminfo isn't installed on agent Mac
# and would cause `tmux new` to refuse the session.
export TERM=xterm-256color

REPO_ROOT="$HOME/code/quiz-agent"
FOCUS_FILE="docs/issues/issue-42-question-quality-and-mcq.md"
SESSION_NAME="ralph-issue42"
# 13 Ralph-suitable tasks (42.1–42.13) + 5-iter slack for retries/blockers.
MAX_ITERS="${MAX_ITERS:-18}"

cd "$REPO_ROOT"

# Pull latest before launch — agent-side commits land while loop runs.
git pull --ff-only

if [[ ! -f "$FOCUS_FILE" ]]; then
    echo "[launch] focus file not found after pull: $FOCUS_FILE" >&2
    exit 2
fi

if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "[launch] session '$SESSION_NAME' already exists; attach with:"
    echo "         ssh -t mba 'TERM=xterm-256color tmux attach -t $SESSION_NAME'"
    exit 0
fi

# Trailing `sleep 3600` keeps the pane alive after the loop finishes so the
# operator can scroll the harness summary on attach.
tmux new -d -s "$SESSION_NAME" \
    "cd '$REPO_ROOT' && scripts/ralph/ralph.sh '$FOCUS_FILE' $MAX_ITERS; echo; echo '[ralph] loop finished — pane will sleep for 1h so you can scroll'; sleep 3600"

echo "[launch] started tmux session '$SESSION_NAME' running scripts/ralph/ralph.sh"
echo "[launch] attach with:"
echo "         ssh -t mba 'TERM=xterm-256color tmux attach -t $SESSION_NAME'"
echo "[launch] detach inside tmux with: Ctrl-B then D"
