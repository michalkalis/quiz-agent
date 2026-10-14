#!/usr/bin/env bash
# Ralph GitHub Issues mirror (#57 — loop verification backbone, 57.10).
#
# ONE-WAY sync of the LOCAL plan files (docs/issues/issue-NN-*.md — the source of
# truth) to GitHub Issues, so the post-run state (and any BLOCKER) is visible from
# phone/web in the morning without ssh-ing into mba. This NEVER reads GitHub back
# into the local files — GitHub is a read-only mirror.
#
# State (exactly one `state:*` label per mirrored issue):
#   blocked — the plan file contains a `## BLOCKER` section (a run hit a gate/reviewer
#             /goal "no", or a human wrote one). Highest priority — it wins over wip/todo.
#   done    — TODO.md `[x]` for the issue, or its `**Triage:**` state is done/shipped
#             → the GitHub issue is CLOSED (not deleted).
#   wip     — TODO.md `[~]`, or triage in-progress / ready-for-overnight.
#   todo    — any other open state (`[ ]`, ready-for-agent, ready-for-human, needs-*).
#
# Scope: only ACTIVE issues (computed state todo|wip|blocked) get a GitHub issue
# created. A previously-mirrored issue that has since gone done is CLOSED. Ancient
# done issues are never created (no 40-issue spam). What's mirrored vs skipped is
# logged — no silent cap.
#
# Idempotent / regenerable: mirrored issues carry a `ralph-mirror` label and a
# `[#NN]` title prefix, so re-running converges to the same board; delete them all
# and re-run to rebuild it.
#
# Requires: `gh` authenticated with `repo` scope, `python3` (JSON parsing). This is
# BEST-EFFORT: a missing/unauthed gh logs a warning and exits 0 — the mirror must
# never fail the overnight run.
#
# Usage:
#   scripts/ralph/mirror-issues.sh            # sync the active set
#   MIRROR_DRY_RUN=1 scripts/ralph/mirror-issues.sh   # log intended actions, no writes

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"
ISSUE_DIR="$REPO_ROOT/docs/issues"
INDEX_FILE="$ISSUE_DIR/INDEX.md"
TODO_FILE="$REPO_ROOT/docs/todo/TODO.md"
DRY_RUN="${MIRROR_DRY_RUN:-0}"

log() { echo "[mirror] $*"; }

# ── Preflight: gh present + authenticated. Best-effort — never fail the run.
if ! command -v gh >/dev/null 2>&1; then
    log "gh CLI not on PATH — skipping mirror (non-fatal)."
    exit 0
fi
if [[ "$DRY_RUN" != "1" ]] && ! gh auth status >/dev/null 2>&1; then
    log "gh not authenticated — skipping mirror (non-fatal). Run: gh auth login"
    exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
    log "python3 not on PATH — skipping mirror (non-fatal)."
    exit 0
fi

# ── gh wrappers (the only GitHub touch-points; the offline test shims `gh`).
gh_ensure_label() {  # name color description
    [[ "$DRY_RUN" == "1" ]] && { log "DRY: ensure label $1"; return 0; }
    gh label create "$1" --color "$2" --description "$3" >/dev/null 2>&1 \
        || gh label edit "$1" --color "$2" --description "$3" >/dev/null 2>&1 || true
}
gh_list_mirrored() {  # → JSON array [{number,title,state,labels:[{name}]}]
    gh issue list --label ralph-mirror --state all --limit 300 \
        --json number,title,state,labels 2>/dev/null || echo '[]'
}
gh_create() {  # title body label → prints new issue number (or nothing)
    if [[ "$DRY_RUN" == "1" ]]; then log "DRY: create '$1' [$3]"; return 0; fi
    gh issue create --title "$1" --body "$2" --label ralph-mirror --label "$3" 2>/dev/null \
        | grep -oE '[0-9]+$' | tail -1 || true
}
gh_set_state_label() {  # number newlabel current-labels-csv
    local num="$1" want="$2" current="$3"
    local remove=""
    local l
    for l in todo wip blocked done; do
        [[ "state:$l" == "$want" ]] && continue
        [[ ",$current," == *",state:$l,"* ]] && remove="${remove:+$remove,}state:$l"
    done
    if [[ "$DRY_RUN" == "1" ]]; then
        log "DRY: #$num +$want${remove:+ -[$remove]}"; return 0
    fi
    local args=(--add-label "$want")
    [[ -n "$remove" ]] && args+=(--remove-label "$remove")
    gh issue edit "$num" "${args[@]}" >/dev/null 2>&1 || true
}
gh_close() {  # number
    [[ "$DRY_RUN" == "1" ]] && { log "DRY: close #$1"; return 0; }
    gh issue close "$1" >/dev/null 2>&1 || true
}
gh_reopen() {  # number
    [[ "$DRY_RUN" == "1" ]] && { log "DRY: reopen #$1"; return 0; }
    gh issue reopen "$1" >/dev/null 2>&1 || true
}

