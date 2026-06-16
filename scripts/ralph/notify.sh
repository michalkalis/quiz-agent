#!/usr/bin/env bash
# Ralph notify (#57 — loop verification backbone, 57.9).
#
# Emit exactly ONE state-change line per run at a terminal state (done / blocked /
# idle) — never per iteration. Founder decision 2026-06-16: don't wire a night-time
# phone push yet (we review in the morning), so the DEFAULT sink is a durable local
# note you can glance at over ssh. An optional webhook (dormant unless
# RALPH_NOTIFY_WEBHOOK is set) sends the same one-liner to ntfy/Slack/Discord — turn
# phone push on later with a single .env line, no code change.
#
# Source this file, then call once at the run's terminal state:
#     ralph_notify <state> <one-line summary…>
#   <state> ∈ done | blocked | idle
#
# Sinks (always the first two; the third only if RALPH_NOTIFY_WEBHOOK is set):
#   • scripts/ralph/logs/LAST-RUN.md        — overwritten: the latest run at a glance
#   • scripts/ralph/logs/status-history.log — appended: one tab-separated line per event
#   • $RALPH_NOTIFY_WEBHOOK                  — POSTed (ntfy-shaped: Title header + body)
#
# logs/ is gitignored, so these stay local to the machine that ran the loop (mba for
# the overnight chain) — exactly the ssh-glance the founder asked for. The GitHub
# Issues mirror (57.10) is the phone/web-visible surface that needs no ssh.

# ralph_notify <state> <summary…>
ralph_notify() {
    local state="$1"; shift
    local summary="$*"
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"

    local root="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    local logdir="$root/scripts/ralph/logs"
    mkdir -p "$logdir"

    local icon
    case "$state" in
        done)    icon="✅" ;;
        blocked) icon="⛔" ;;
        idle)    icon="·"  ;;
        *)       icon="•"  ;;
    esac

    # One-glance latest-run note (overwritten each terminal event).
    {
        printf '# Ralph — last run\n\n'
        printf '%s **%s** — %s\n\n' "$icon" "$state" "$summary"
        printf '_%s_\n' "$ts"
    } > "$logdir/LAST-RUN.md"

    # Durable history: one line per terminal event (state changes only, never mid-run).
    printf '%s\t%s\t%s\n' "$ts" "$state" "$summary" >> "$logdir/status-history.log"

    # Optional phone/chat push — dormant until the founder sets RALPH_NOTIFY_WEBHOOK
    # in .env. Shaped for ntfy (Title header + plain body); a Slack/Discord incoming
    # webhook ignores the header and shows the body text.
    if [[ -n "${RALPH_NOTIFY_WEBHOOK:-}" ]]; then
        if curl -fsS -m 10 \
                -H "Title: Ralph: $state" \
                -d "$icon $state — $summary" \
                "$RALPH_NOTIFY_WEBHOOK" >/dev/null 2>&1; then
            echo "[notify] webhook sent ($state)"
        else
            echo "[notify] webhook POST failed (non-fatal) — local note still written" >&2
        fi
    fi
}
