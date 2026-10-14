#!/usr/bin/env bash
# Offline proof for #57 Track F (plan-readiness pre-flight, 57.13) — same shim style
# as the A/B/C/E trip-tests. No model spend: a fake `claude` parses its -p prompt and
# returns a canned marker (READY_VERDICT / RALPH_RESULT / …). Runs the REAL ralph.sh
# pre-flight against throwaway focus files in a throwaway git repo. Run from anywhere.
#
#   scripts/ralph/test/test-track-f.sh
#
# Asserts the differential readiness gate:
#   (1) fields tier, no `## Acceptance`      → exit 8 + readiness BLOCKER, no iteration ran
#   (2) fields tier, no `**Reversibility:**` → exit 8 + readiness BLOCKER (C6 undeclared)
#   (3) fields tier, reversibility class `b` → exit 8 + readiness BLOCKER (non-`a` excluded)
#   (4) full tier, /ready-check NOT-READY    → exit 8 + readiness BLOCKER, ready-check ran
#   (5) full tier, /ready-check READY        → run STARTS (readiness GREEN), no BLOCKER
#   (6) soft tier (short run)                → gate skipped, run STARTS even if unready
#   (7) RALPH_READYCHECK=0                    → gate disabled, run STARTS even if unready

set -uo pipefail
SRC_RALPH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d -t ralph-trackf-XXXX)"
trap 'rm -rf "$WORK"' EXIT

# ── Fake `claude`: decide the canned response from the -p prompt keyword.
BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-p" ]]; then prompt="${2:-}"; shift 2; continue; fi
  shift
done
case "$prompt" in
  *READY_VERDICT*)   echo "${FAKE_READY_OUTPUT:-READY_VERDICT: READY}" ;;
  *RALPH_RESULT*)    echo 'RALPH_RESULT: {"status":"no-tasks","task":"none"}' ;;
  *REVIEW_VERDICT*)  echo "REVIEW_VERDICT: PASS" ;;
  *GOAL_MET*)        echo "GOAL_MET: YES" ;;
  *ROUTE:*)          echo "ROUTE: sonnet" ;;
  *)                 echo "noop" ;;
esac
exit 0
EOF
chmod +x "$BIN/claude"

# ── Throwaway repo carrying a copy of scripts/ralph (ralph.sh + prompts).
REPO="$WORK/repo"; mkdir -p "$REPO/scripts/ralph" "$REPO/docs/issues"
cp "$SRC_RALPH_DIR/ralph.sh" "$REPO/scripts/ralph/"
cp -R "$SRC_RALPH_DIR/prompts" "$REPO/scripts/ralph/"
( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t \
    && git add -A && git commit -qm init )

ACCEPT_BLOCK=$'\n## Acceptance\n\n- [ ] something concrete a shell script can check (pytest tests/foo.py::bar GREEN)\n'

# Write a focus issue file with the requested header fields, commit it clean.
make_focus() {  # <name> <reversibility-line-or-empty> <with-acceptance:1/0>
    local name="$1" revline="$2" accept="$3"
    local rel="docs/issues/$name.md" abs="$REPO/docs/issues/$name.md"
    {
        echo "# Issue 90: $name"
        echo ""
        echo "**Triage:** enhancement · ready-for-agent"
        [[ -n "$revline" ]] && echo "$revline"
        echo "**Status:** test fixture"
        [[ "$accept" == "1" ]] && printf '%s' "$ACCEPT_BLOCK"
    } > "$abs"
    ( cd "$REPO" && git add -A && git commit -qm "fixture $name" )
    echo "$rel"
}

# Run ralph.sh pre-flight only. Router/reviewer/goalcheck off so the only claude
# calls are the readiness /ready-check and (if the run starts) the no-tasks worker.
run_ralph() {  # <focus-rel> <iters> [extra env assignments...]
    local focus="$1" iters="$2"; shift 2
    ( cd "$REPO" && env PATH="$BIN:$PATH" \
        RALPH_ROUTER=0 RALPH_REVIEWER=0 RALPH_GOALCHECK=0 \
        "$@" bash scripts/ralph/ralph.sh "$focus" "$iters" 1 ) > "$WORK/out.log" 2>&1
    echo $?
}

