#!/usr/bin/env bash
# Launch Ralph against the #45 iOS MCQ-voice + design-port plan from agent Mac.
#
#   ssh mba bash code/quiz-agent/scripts/ralph/launch-issue45.sh
#
# Only the Ralph-suitable tasks (45.1–45.6) use `- [ ]`; the human integration /
# visual / simulator tasks (45.7–45.13) use `- [HUMAN]` so the harness skips them.
#
# ⛔ HARD PREREQUISITE — iOS 26 SDK + accepted Xcode license.
# The Hangs target uses SpeechAnalyzer (iOS 26-only). Xcode 26.3 is installed
# (no-admin) at ~/Applications/Xcode-26.3.0.app and selected here via DEVELOPER_DIR
# (no sudo / no /Applications). Its iOS 26.2 SDK is bundled. BUT xcodebuild is
# license-gated: an admin (michalkalis) must run ONCE:
#   sudo DEVELOPER_DIR=/Users/agent/Applications/Xcode-26.3.0.app/Contents/Developer \
#        xcodebuild -license accept
#   sudo DEVELOPER_DIR=... xcodebuild -runFirstLaunch   # if a build reports missing packages
# This launcher fail-loud pre-flights both SDK presence and license, and refuses
# to start otherwise. Alternatively run the loop on the laptop (builds on iOS 26).
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
FOCUS_FILE="docs/issues/issue-45-ios-mcq-voice-and-redesign.md"
SESSION_NAME="ralph-issue45"
# 6 Ralph-suitable tasks (45.1–45.6) + slack for retries/blockers.
MAX_ITERS="${MAX_ITERS:-10}"

cd "$REPO_ROOT"

# --- Fail-loud pre-flight: iOS code is unbuildable without the iOS 26 SDK AND an
#     accepted Xcode license. Distinguish the two so the message is actionable.
SDKS="$(xcodebuild -showsdks 2>&1 || true)"
if echo "$SDKS" | grep -qi "license"; then
    echo "[launch] ⛔ Xcode license not accepted for $DEVELOPER_DIR." >&2
    echo "[launch]    An admin (michalkalis) must run ONCE:" >&2
    echo "[launch]      sudo DEVELOPER_DIR=$DEVELOPER_DIR xcodebuild -license accept" >&2
    echo "[launch]    Aborting." >&2
    exit 4
fi
if ! echo "$SDKS" | grep -q "iphonesimulator26"; then
    echo "[launch] ⛔ iOS 26 simulator SDK not found — Hangs uses SpeechAnalyzer (iOS 26 API)." >&2
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
