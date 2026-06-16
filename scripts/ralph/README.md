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
| `done` | Task completed, committed | Verify (gate + reviewer), then **goal-check**; continue or stop if the goal is met |
| `no-tasks` | Worker reports nothing actionable left | **Goal-checked, not trusted** — stop cleanly only if `## Acceptance` is met; else `## BLOCKER` + halt (`exit 7`) |
| `blocked` | Task tried, failed, BLOCKER note written | Count toward consecutive-failure cap |
| `parse-fail` / other | Output didn't include marker | Treat as failure |

The stop decision is owned by the goal-check (#57 57.7), not the worker's self-report — see **Enforced verification** below.

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

## Per-iteration model routing

Each iteration is preceded by a cheap **router pre-pass** (Haiku, $0.50 cap,
read-only). It reads the focus file, finds the same "next task" the worker will
pick, applies a rubric (`prompts/route-model.md`), and prints `ROUTE: <model>`.
The worker iteration then runs on that model (`--model`), with `--fallback-model
sonnet` still as the safety net. The route is logged as `route=<model>` per
iteration. Rubric biases cheap: `sonnet` is the default; `haiku` for trivial
doc/checkbox edits; `opus` for hard multi-file logic or strategy decomposition;
`fable` only for genuine new architecture.

Disable with `RALPH_ROUTER=0` (then every iteration uses `RALPH_DEFAULT_MODEL`,
default `sonnet`).

## Enforced verification (the backbone)

A "done" iteration is **not** accepted on the agent's word. After it commits, two
independent checks must pass before the iteration counts (`#57`):

1. **Scoped test gate (57.2).** The harness re-runs only the suites relevant to the
   changed top-level scope — backend/quiz-pack-api `pytest`, or the iOS `HangsTests`
   flow/state suite (ViewInspector + state dumps, **not** pixel/`.pen` design
   fidelity). Diff-level, not whole-repo. On red the run halts (`exit 5`), a
   `## BLOCKER` is appended to the focus file, and the branch is **not** advanced.
   An iOS failure that is *only* `.stableDump` snapshot drift is surfaced as a
   re-record signal, not a silent auto-fix.
2. **Independent reviewer (57.5 — maker ≠ checker).** If the gate is green, a
   *separate* `claude -p` runs with fresh context (no memory of how the change was
   made), seeing ONLY the iteration's diff + the focus file's acceptance criteria.
   It is prompted to flag **only** correctness / stated-requirement gaps (not style,
   not design) and returns `PASS` / `CONCERNS` (`prompts/review-task.md`). A green
   gate proves the tests pass; the reviewer proves the change actually met its
   acceptance. `CONCERNS` — or any unparseable verdict ("could not confirm" ≠
   "confirmed") — blocks acceptance: the run halts (`exit 6`), appends a reviewer
   `## BLOCKER`, and leaves the branch unpushed.

Disable the reviewer with `RALPH_REVIEWER=0`. Tune it with `RALPH_REVIEWER_MODEL`
(default `sonnet`) and `RALPH_REVIEWER_BUDGET_USD` (default `1.00`). The reviewer
uses a fixed model, not the router, so the "no" stays consistent and independent of
the worker's model.

### The stop-condition: goal-check (57.7 — the "/goal" pattern)

Claude Code has **no native `/goal`** command — this implements the pattern. The
worker deciding the run is finished (its `no-tasks` self-report, or running out of
checkboxes) is the same maker = checker flaw 57.5 fixes on the *work*, applied to the
*stop*. So a separate `claude -p` on a fixed model (**sonnet**, read-only, fresh
context — independent of the worker's router choice) re-checks the
focus file's machine-evaluable `## Acceptance` block (57.6) against the actual repo
state and emits `GOAL_MET: YES|NO` (`prompts/goal-check.md`). It verifies the underlying
evidence for each criterion — a ticked checkbox with no evidence is unmet — and is told
to **bias to NO when unsure** (a false NO keeps the human-reviewed loop working; a false
YES stops early). Criteria marked `[HUMAN]` or needing a simulator/deploy/live dashboard
are out of the loop's reach and don't block the stop.

It runs at two points:

- **After each accepted `done` iteration** (gate GREEN + reviewer PASS) — `GOAL_MET: YES`
  stops the run the moment the stated goal holds, rather than looping until the worker
  happens to report `no-tasks`.
- **On the worker's `no-tasks`** — the run exits clean only if the goal-check agrees;
  `GOAL_MET: NO` (or an unparseable verdict) appends a goal `## BLOCKER` and halts
  (`exit 7`) rather than silently exiting "clean" on an unfinished issue.

A focus file with **no `## Acceptance` block** (queue files, legacy issues) has nothing
machine-evaluable to gate on, so the worker's stop signal is accepted as before
(backward-compatible). Disable with `RALPH_GOALCHECK=0`; tune `RALPH_GOALCHECK_MODEL`
(default `sonnet`) and `RALPH_GOALCHECK_BUDGET_USD` (default `0.50`).

`overnight.sh` treats ralph.sh `exit 4` (end-of-run iOS gate), `exit 5` (scoped gate),
`exit 6` (reviewer CONCERNS), and `exit 7` (goal not met) as gate-red: it stops the chain
and never pushes the branch.

## Overnight orchestration

`overnight.sh` chains **multiple** issues through `ralph.sh` in one unattended
run, isolating everything on a throwaway branch so main stays clean:

```bash
# Read the priority queue (triage output) and burn it down:
scripts/ralph/overnight.sh

# Or run a specific subset / dry-run (default iteration cap each):
scripts/ralph/overnight.sh docs/issues/issue-49-daily-limit-cost-research.md
```

It cuts `ralph/overnight-YYYYMMDD-HHMM`, runs each focus file sequentially under a
global wall-clock budget (`OVERNIGHT_MAX_SECONDS`, default 6h), writes a
consolidated self-contained HTML report (`prompts/report.md` →
`docs/artifacts/ralph-report-*.html`, force-added so it travels with the branch),
then **pushes the `ralph/*` branch only** — never main — and returns to main.

### Priority queue format

`docs/issues/overnight-queue.md` (produced by `/triage`). One focus file per line,
optional `| <max-iters>`; blank lines and `#` comments ignored, a leading `- `
bullet is stripped:

```
# highest priority first — #44 unlocks the agent's own visual self-check
docs/issues/issue-44-screenshot-verify.md | 8
docs/issues/issue-45-pencil-theme.md | 12
docs/issues/issue-49-daily-limit-cost-research.md          # iters omitted → default
```

## Scheduling (agent Mac)

- `com.quizagent.ralph-overnight.plist` — LaunchAgent, fires `run-scheduled.sh` at
  00:30 daily (GUI domain, for Keychain access). Install/kickstart instructions
  are in the plist's leading comment.
- `run-scheduled.sh` — thin launchd entry: sets PATH, cds to the repo, runs
  `overnight.sh` in the foreground (no tmux at 00:30; the lockfile guards against
  colliding with a manual run or the Remote Control session).
- `launch-overnight.sh` — on-demand tmux launcher for when you're awake and want
  to attach and watch.

**Reboot gotcha:** auto-login is OFF on the agent Mac, so after a full reboot the
scheduler won't fire until the `agent` user logs into the GUI desktop.

## Morning review (laptop)

```bash
scripts/ralph/morning.sh
```

Fetches origin, finds the newest `ralph/overnight-*` branch, opens its HTML report,
and prints the commit log, BLOCKERs, and the merge command. It does **not** merge —
reviewing before main is yours.

## Files

```
scripts/ralph/
  ralph.sh                          ← the loop (+ per-iteration router)
  overnight.sh                      ← chains issues on a ralph/* branch, pushes, reports
  run-scheduled.sh                  ← launchd entry (00:30, no tmux)
  launch-overnight.sh               ← on-demand tmux launcher
  morning.sh                        ← laptop review of the overnight branch
  com.quizagent.ralph-overnight.plist ← LaunchAgent (00:30 daily)
  prompts/work-next.md              ← worker system prompt per iteration
  prompts/route-model.md            ← router pre-pass system prompt
  prompts/review-task.md            ← independent reviewer system prompt (57.5)
  prompts/goal-check.md             ← goal stop-condition system prompt (57.7)
  prompts/report.md                 ← overnight report-writer system prompt
  logs/                             ← run-*, iter-*, route-*, goal-*, overnight-* logs (gitignored)
  README.md                         ← you are here
```
