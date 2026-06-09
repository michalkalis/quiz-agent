#!/usr/bin/env bash
# Launch Ralph against the #44 screenshot-verify step plan from agent Mac.
#
#   ssh mba bash code/quiz-agent/scripts/ralph/launch-issue44.sh
#
# All 5 tasks (44.1–44.5) are pure skill/rules markdown edits + one regression
# smoke run. No iOS compilation is required for tasks 44.1–44.4; task 44.5
# runs /regression RS-01, which DOES build the Hangs target.
#
# ⛔ HARD PREREQUISITE for task 44.5 — iOS 26 SDK + accepted Xcode license.
# Tasks 44.1–44.4 can complete without it. If the SDK is missing, 44.5 will
# write a BLOCKER note and the loop will exit cleanly; that is acceptable.
# To unlock 44.5 fully, an admin (michalkalis) must run ONCE:
#   sudo DEVELOPER_DIR=<path-to-xcode-26>/Contents/Developer xcodebuild -license accept
set -euo pipefail

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"
export TERM=xterm-256color

REPO_ROOT="$HOME/code/quiz-agent"
FOCUS_FILE="docs/issues/issue-44-screenshot-verify-step.md"
SESSION_NAME="ralph-issue44"
# 5 tasks (44.1–44.5) + slack for retries/blockers.
MAX_ITERS="${MAX_ITERS:-9}"

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
