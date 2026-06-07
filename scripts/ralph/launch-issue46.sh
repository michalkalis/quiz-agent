#!/usr/bin/env bash
# Launch Ralph against the #46 canonical-answer + open/logical-branch plan from agent Mac.
#
#   ssh mba bash code/quiz-agent/scripts/ralph/launch-issue46.sh
#
# One loop runs the whole issue end to end (A→B): Track A + Track B backend are
# pure Python; the Track B iOS tail (46.B8–B9) builds on the iOS 26 SDK. All tasks
# use `- [ ]`, so the harness walks them top-to-bottom in dependency order.
#
# ⛔ HARD PREREQUISITE — iOS 26 SDK + accepted Xcode license (for 46.B8–B9).
# The Hangs target uses SpeechAnalyzer (iOS 26-only). mba carries the latest Xcode
# + macOS; this launcher auto-selects an iOS-26 Xcode and fail-loud pre-flights the
# SDK + license so a premature run surfaces the blocker instead of failing on the
# iOS tail after burning backend iterations. Mirrors launch-issue45.sh.
set -euo pipefail

export PATH=/opt/homebrew/bin:/opt/homebrew/sbin:$PATH
export TERM=xterm-256color
# Pick an Xcode that ships the iOS 26 SDK, in priority order:
#   1. caller-provided DEVELOPER_DIR (respect an explicit override)
#   2. the system-selected Xcode, IF it is already 26.x (e.g. after an upgrade)
#   3. the no-admin staged ~/Applications/Xcode-26.3.0.app (license-gated; needs
#      a one-time `sudo … xcodebuild -license accept` by an admin)
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    if xcodebuild -version 2>/dev/null | grep -q "Xcode 26"; then
        :  # system Xcode is already 26.x — use it, no override
    elif [[ -d "$HOME/Applications/Xcode-26.3.0.app/Contents/Developer" ]]; then
        export DEVELOPER_DIR="$HOME/Applications/Xcode-26.3.0.app/Contents/Developer"
    fi
fi
echo "[launch] using Xcode: $(xcodebuild -version 2>/dev/null | head -1 || echo '?')  (DEVELOPER_DIR=${DEVELOPER_DIR:-<system>})"

REPO_ROOT="$HOME/code/quiz-agent"
FOCUS_FILE="docs/issues/issue-46-answer-shape-and-logical-branch.md"
SESSION_NAME="ralph-issue46"
# 13 tasks (46.A1–A4 + 46.B1–B9) + slack for retries/blockers.
MAX_ITERS="${MAX_ITERS:-18}"

cd "$REPO_ROOT"

# --- Fail-loud pre-flight: the iOS tail (46.B8–B9) is unbuildable without the
#     iOS 26 SDK AND an accepted Xcode license. Distinguish the two so the message
#     is actionable. Track A + the backend Track B tasks do not need it, but the
#     single loop reaches the iOS tail, so gate up front.
SDKS="$(xcodebuild -showsdks 2>&1 || true)"
if echo "$SDKS" | grep -qi "license"; then
    echo "[launch] ⛔ Xcode license not accepted for $DEVELOPER_DIR." >&2
    echo "[launch]    An admin (michalkalis) must run ONCE:" >&2
    echo "[launch]      sudo DEVELOPER_DIR=$DEVELOPER_DIR xcodebuild -license accept" >&2
    echo "[launch]    Aborting." >&2
    exit 4
fi
if ! echo "$SDKS" | grep -q "iphonesimulator26"; then
    echo "[launch] ⛔ iOS 26 simulator SDK not found — 46.B8–B9 build the Hangs target (iOS 26 API)." >&2
    echo "[launch]    DEVELOPER_DIR=$DEVELOPER_DIR · current SDKs:" >&2
    echo "$SDKS" | grep -i "ios" >&2 || true
    echo "[launch]    Check the Xcode 26 install (or run this loop on the laptop). Aborting." >&2
    exit 4
fi

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

tmux new -d -s "$SESSION_NAME" \
    "cd '$REPO_ROOT' && scripts/ralph/ralph.sh '$FOCUS_FILE' $MAX_ITERS; echo; echo '[ralph] loop finished — pane will sleep for 1h so you can scroll'; sleep 3600"

echo "[launch] started tmux session '$SESSION_NAME' running scripts/ralph/ralph.sh"
echo "[launch] attach with:"
echo "         ssh -t mba 'TERM=xterm-256color tmux attach -t $SESSION_NAME'"
echo "[launch] detach inside tmux with: Ctrl-B then D"
