#!/usr/bin/env bash
# Ralph Morning — run this on the laptop to review what the overnight run did.
#
#   scripts/ralph/morning.sh
#
# Fetches origin, finds the newest ralph/overnight-* branch, opens its HTML report
# in the browser, and prints the commit log, BLOCKERs, and the merge command.
# It does NOT merge — reviewing before main is yours.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

echo "[morning] fetching origin…"
git fetch origin --prune

# Newest ralph/overnight-* branch on origin (lexical sort works: TS is zero-padded).
BRANCH="$(git for-each-ref --sort=-refname --format='%(refname:short)' \
    'refs/remotes/origin/ralph/overnight-*' | head -1 || true)"

if [[ -z "$BRANCH" ]]; then
    echo "[morning] no origin/ralph/overnight-* branch found. Did the overnight run push?" >&2
    exit 1
fi

# Strip the "origin/" prefix for the local-name merge command.
LOCAL_BRANCH="${BRANCH#origin/}"
TS="${LOCAL_BRANCH#ralph/overnight-}"
REPORT_REL="docs/artifacts/ralph-report-$TS.html"

echo "[morning] latest run: $BRANCH"
echo ""

# Extract + open the report (it lives on the branch; artifacts/ is gitignored locally).
if git cat-file -e "$BRANCH:$REPORT_REL" 2>/dev/null; then
    TMP_REPORT="$(mktemp -t ralph-report-XXXX).html"
    git show "$BRANCH:$REPORT_REL" > "$TMP_REPORT"
    echo "[morning] opening report → $TMP_REPORT"
    open "$TMP_REPORT" 2>/dev/null || echo "[morning] open failed; report at $TMP_REPORT"
else
    echo "[morning] ⚠ no report at $BRANCH:$REPORT_REL — see commit log below."
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "Commits (main..$BRANCH):"
echo "════════════════════════════════════════════════════════════════"
git log "main..$BRANCH" --stat --oneline || true

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "BLOCKERs in focus files on the branch:"
echo "════════════════════════════════════════════════════════════════"
git grep -n "BLOCKER" "$BRANCH" -- 'docs/issues/*.md' 2>/dev/null || echo "  (none found)"

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "GitHub board (#57 57.10 mirror — state of the active issues):"
echo "════════════════════════════════════════════════════════════════"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh issue list --label ralph-mirror --state open \
        --json number,title,labels \
        --jq '.[] | "  \(.title)\t[\(.labels | map(.name) | map(select(startswith("state:"))) | join(","))]"' \
        2>/dev/null || echo "  (mirror not run yet — populates after the next overnight run)"
else
    echo "  (gh unavailable — skip)"
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "To merge after review (fast-forward only — review the diff + BLOCKERs first):"
echo "════════════════════════════════════════════════════════════════"
echo "  git checkout main"
echo "  git merge --ff-only $BRANCH   # or: git merge --no-ff $BRANCH"
echo "  git push"
echo ""
echo "  # if you only want some commits, cherry-pick from $BRANCH instead."
