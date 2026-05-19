# Ralph Loop

Autonomous task burndown for Claude Code. Spawns fresh `claude -p` sessions in a loop, each scoped to **one** atomic task from a focus file. Stops when the focus file is empty, a hard cap is reached, or three consecutive failures.

Inspired by the "Ralph Loop" pattern; adapted for this repo's `docs/issues/issue-NN-*.md` convention and the `[ ]/[~]/[x]` checkbox state in `docs/todo/TODO.md`.

## Why

- **Fresh context per iteration** — no token bloat, each task gets a clean window (CLAUDE.md rule #6).
- **State in git, not in chat** — every iteration commits or it didn't happen.
- **Atomic units** — a task is "done" only when its tests pass and the commit lands.
- **Surface conflicts, don't average them** — on failure, Ralph reverts and writes a `BLOCKER` note for human review (CLAUDE.md rules #7, #12).

## Prerequisites

- `claude` CLI in `$PATH` and authenticated.
- Clean working tree (Ralph refuses to start with uncommitted changes).
- Focus file with a clear next task. Either:
  - `- [ ]` checkboxes in the issue plan file (preferred), **or**
  - A strategy doc — first iteration will decompose it into a child plan.

## Usage

```bash
# Burn down a specific issue
scripts/ralph/ralph.sh docs/issues/issue-30-batch-generate-categories.md

# With custom limits (max iterations, USD budget per iteration)
scripts/ralph/ralph.sh docs/issues/issue-30-*.md 30 10
```

Defaults: 20 iterations, $5 per iteration, 25-minute hard timeout per iteration (requires `gtimeout` from `brew install coreutils` — falls back to budget-only if unavailable).

## What each iteration does

1. Reads the focus file + `docs/todo/TODO.md`.
2. Identifies the single smallest concrete next task.
3. Implements it (surgical, no scope creep).
4. Runs the relevant tests.
5. Commits atomically (code + focus-file update). **Does not push.**
6. Emits a `RALPH_RESULT: {...}` line so the harness knows what happened.

Full protocol in `prompts/work-next.md`.

## Status codes

| Status | Meaning | Harness behavior |
|---|---|---|
| `done` | Task completed, committed | Continue to next iteration |
| `no-tasks` | Focus file has nothing actionable left | Exit cleanly |
| `blocked` | Task tried, failed, BLOCKER note written | Count toward consecutive-failure cap |
| `parse-fail` / other | Output didn't include marker | Treat as failure |

After 3 consecutive failures Ralph stops and waits for human review. Exponential backoff (2^N seconds) between failed iterations to ride out API hiccups.

## Operator workflow (the morning after)

```bash
# What did Ralph do?
cat scripts/ralph/logs/run-YYYYMMDD-HHMMSS.log

# Review commits made by Ralph
git log $(grep "start sha:" scripts/ralph/logs/run-*.log | tail -1 | awk '{print $NF}')..HEAD --stat

# Spot-check the focus file for BLOCKER sections
grep -n "BLOCKER" docs/issues/issue-NN-*.md

# Push if happy
git push
```

## Running it overnight on the new MacBook

Two options:

### Option A — tmux (simplest)

```bash
tmux new -s ralph
scripts/ralph/ralph.sh docs/issues/issue-30-batch-generate-categories.md 30
# Ctrl-B then D to detach. The Mac can stay awake; in System Settings → Battery,
# disable sleep on power adapter.
# Reattach next morning: tmux attach -t ralph
```

### Option B — launchd

Schedule via `~/Library/LaunchAgents/com.quizagent.ralph.plist`. Trigger nightly. Add later when you've validated the loop is well-behaved.

## Safety notes

- **`--permission-mode bypassPermissions`** is used so iterations don't pause on tool prompts. The MacBook running Ralph is your trusted dev machine — Ralph cannot escape the repo and shell. Do not run Ralph against an untrusted focus file.
- **No push.** Every iteration commits locally. You decide what reaches origin in the morning.
- **Working tree must be clean** at start — Ralph refuses otherwise, to prevent accidentally mixing autonomous + manual diffs.
- **Per-iteration cost cap** via `--max-budget-usd`; default $5. If an iteration blows through this, Claude exits and Ralph treats it as a failure.

## When NOT to use Ralph

- For iOS work that requires the simulator (Ralph can't drive Xcode UI reliably).
- For tasks without clear acceptance criteria (Ralph will drift; spend the time decomposing first).
- When you're about to ship something time-sensitive — Ralph commits often, debugging a wrong direction is cheap, but a half-finished Phase 2 in the middle of a deploy window is not.

## Files

```
scripts/ralph/
  ralph.sh                  ← the loop
  prompts/work-next.md      ← system prompt template per iteration
  logs/                     ← run-* and iter-* logs (gitignored)
  README.md                 ← you are here
```
