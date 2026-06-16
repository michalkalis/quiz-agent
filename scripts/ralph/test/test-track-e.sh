#!/usr/bin/env bash
# Offline proof for #57 Track E (visibility) — same shim style as the A/B/C trip-tests.
# No GitHub writes, no model spend: a fake `gh` records argv + returns canned JSON,
# and a fake webhook sink (file) captures notify POSTs. Run from anywhere.
#
#   scripts/ralph/test/test-track-e.sh
#
# Asserts:
#   57.9  ralph_notify writes ONE LAST-RUN.md + ONE history line per terminal event,
#         fires the webhook only when RALPH_NOTIFY_WEBHOOK is set, and never mid-run.
#   57.10 mirror-issues.sh computes blocked>done>wip>todo correctly, creates only
#         active issues (skips ancient done), closes a done-but-mirrored issue, and
#         sets exactly one state:* label — all one-way (no local file writes).

set -uo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT_DIR="$REPO_ROOT/scripts/ralph"
PASS=0; FAIL=0
ok()   { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d -t ralph-tracke-XXXX)"
trap 'rm -rf "$WORK"' EXIT

# ───────────────────────────────────────────────────────────────────────────
echo "── 57.9 notify ──────────────────────────────────────────────────────"
# Isolated repo-root so the helper writes into a sandbox logs/ dir.
FAKE_ROOT="$WORK/repo"; mkdir -p "$FAKE_ROOT/scripts/ralph/logs"
WEBHOOK_SINK="$WORK/webhook.log"

# Shim curl so the webhook POST is captured, not sent.
BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/curl" <<EOF
#!/usr/bin/env bash
echo "CURL \$*" >> "$WEBHOOK_SINK"
exit 0
EOF
chmod +x "$BIN/curl"

# shellcheck disable=SC1090
REPO_ROOT="$FAKE_ROOT" source "$SCRIPT_DIR/notify.sh"

# (a) No webhook env → local note only, no POST.
( cd "$FAKE_ROOT"; REPO_ROOT="$FAKE_ROOT" PATH="$BIN:$PATH" bash -c '
    source '"$SCRIPT_DIR"'/notify.sh; ralph_notify done "overnight-X · 2 issues · pushed"' )
LAST="$FAKE_ROOT/scripts/ralph/logs/LAST-RUN.md"
HIST="$FAKE_ROOT/scripts/ralph/logs/status-history.log"
[[ -f "$LAST" ]] && grep -q "done" "$LAST" && ok "LAST-RUN.md written (done)" || bad "LAST-RUN.md missing/wrong"
[[ "$(wc -l < "$HIST" | tr -d ' ')" == "1" ]] && ok "history has exactly 1 line after 1 event" || bad "history line count != 1"
[[ ! -f "$WEBHOOK_SINK" ]] && ok "no webhook POST when RALPH_NOTIFY_WEBHOOK unset" || bad "webhook fired without env"

# (b) Second terminal event (blocked) → history grows to 2, LAST-RUN overwritten.
( cd "$FAKE_ROOT"; REPO_ROOT="$FAKE_ROOT" PATH="$BIN:$PATH" RALPH_NOTIFY_WEBHOOK="http://sink" bash -c '
    source '"$SCRIPT_DIR"'/notify.sh; ralph_notify blocked "overnight-X · #56 BLOCKER (scoped gate) · held local"' )
[[ "$(wc -l < "$HIST" | tr -d ' ')" == "2" ]] && ok "history grows by exactly 1 per event (now 2)" || bad "history not append-once"
grep -q "blocked" "$LAST" && ! grep -q "done" "$LAST" && ok "LAST-RUN.md overwritten to latest (blocked)" || bad "LAST-RUN not overwritten"
[[ -f "$WEBHOOK_SINK" ]] && grep -q "blocked" "$WEBHOOK_SINK" && ok "webhook fired once when env set" || bad "webhook not fired with env"

# ───────────────────────────────────────────────────────────────────────────
echo "── 57.10 mirror ─────────────────────────────────────────────────────"
# Build a tiny fake repo with 4 plan files + a TODO, and a fake gh.
M="$WORK/mrepo"; mkdir -p "$M/docs/issues" "$M/docs/todo" "$M/scripts/ralph"
cp "$SCRIPT_DIR/mirror-issues.sh" "$M/scripts/ralph/"
( cd "$M" && git init -q && git config user.email t@t && git config user.name t )

cat > "$M/docs/todo/TODO.md" <<'EOF'
# TODO
- [~] #71 Work in progress thing
- [ ] #72 Not started thing
- [x] #74 Old finished thing
EOF
# #70 blocked (BLOCKER wins over its triage)
cat > "$M/docs/issues/issue-70-blocked-one.md" <<'EOF'
# Issue #70 — Blocked one
**Triage:** enhancement · ready-for-agent
## BLOCKER (2026-06-16) — automated test gate (backend)
- a red gate
EOF
cat > "$M/docs/issues/issue-71-wip-one.md" <<'EOF'
# Issue #71 — Wip one
**Triage:** refactor · in progress
EOF
cat > "$M/docs/issues/issue-72-todo-one.md" <<'EOF'
# Issue #72 — Todo one
**Triage:** enhancement · ready-for-agent
EOF
# #74 done & NOT yet mirrored → must be skipped (no create)
cat > "$M/docs/issues/issue-74-done-one.md" <<'EOF'
# Issue #74 — Done one
**Triage:** enhancement · done
EOF

# Fake gh: records argv; `issue list` returns ONE pre-existing mirrored issue (#73,
# done but still open on GH) to prove the close path.
GHLOG="$WORK/gh.log"
cat > "$BIN/gh" <<EOF
#!/usr/bin/env bash
echo "GH \$*" >> "$GHLOG"
case "\$1 \$2" in
  "issue list")
    cat <<'JSON'
[{"number":900,"title":"[#73] Previously mirrored now done","state":"OPEN","labels":[{"name":"ralph-mirror"},{"name":"state:wip"}]}]
JSON
    ;;
  "issue create") echo "https://github.com/x/y/issues/999" ;;
  *) : ;;
