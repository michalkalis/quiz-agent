#!/usr/bin/env bash
# ralph72-window.sh — one "window" fire of the issue #72 overnight grind on mba.
#
# WHY THIS WRAPPER EXISTS
#   overnight.sh always cuts its work branch from main HEAD and has NO resume knob;
#   the worker picks the next task purely from the focus file's checkboxes. Under the
#   Claude session limit (~3-4 max-effort Opus iters per 5h window) the #72 grind must
#   span several reset windows. If every scheduled fire cut from pristine origin/main,
#   each would restart at P0.1 -> zero net overnight progress. This wrapper fast-forwards
#   mba's LOCAL main to the latest ralph/* tip (accumulated progress) before each fire,
#   so the worker resumes at the next open checkbox. The founder now reconciles completed
#   phases to origin/main (it is NO LONGER frozen), so origin/main can move ahead of the
#   ralph tips; the tip merge below is therefore CONDITIONAL and never aborts the window.
#
# SAFETY
#   - Respects overnight.sh's single-instance lock: if a grind is active, skip entirely
#     and touch nothing (another run owns the one working tree).
#   - Advances LOCAL main with `merge --ff-only` ONLY: a pure fast-forward that never
#     rewrites or discards history and fails loudly if the tip is not a clean descendant.
#     The tip ff is guarded by `merge-base --is-ancestor` so it can only advance main,
#     never rewind it; a diverged/behind tip is a logged no-op, not a fatal abort.
#     Non-destructive and reversible. This wrapper never runs `git push`.
set -euo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export TERM=xterm-256color
cd /Users/agent/code/quiz-agent

# If a grind already owns the lock, this fire is a no-op (do NOT disturb its working tree).
if [[ -d scripts/ralph/.overnight.lock ]]; then
  echo "[ralph72-window] $(date '+%F %T') overnight run already active — skipping this fire."
  exit 0
fi

# The agent Mac runs Hangs iOS tests in THIS same checkout. A branch switch / ff mid-build
# corrupts it under xcodebuild, so skip the fire while a REAL build/test is active. Match
# only genuine `xcodebuild <verb>` invocations — NOT the idle `xcodebuildmcp` MCP tool
# server (its argv contains the "xcodebuild" substring) nor incidental command text that
# merely mentions xcodebuild. A build wedged >1h is an orphaned zombie (a real HangsTests
# run is ~1-2 min; the gtimeout cap is 40 min), not an active build: force-kill it and
# proceed, so a hung build can NEVER block windows for days (the 7-day stall, 2026-06).
xcb_pids="$(pgrep -f 'xcodebuild (test|build|clean|archive|analyze|-scheme|-project|-workspace)' 2>/dev/null || true)"
if [[ -n "$xcb_pids" ]]; then
  recent_build=""
  for _p in $xcb_pids; do
    _et="$(ps -o etime= -p "$_p" 2>/dev/null | tr -d ' ')"
    # BSD etime: MM:SS (<1h) | HH:MM:SS (>=1h) | D-HH:MM:SS (>=1d). A '-' or 2+ ':' => >=1h.
    if [[ -n "$_et" && "$_et" != *-* && "$(printf '%s' "$_et" | tr -cd ':' | wc -c | tr -d ' ')" -lt 2 ]]; then
      recent_build="yes"
    fi
  done
  if [[ -n "$recent_build" ]]; then
    echo "[ralph72-window] $(date '+%F %T') active iOS build/test (<1h) in the working tree — skipping this fire."
    exit 0
  fi
  echo "[ralph72-window] $(date '+%F %T') STALE wedged xcodebuild >1h (pids: $xcb_pids) — force-killing orphan and proceeding."
  kill -9 $xcb_pids 2>/dev/null || true
  sleep 1
fi

# Position LOCAL main at the most-advanced resume base. First advance to the founder's
# reconciled baseline (origin/main), then ff to the latest ralph/* tip ONLY if it is strictly
# ahead of that baseline. Both steps are non-fatal: a window must never no-op on a diverged/
# behind branch the way the unconditional ff did (the 2026-06-25 doom-loop).
git checkout main
git fetch origin main --quiet 2>/dev/null || true
git merge --ff-only origin/main 2>/dev/null || true   # advance to the founder's reconciled baseline
TIP="$(git for-each-ref --sort=-committerdate --format='%(objectname)' refs/heads/ralph/ | head -1)"
if [[ -n "$TIP" ]] && git merge-base --is-ancestor HEAD "$TIP"; then
  git merge --ff-only "$TIP"                            # ralph tip ahead of baseline -> resume in-flight progress
else
  echo "[ralph72-window] $(date '+%F %T') ralph tip ${TIP:0:8} not ahead of main (reconciled/none) -> resuming from main."
fi
echo "[ralph72-window] $(date '+%F %T') resume base -> $(git rev-parse --short HEAD)  (overnight.sh cuts its branch from here)"

# Pin Opus 4.8 @ effort max, 22 iters, focus = #72 (Phases 0-5 ONLY; overnight.sh stops at the 🛑 line).
# Hard cutoff: everything must run between 22:00 and 05:30 (Europe/Prague). Cap this fire's
# wall-clock so a grind started late at night can NEVER bleed into the morning (the founder
# dropped the 08:00 window for exactly this reason, 2026-06-25). overnight.sh reads OVERNIGHT_MAX_SECONDS.
now_epoch="$(date +%s)"
hh=$((10#$(date +%H)))
if (( hh >= 22 )); then
  cutoff_epoch="$(date -j -v+1d -v5H -v30M -v0S +%s)"   # 22:00-23:59 fire -> 05:30 tomorrow
else
  cutoff_epoch="$(date -j -v5H -v30M -v0S +%s)"          # 00:00-05:xx fire -> 05:30 today
fi
cap=$(( cutoff_epoch - now_epoch ))
if (( cap < 120 )); then
  echo "[ralph72-window] $(date '+%F %T') within 2 min of the 05:30 cutoff — skipping this fire."
  exit 0
fi
export OVERNIGHT_MAX_SECONDS="$cap"
echo "[ralph72-window] $(date '+%F %T') wall-clock capped at 05:30 (${cap}s remaining)."

export OVERNIGHT_DEFAULT_ITERS=22 RALPH_ROUTER=0 RALPH_DEFAULT_MODEL=claude-opus-4-8 RALPH_EFFORT=max
exec scripts/ralph/overnight.sh docs/issues/issue-72-question-fun-engagement-redesign.md
