#!/usr/bin/env bash
# Launch Ralph against #51 — product analytics for PRD success metrics.
#
#   ssh mba bash code/quiz-agent/scripts/ralph/launch-issue51.sh
#
# Ralph tasks: 51.1 (event taxonomy doc), then — ONLY after the founder flips
# 51.2 to [x] — 51.3 (backend instrumentation) and 51.4 (iOS AnalyticsClient
# seam + unit tests, builds on the iOS 26 SDK). The gate is enforced in the
# focus file (51.3/51.4 say "exit no-tasks if 51.2 is open"), so launching
# early is safe: the loop does 51.1 and stops. 51.5 is a laptop session.
set -euo pipefail

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"
export TERM=xterm-256color
# Pick an Xcode that ships the iOS 26 SDK (needed for 51.4), in priority order:
#   1. caller-provided DEVELOPER_DIR (respect an explicit override)
#   2. the system-selected Xcode, IF it is already 26.x
#   3. the no-admin staged ~/Applications/Xcode-26.3.0.app
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    if xcodebuild -version 2>/dev/null | grep -q "Xcode 26"; then
        :  # system Xcode is already 26.x — use it, no override
    elif [[ -d "$HOME/Applications/Xcode-26.3.0.app/Contents/Developer" ]]; then
        export DEVELOPER_DIR="$HOME/Applications/Xcode-26.3.0.app/Contents/Developer"
    fi
fi
echo "[launch] using Xcode: $(xcodebuild -version 2>/dev/null | head -1 || echo '?')  (DEVELOPER_DIR=${DEVELOPER_DIR:-<system>})"

REPO_ROOT="$HOME/code/quiz-agent"
FOCUS_FILE="docs/issues/issue-51-product-analytics.md"
SESSION_NAME="ralph-issue51"
# 3 Ralph tasks (51.1 / 51.3 / 51.4) + slack for retries.
MAX_ITERS="${MAX_ITERS:-5}"

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
    "export PATH=\"\$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:\$PATH\"; export DEVELOPER_DIR=\"${DEVELOPER_DIR:-}\"; cd '$REPO_ROOT' && scripts/ralph/ralph.sh '$FOCUS_FILE' $MAX_ITERS; echo; echo '[ralph] loop finished — pane will sleep for 1h so you can scroll'; sleep 3600"

echo "[launch] started tmux session '$SESSION_NAME' running scripts/ralph/ralph.sh"
echo "[launch] attach with:"
echo "         ssh -t mba 'TERM=xterm-256color tmux attach -t $SESSION_NAME'"
echo "[launch] detach inside tmux with: Ctrl-B then D"