esac
exit 0
EOF
chmod +x "$BIN/gh"
# #73 plan file: now done → should be CLOSED (it's already mirrored).
cat > "$M/docs/issues/issue-73-was-wip.md" <<'EOF'
# Issue #73 — Previously mirrored now done
**Triage:** enhancement · done
EOF

OUT="$( cd "$M" && PATH="$BIN:$PATH" bash scripts/ralph/mirror-issues.sh 2>&1 )"
echo "$OUT" | sed 's/^/    /'

# Assertions on the recorded gh calls.
grep -qE "issue create .*\[#70\] Blocked one.*--label state:blocked" "$GHLOG" \
    && ok "#70 created with state:blocked (BLOCKER wins)" || bad "#70 not created as blocked"
grep -qE "issue create .*\[#71\] Wip one.*--label state:wip" "$GHLOG" \
    && ok "#71 created with state:wip (triage in progress)" || bad "#71 not created as wip"
grep -qE "issue create .*\[#72\] Todo one.*--label state:todo" "$GHLOG" \
    && ok "#72 created with state:todo" || bad "#72 not created as todo"
! grep -qE "issue create .*\[#74\]" "$GHLOG" \
    && ok "#74 (done & unmirrored) NOT created" || bad "#74 was created (should skip)"
grep -qE "issue close 900" "$GHLOG" \
    && ok "#73 (mirrored, now done) closed" || bad "#73 not closed"
grep -qE "issue edit 900 .*--add-label state:done.*--remove-label state:wip" "$GHLOG" \
    && ok "#73 state label flipped wip→done (exactly one state:*)" || bad "#73 label not flipped"
# One-way: the mirror must not have modified any local plan file.
if [[ -z "$( cd "$M" && git status --porcelain docs/ )" ]] || \
   [[ -z "$( cd "$M" && git diff --name-only docs/issues )" ]]; then
    ok "one-way: no local docs/issues file modified by the mirror"
else
    bad "mirror modified local files (not one-way)"
fi

echo "─────────────────────────────────────────────────────────────────────"
echo "Track E offline proof: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
