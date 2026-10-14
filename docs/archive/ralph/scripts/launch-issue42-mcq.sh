#!/usr/bin/env bash
# Launch Ralph against #42 Track F — fresh MCQ batch run (gen→verify→score).
#
#   ssh mba bash code/quiz-agent/scripts/ralph/launch-issue42-mcq.sh
#
# Re-runnable loop: 42.19 (CLI flags) lands once, then 42.20 repeats — one
# MCQ-biased batch of 20 per iteration via generate_pack.py --dry-run, MCQ
# candidates committed to data/generated/mcq_batch_*.json — until the
# cumulative candidate count hits ~40, then 42.23 (importer code+tests).
# 42.21 (Workflow review screen) / 42.22 (founder) / 42.24 (prod import)
# are [SESSION]/[HUMAN] — Ralph skips them by convention.
# All work is Python/backend — no iOS build required, no SDK gate.
# Needs OPENAI/Tavily keys in .env (same as the issue-30 loop).
set -euo pipefail

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"
export TERM=xterm-256color

REPO_ROOT="$HOME/code/quiz-agent"
FOCUS_FILE="docs/issues/issue-42-question-quality-and-mcq.md"
SESSION_NAME="ralph-issue42mcq"
# 1× 42.19 + ~3 batches of 20 (≥5 MCQ candidates each → ~40 target may take
# more) + 1× 42.23. Override per run: MAX_ITERS=12 ssh mba bash .../launch-issue42-mcq.sh
MAX_ITERS="${MAX_ITERS:-8}"

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