# ── Human title from the plan file's H1 (strip "# Issue #NN — "); fallback to slug.
issue_title() {  # file NN → title
    local file="$1" nn="$2" h1
    h1="$(grep -m1 '^# ' "$file" 2>/dev/null | sed -E 's/^#[[:space:]]*//')"
    h1="$(echo "$h1" | sed -E "s/^Issue[[:space:]]*#?$nn[[:space:]]*[—:-]?[[:space:]]*//I")"
    if [[ -z "$h1" ]]; then
        h1="$(basename "$file" .md | sed -E "s/^issue-0*$nn-//; s/-/ /g")"
    fi
    echo "$h1"
}

# ── INDEX.md is the curated source of truth for scope + done-ness. Ancient issues
#    (pre-Triage convention) carry their state only there, and a long-shipped issue
#    can still contain a historical `## BLOCKER` section — so we must NOT infer
#    done-ness from the file alone. Parse INDEX into TSV: NN<tab>done(1/0)<tab>triage.
#    An issue under the "## Done" heading is done regardless of its row text; under
#    "## Open" the triage token (after "·") drives wip/todo.
INDEX_TSV="$(awk '
    /^##[[:space:]]/ { sec = tolower($0); next }
    /^\|/ {
        n = split($0, f, "|")
        cell = f[2]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", cell)   # first cell = issue number
        if (cell !~ /^[0-9]+$/) next                    # skip header / separator rows
        # column 3 = "[title](issue-NN-slug.md)"; column 4 = "category · state" (Open).
        link = f[3]
        sub(/^.*\]\(/, "", link); sub(/\.md\).*/, ".md", link); sub(/.*\//, "", link)
        if (link !~ /\.md$/) link = ""
        triage = (n >= 4) ? f[4] : ""
        sub(/.*·[[:space:]]*/, "", triage)              # keep text after the middot
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", triage)
        done = (sec ~ /done/) ? 1 : 0
        print cell "\t" done "\t" tolower(triage) "\t" link
    }
' "$INDEX_FILE" 2>/dev/null)"
index_field() {  # NN fieldno(2=done,3=triage,4=linked-file) → value ("" if absent)
    awk -F'\t' -v n="$1" -v f="$2" '$1==n {print $f; exit}' <<<"$INDEX_TSV"
}

# Canonical plan file for an issue number: the file INDEX links to (umbrellas like
# #54 have many child plan files; only the linked umbrella is the issue), else the
# first matching plan file on disk.
canonical_file() {  # NN → absolute path ("" if none)
    local nn="$1" linked
    linked="$(index_field "$nn" 4)"
    if [[ -n "$linked" && -f "$ISSUE_DIR/$linked" ]]; then
        echo "$ISSUE_DIR/$linked"; return
    fi
    # Regex match (not a shell glob — `0*` must mean zero-or-more zeros so that
    # non-zero-padded files like issue-48-… are found, while #4 ≠ #44).
    local m
    m="$(ls "$ISSUE_DIR" 2>/dev/null | grep -E "^issue-0*$nn-" | head -1)"
    [[ -n "$m" ]] && echo "$ISSUE_DIR/$m"
}

# TODO.md checkbox(es) for NN → most-active of [~]>[ ]>[x] (an issue can recur, e.g.
# #30 has a done-scope line and a parked grow line — prefer the active one).
todo_state_for() {  # NN → wip|todo|done|"" (absent)
    local nn="$1" best=""
    while IFS= read -r line; do
        case "$line" in
            *"[~]"*) best="wip"; break ;;
            *"[ ]"*) [[ "$best" != "wip" ]] && best="todo" ;;
            *"[x]"*) [[ -z "$best" ]] && best="done" ;;
        esac
    done < <(grep -E "^- \[.\] #$nn[ \)]" "$TODO_FILE" 2>/dev/null)
    echo "$best"
}

# Canonical state. Precedence: done (INDEX/triage/TODO) > blocked (live file marker,
# active issues only) > wip > todo. Done wins over a stale `## BLOCKER`. Returns
# "skip" for an issue with no presence signal anywhere (don't invent a board entry).
compute_state() {  # file NN → blocked|done|wip|todo|skip
    local file="$1" nn="$2"
    local idx_done idx_triage ftriage tstate
    idx_done="$(index_field "$nn" 2)"
    idx_triage="$(index_field "$nn" 3)"
    ftriage="$(grep -m1 -iE '^\*\*Triage:\*\*' "$file" 2>/dev/null | sed -E 's/.*·[[:space:]]*//; s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')"
    tstate="$(todo_state_for "$nn")"

    # 1. Done — authoritative, beats a historical BLOCKER. A TODO `[x]`-only box
    #    (todo_state_for returns "done" only when no `[~]`/`[ ]` line exists for NN)
    #    is an explicit human done-mark and is usually the most current signal, so it
    #    wins even when INDEX/triage lag (e.g. #54 closed in TODO, still Open in INDEX).
    if [[ "$idx_done" == "1" ]] \
       || [[ "$idx_triage" =~ ^(done|shipped|wontfix)$ ]] \
       || [[ "$ftriage" =~ ^(done|shipped|wontfix)$ ]] \
       || [[ "$tstate" == "done" ]]; then
        echo "done"; return
    fi
    # No presence signal at all → don't create a phantom issue.
    if [[ -z "$idx_done" && -z "$idx_triage" && -z "$ftriage" && -z "$tstate" ]]; then
        echo "skip"; return
    fi
    # 2. Blocked — live marker in the (still-active) plan file.
    if grep -qE '^## BLOCKER' "$file" 2>/dev/null; then echo "blocked"; return; fi
    # 3. Wip.
    if [[ "$tstate" == "wip" ]] \
       || [[ "$idx_triage" =~ (in.progress|ready-for-overnight) ]] \
       || [[ "$ftriage" =~ (in.progress|ready-for-overnight) ]]; then
        echo "wip"; return
    fi
    # 4. Default open.
    echo "todo"
}

