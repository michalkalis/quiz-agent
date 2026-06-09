#!/usr/bin/env bash
# Launch Ralph against the #49 daily-limit cost research issue.
#
#   ssh mba bash code/quiz-agent/scripts/ralph/launch-issue49.sh
#
# Pure research issue: reads serving-path LLM call sites, loads Claude pricing
# via the claude-api skill, queries Fly.io machine specs, computes cost scenarios,
# and writes a self-contained HTML artifact to docs/artifacts/daily-limit-cost-model.html.
# No iOS compilation — no SDK gate required.
#
# Tasks 49.1–49.8 (8 tasks) + slack for retries.
set -euo pipefail

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"
export TERM=xterm-256color

REPO_ROOT="$HOME/code/quiz-agent"
FOCUS_FILE="docs/issues/issue-49-daily-limit-cost-research.md"
SESSION_NAME="ralph-issue49"
# 8 tasks + 4 slack iterations for retries/blockers.
MAX_ITERS="${MAX_ITERS:-12}"

cd "$REPO_ROOT"

# --- Fail-loud pre-flight: fly CLI must be available (needed for 49.3).
if ! command -v fly &>/dev/null; then
    echo "[launch] fly CLI not found on PATH — needed for task 49.3 (fly scale show / fly status)." >&2
    echo "[launch] Install: https://fly.io/docs/hands-on/install-flyctl/" >&2
    echo "[launch] Then re-run this script. Aborting." >&2
    exit 3
fi
echo "[launch] fly CLI: $(fly version 2>/dev/null | head -1 || echo '?')"

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

# NB: set PATH *inside* the tmux command — a non-login pane shell does not source
# ~/.zprofile, so `claude` (native install at ~/.local/bin) would be off PATH and
# every ralph.sh iteration would die with exit 127. Escape $HOME/$PATH so they
# resolve in the pane, not here.
tmux new -d -s "$SESSION_NAME" \
    "export PATH=\"\$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:\$PATH\"; cd '$REPO_ROOT' && scripts/ralph/ralph.sh '$FOCUS_FILE' $MAX_ITERS; echo; echo '[ralph] loop finished — pane will sleep for 1h so you can scroll'; sleep 3600"

echo "[launch] started tmux session '$SESSION_NAME' running scripts/ralph/ralph.sh"
echo "[launch] attach with:"
echo "         ssh -t mba 'TERM=xterm-256color tmux attach -t $SESSION_NAME'"
echo "[launch] detach inside tmux with: Ctrl-B then D"
