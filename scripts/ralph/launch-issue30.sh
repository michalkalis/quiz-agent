#!/usr/bin/env bash
# Launch Ralph against the #30 disney/football top-up + doc-drift close-out.
#
#   ssh mba bash code/quiz-agent/scripts/ralph/launch-issue30.sh
#
# Six tasks (30.1–30.6): generate/verify/score/approve disney + football batches,
# migrate to prod pgvector, then close out the issue and the dangling #62 reference.
# All work is Python/backend — no iOS build required, no SDK gate.
set -euo pipefail

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"
export TERM=xterm-256color

REPO_ROOT="$HOME/code/quiz-agent"
FOCUS_FILE="docs/issues/issue-30-batch-generate-categories.md"
SESSION_NAME="ralph-issue30"
# 6 tasks + generous slack for batch retries (disney/football may each need 2 rounds).
MAX_ITERS="${MAX_ITERS:-10}"

cd "$REPO_ROOT"

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
