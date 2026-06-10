#!/usr/bin/env bash
# Launch the Ralph overnight run on-demand inside tmux (for when you're awake and
# want to attach and watch). The 00:30 scheduled path uses run-scheduled.sh
# instead (no tmux). Both go through overnight.sh, whose lockfile prevents the two
# from colliding.
#
#   ssh mba bash code/quiz-agent/scripts/ralph/launch-overnight.sh
#   # optionally pass focus files for a manual subset / dry-run:
#   ssh mba bash code/quiz-agent/scripts/ralph/launch-overnight.sh docs/issues/issue-49-daily-limit-cost-research.md
set -euo pipefail

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"
export TERM=xterm-256color

SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_PATH/../.." && pwd)"
SESSION_NAME="ralph-overnight"
cd "$REPO_ROOT"

if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "[launch] session '$SESSION_NAME' already exists; attach with:"
    echo "         ssh -t mba 'TERM=xterm-256color tmux attach -t $SESSION_NAME'"
    exit 0
fi

# Forward any focus-file args to overnight.sh (quoted for the pane shell).
ARGS=""
for a in "$@"; do ARGS+=" '$a'"; done

# Set PATH inside the pane — a non-login tmux shell does not source ~/.zprofile,
# so the native claude install at ~/.local/bin would otherwise be off PATH.
tmux new -d -s "$SESSION_NAME" \
    "export PATH=\"\$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:\$PATH\"; cd '$REPO_ROOT' && scripts/ralph/overnight.sh$ARGS; echo; echo '[overnight] finished — pane sleeps 1h so you can scroll'; sleep 3600"

echo "[launch] started tmux session '$SESSION_NAME' running scripts/ralph/overnight.sh"
echo "[launch] attach with:"
echo "         ssh -t mba 'TERM=xterm-256color tmux attach -t $SESSION_NAME'"
echo "[launch] detach inside tmux with: Ctrl-B then D"
