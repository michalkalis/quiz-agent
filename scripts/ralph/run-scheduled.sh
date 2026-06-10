#!/usr/bin/env bash
# Ralph Scheduled Entry — invoked by launchd (com.quizagent.ralph-overnight) at
# 00:30 on the agent Mac. Thin on purpose: launchd panes do not source ~/.zprofile,
# so we set PATH explicitly, cd into the repo, and run overnight.sh in the
# foreground (no tmux — nobody attaches at 00:30; overnight.sh's lockfile guards
# against colliding with a manual run or the Remote Control session).
#
# All stdout/stderr is captured by the plist into ~/Library/Logs/quizagent-ralph.log.
set -euo pipefail

# Native claude install + homebrew, matching the Remote Control LaunchAgent.
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export TERM=xterm-256color

# Resolve repo root from this script's location so the path isn't hardcoded.
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_PATH/../.." && pwd)"
cd "$REPO_ROOT"

echo "════════════════════════════════════════════════════════════════"
echo "[run-scheduled] $(date '+%Y-%m-%d %H:%M:%S') starting overnight run"
echo "[run-scheduled] repo: $REPO_ROOT"
echo "[run-scheduled] claude: $(command -v claude || echo 'NOT FOUND') $(claude --version 2>/dev/null || true)"

if ! command -v claude >/dev/null 2>&1; then
    echo "[run-scheduled] claude not on PATH — aborting." >&2
    exit 127
fi

scripts/ralph/overnight.sh
echo "[run-scheduled] $(date '+%Y-%m-%d %H:%M:%S') overnight run finished"