# ── Ensure the label vocabulary exists.
gh_ensure_label "ralph-mirror" "ededed" "Mirrored from local docs/issues by Ralph (read-only)"
gh_ensure_label "state:todo"    "c5def5" "Ralph mirror: not started"
gh_ensure_label "state:wip"     "1d76db" "Ralph mirror: in progress"
gh_ensure_label "state:blocked" "d73a4a" "Ralph mirror: BLOCKER in the plan file"
gh_ensure_label "state:done"    "0e8a16" "Ralph mirror: done"

# ── Snapshot existing mirrored issues as TSV (NN<tab>number<tab>state<tab>labelcsv).
#    macOS ships bash 3.2 (no associative arrays), so keep it as text + awk lookups.
EXISTING="$(gh_list_mirrored | python3 -c '
import json, sys, re
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
for it in data:
    m = re.match(r"\[#(\d+)\]", it.get("title", ""))
    if not m:
        continue
    nn = m.group(1)
    num = str(it.get("number", ""))
    st = it.get("state", "").lower()
    labels = ",".join(l.get("name", "") for l in it.get("labels", []))
    print("\t".join([nn, num, st, labels]))
')"
ex_field() {  # NN fieldno(2=number,3=state,4=labels) → value ("" if absent)
    awk -F'\t' -v n="$1" -v f="$2" '$1==n {print $f; exit}' <<<"$EXISTING"
}

# ── Unique issue numbers across INDEX + the plan-file directory (umbrellas like #54
#    have many child files but are ONE issue — dedupe by NN, use the canonical file).
ALL_NN="$( { echo "$INDEX_TSV" | cut -f1
            for f in "$ISSUE_DIR"/issue-*.md; do
                [[ -f "$f" ]] && basename "$f" | sed -E 's/^issue-0*([0-9]+).*/\1/'
            done ; } | grep -E '^[0-9]+$' | sort -un )"

# ── Sync loop, one entry per issue number.
created=0; updated=0; closed=0; skipped=0
for nn in $ALL_NN; do
    file="$(canonical_file "$nn")"
    [[ -n "$file" && -f "$file" ]] || { skipped=$((skipped + 1)); continue; }
    base="$(basename "$file")"

    state="$(compute_state "$file" "$nn")"
    exists="$(ex_field "$nn" 2)"

    # Unindexed / no-signal issue and not already mirrored → leave it off the board.
    if [[ "$state" == "skip" ]]; then
        [[ -z "$exists" ]] && { skipped=$((skipped + 1)); continue; }
        state="todo"   # somehow mirrored before → keep it visible rather than orphan it
    fi

    title="[#$nn] $(issue_title "$file" "$nn")"
    want_label="state:$state"

    if [[ -z "$exists" ]]; then
        if [[ "$state" == "done" ]]; then
            skipped=$((skipped + 1)); continue   # never create ancient done issues
        fi
        # Single-line body so the marker stays greppable; GitHub renders it fine.
        body="Mirrored from \`docs/issues/$base\` by Ralph (#57 57.10) — read-only, edit the plan file. <!-- ralph-mirror:$nn -->"
        num="$(gh_create "$title" "$body" "$want_label")"
        log "created #$nn → $title [$want_label]${num:+ (gh #$num)}"
        created=$((created + 1))
    else
        local_state="$(ex_field "$nn" 3)"
        gh_set_state_label "$exists" "$want_label" "$(ex_field "$nn" 4)"
        if [[ "$state" == "done" && "$local_state" != "closed" ]]; then
            gh_close "$exists"; log "closed #$nn (done) gh #$exists"; closed=$((closed + 1))
        elif [[ "$state" != "done" && "$local_state" == "closed" ]]; then
            gh_reopen "$exists"; log "reopened #$nn ($state) gh #$exists"
        fi
        log "updated #$nn → [$want_label] gh #$exists"
        updated=$((updated + 1))
    fi
done

log "done: $created created, $updated updated, $closed closed, $skipped skipped (done & unmirrored)."
exit 0