blocker_present() { grep -q "plan-readiness pre-flight (NOT-READY)" "$REPO/$1"; }
iter_ran() { grep -q "iteration 1/" "$WORK/out.log"; }

echo "── 57.13 plan-readiness pre-flight ──────────────────────────────────"

# (1) fields tier, missing ## Acceptance → block.
f=$(make_focus t1-no-accept "**Reversibility:** a" 0)
rc=$(run_ralph "$f" 12)
{ [[ "$rc" == "8" ]] && blocker_present "$f" && ! iter_ran; } \
  && ok "(1) no ## Acceptance → exit 8 + BLOCKER, no iteration" \
  || bad "(1) expected exit 8+BLOCKER+no-iter, got rc=$rc"

# (2) fields tier, missing **Reversibility** → block (C6 undeclared).
f=$(make_focus t2-no-rev "" 1)
rc=$(run_ralph "$f" 12)
{ [[ "$rc" == "8" ]] && blocker_present "$f" && grep -qi "Reversibility" "$WORK/out.log"; } \
  && ok "(2) no **Reversibility** → exit 8 + BLOCKER (C6)" \
  || bad "(2) expected exit 8+BLOCKER+C6, got rc=$rc"

# (3) fields tier, reversibility class b → block (non-`a` excluded from unattended).
f=$(make_focus t3-rev-b "**Reversibility:** b" 1)
rc=$(run_ralph "$f" 12)
{ [[ "$rc" == "8" ]] && blocker_present "$f"; } \
  && ok "(3) reversibility class 'b' → exit 8 + BLOCKER (human checkpoint)" \
  || bad "(3) expected exit 8+BLOCKER, got rc=$rc"

# (4) full tier (overnight), /ready-check NOT-READY → block; ready-check actually ran.
f=$(make_focus t4-notready "**Reversibility:** a" 1)
rc=$(run_ralph "$f" 12 RALPH_OVERNIGHT=1 FAKE_READY_OUTPUT="READY_VERDICT: NOT-READY — under-specified")
{ [[ "$rc" == "8" ]] && blocker_present "$f" && grep -q "full tier" "$WORK/out.log"; } \
  && ok "(4) full tier + /ready-check NOT-READY → exit 8 + BLOCKER" \
  || bad "(4) expected exit 8+BLOCKER+full-tier, got rc=$rc"

# (5) full tier, /ready-check READY on a well-formed issue → run STARTS, no BLOCKER.
f=$(make_focus t5-ready "**Reversibility:** a" 1)
rc=$(run_ralph "$f" 12 RALPH_OVERNIGHT=1 FAKE_READY_OUTPUT="READY_VERDICT: READY")
{ [[ "$rc" == "0" ]] && ! blocker_present "$f" && grep -q "readiness GREEN" "$WORK/out.log" && iter_ran; } \
  && ok "(5) full tier + READY → readiness GREEN, run starts, no BLOCKER" \
  || bad "(5) expected exit 0 + GREEN + iter, got rc=$rc"

# (6) soft tier: a short run is not gated even though the issue is unready.
f=$(make_focus t6-short "" 0)
rc=$(run_ralph "$f" 5)
{ [[ "$rc" == "0" ]] && ! blocker_present "$f" && grep -q "soft tier" "$WORK/out.log" && iter_ran; } \
  && ok "(6) short run (iters<10) → gate skipped, run starts" \
  || bad "(6) expected exit 0 + soft-skip + iter, got rc=$rc"

# (7) explicit disable overrides even a long unready run.
f=$(make_focus t7-disabled "" 0)
rc=$(run_ralph "$f" 12 RALPH_READYCHECK=0)
{ [[ "$rc" == "0" ]] && ! blocker_present "$f" && iter_ran; } \
  && ok "(7) RALPH_READYCHECK=0 → gate disabled, run starts" \
  || bad "(7) expected exit 0 + run starts, got rc=$rc"

echo "─────────────────────────────────────────────────────────────────────"
echo "Track F offline proof: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
