#!/usr/bin/env bash
# Launch Ralph against the #52 iOS design-refresh sweep from agent Mac (mba).
#
#   ssh mba bash code/quiz-agent/scripts/ralph/launch-issue52.sh
#
# The whole sweep is ONE autonomous loop (founder override of the original hybrid).
# Ralph picks the first `- [ ]` task: Phase 1/2 are machine-verifiable (tokens, fonts,
# components, flow logic); Phase 3 screens (52.8–52.15) each carry a screenshot-verify
# acceptance — build → sim screenshot → compare to the committed reference PNG in
# docs/design/frames/<frameId>.png → self-correct. ralph.sh auto-attaches XcodeBuildMCP
# for iOS focus files (this one matches). Only 52.16–52.18 are `- [HUMAN]` (skipped).
#
# ⛔ HARD PREREQUISITES (read overnight-queue.md): #44 (screenshot-verify harness) and
# #45 (shared QuestionView/AnswerOption/tokens — Phase 0) must already be on origin.
# This launcher does NOT check that — it's enforced by queue order (#44 → #45 → #52).
#
# iOS builds use mba's system Xcode 26.5 + iOS 26 SDK (no DEVELOPER_DIR — see memory
# project_mba_ios26_sdk_gap). The pre-flight below fails loud if that SDK is missing.
set -euo pipefail

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"
export TERM=xterm-256color
echo "[launch] using Xcode: $(xcodebuild -version 2>/dev/null | head -1 || echo '?')"

REPO_ROOT="$HOME/code/quiz-agent"
FOCUS_FILE="docs/issues/issue-52-design-refresh-sweep.md"
SESSION_NAME="ralph-issue52"
# 15 Ralph-suitable tasks (52.1–52.15) + slack for retries/blockers.
MAX_ITERS="${MAX_ITERS:-18}"

cd "$REPO_ROOT"

# --- Fail-loud pre-flight: every Phase-3 screen task builds the Hangs target, which
#     needs the iOS 26 simulator SDK (SpeechAnalyzer is iOS 26-only) AND an accepted
#     Xcode license. Distinguish the two so the message is actionable.
SDKS="$(xcodebuild -showsdks 2>&1 || true)"
if echo "$SDKS" | grep -qi "license"; then
    echo "[launch] ⛔ Xcode license not accepted." >&2
    echo "[launch]    An admin (michalkalis) must run ONCE: sudo xcodebuild -license accept" >&2
    echo "[launch]    Aborting." >&2
    exit 4
fi
if ! echo "$SDKS" | grep -q "iphonesimulator26"; then
    echo "[launch] ⛔ iOS 26 simulator SDK not found — Hangs uses SpeechAnalyzer (iOS 26 API)." >&2
    echo "$SDKS" | grep -i "ios" >&2 || true
    echo "[launch]    Check the system Xcode 26 install (or run on the laptop). Aborting." >&2
    exit 4
fi

# Reference frames must be committed (the headless loop has no pencil MCP).
if ! ls docs/design/frames/*.png >/dev/null 2>&1; then
    echo "[launch] ⛔ no reference PNGs in docs/design/frames/ — screenshot-verify can't run." >&2
    echo "[launch]    Re-export from design/quiz-agent.pen (see docs/design/frames/README.md). Aborting." >&2
    exit 5
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
