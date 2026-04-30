---
name: regression
description: Run iOS regression scenarios (RS-01..RS-NN) end-to-end on the simulator. Drive UI via XcodeBuildMCP + curl HTTP listener, assert state-machine correctness, write per-run report, stop on first failure.
allowed-tools: Bash, Read, Write, Glob, Grep, mcp__XcodeBuildMCP__clean, mcp__XcodeBuildMCP__build_sim, mcp__XcodeBuildMCP__get_sim_app_path, mcp__XcodeBuildMCP__install_app_sim, mcp__XcodeBuildMCP__launch_app_sim, mcp__XcodeBuildMCP__stop_app_sim, mcp__XcodeBuildMCP__start_sim_log_cap, mcp__XcodeBuildMCP__stop_sim_log_cap, mcp__XcodeBuildMCP__snapshot_ui, mcp__XcodeBuildMCP__screenshot, mcp__XcodeBuildMCP__tap, mcp__XcodeBuildMCP__touch, mcp__XcodeBuildMCP__list_sims, mcp__XcodeBuildMCP__boot_sim, mcp__XcodeBuildMCP__open_sim, mcp__XcodeBuildMCP__session_show_defaults, mcp__XcodeBuildMCP__session_set_defaults
argument-hint: "[RS-01|RS-02|...|all] (default: all)"
model: sonnet
---

# Run iOS Regression Scenarios

Drive `docs/testing/regression-scenarios.md` end-to-end on the iPhone 17 Pro
simulator. Each scenario produces `docs/testing/runs/<RS-id>-<date>.md`
with a final `VERDICT: PASS|FAIL` line. **Stop on the first FAIL.**

This is a **fail-and-report** skill — never silently fix the app or relax a
scenario assertion. If a scenario fails, write the report and halt.

## Constants (do not change without updating the doc)

| Thing | Value |
|---|---|
| Workspace | `apps/ios-app/Hangs/Hangs.xcodeproj` (or `.xcworkspace` if present) |
| Scheme | `Hangs-Local` |
| Configuration | `Debug-Local` |
| Simulator | iPhone 17 Pro · `918FD36A-8869-48F8-A1F8-3047CB122582` |
| Bundle root (Debug-Local) | `<DerivedData>/.../Build/Products/Debug-Local-iphonesimulator/Hangs.app` |
| HTTP listener | `http://127.0.0.1:9999` (DEBUG-Local builds only) |
| Bundle id | inferred via `get_app_bundle_id` if needed |

## Required deferred tools

Before running, confirm these XcodeBuildMCP tools are loadable. If any are
missing the user must enable the UI-automation workflow in their MCP config
(`~/.claude/mcp/xcodebuildmcp.json` or equivalent) and re-run.

- `mcp__XcodeBuildMCP__build_sim`
- `mcp__XcodeBuildMCP__install_app_sim`
- `mcp__XcodeBuildMCP__launch_app_sim`
- `mcp__XcodeBuildMCP__start_sim_log_cap` / `stop_sim_log_cap`
- `mcp__XcodeBuildMCP__snapshot_ui`
- `mcp__XcodeBuildMCP__tap`

If `tap` is missing, stop and tell the user — the suite cannot run.

## Argument parsing

`$ARGUMENTS` is one of:
- *(empty)* or `all` — run every scenario in `docs/testing/regression-scenarios.md` in order
- `RS-NN` — run a single scenario

If a single id is given, validate it exists in the regression doc; if not,
list available ids and stop.

## Procedure

### 0. Pre-flight (once per invocation)

1. Confirm simulator is booted (`list_sims` → `boot_sim` if needed,
   `open_sim` to bring up Simulator.app).
2. Build once at the top of the run, even if running a single scenario,
   so we know the app is fresh:
   ```
   clean({ scheme: "Hangs-Local", configuration: "Debug-Local" })
   build_sim({
     scheme: "Hangs-Local",
     configuration: "Debug-Local",
     simulatorName: "iPhone 17 Pro",
     workspacePath or projectPath: <discovered>
   })
   ```
3. Resolve app path via `get_sim_app_path` (must end in
   `Debug-Local-iphonesimulator/Hangs.app` — not `Debug-iphonesimulator`).
   If a different config slipped in, fail loudly: it means `Debug-Local`
   wasn't honoured.
4. `install_app_sim`.

### 1. Per-scenario loop

For each scenario id (in order if `all`):

#### 1a. Launch in UI-test mode (order matters)

```
launch_app_sim({
  simulatorUuid: "918FD36A-...",
  bundleId: <bundle id>,
  args: ["--ui-test"]
})
```

Confirm the HTTP listener bound:
```bash
curl -sf -o /dev/null -w '%{http_code}' http://127.0.0.1:9999/stt/connected
```
Must return `200`. If not, kill the app (`stop_app_sim`) and relaunch once;
on a second failure write `VERDICT: FAIL — listener never bound` and stop.

**Then** start log capture **without** `captureConsole` (this is the trap
RS-01 surfaced — `captureConsole: true` relaunches the app and drops
`--ui-test`):

```
start_sim_log_cap({
  simulatorUuid: "918FD36A-..."
  // NO captureConsole — structured logs only
})
```

Save the returned `logSessionId`.

#### 1b. Drive the steps

Read the scenario block in `docs/testing/regression-scenarios.md`. For each
step, translate to MCP tool calls (see "Step → tool map" below). Between
state transitions, **poll** rather than sleep:

- Snapshot every 250–300 ms.
- Hard timeout: 5 s for fast transitions, 18 s for the auto-stop scenario,
  or whatever the spec mandates.
- A single `sleep` then one snapshot will miss fast transitions.

State probe priority (today's tree restored the dedicated probe; older
WIP trees only had the pill):
1. `accessibilityIdentifier == "question.state"` → read `AXLabel`.
2. Fallback: `accessibilityIdentifier == "question.statusPill"` → read `AXValue`.
3. Confirmation sheet visible (`confirmation.state.{transcript,processing}` present)
   ⇒ underlying state is `processing` for assertion purposes (see RS-01 lesson).

When the confirmation sheet overlays QuestionView, `question.statusPill`
won't be in the snapshot tree — that's expected.

#### 1c. Run the asserts

Capture one final snapshot at the assertion point. Evaluate every assert
in the scenario block. Any single failure ⇒ scenario VERDICT: FAIL.

Crash check: scan the captured log for `EXC_`, `signal `, or
`Terminating app due to`. Any hit ⇒ FAIL.

#### 1d. Stop log capture, kill app

```
stop_sim_log_cap({ logSessionId: <saved> })
stop_app_sim({ simulatorUuid: "918FD36A-...", bundleId: <bundle id> })
```

#### 1e. Write the report

Path: `docs/testing/runs/<RS-id>-YYYY-MM-DD.md` (today's date). If a file
for the same id+date already exists, suffix `-2`, `-3`, etc.

Use the structure modeled by `RS-01-2026-04-29.md`:

```markdown
# <RS-id> — <title>

**Date:** <YYYY-MM-DD>
**Build:** Hangs-Local · Debug-Local · iPhone 17 Pro sim (918FD36A-8869-48F8-A1F8-3047CB122582)
**Tree:** <git rev-parse --short HEAD> + <wip note if dirty>
**Driver:** Claude (XcodeBuildMCP UI automation + curl HTTP listener)

## VERDICT: PASS | FAIL — <reason if FAIL>

## Per-step results
| # | Step | Result | Evidence |

## Assertion results
| Assert | Expected | Actual | Result |

## State timeline (from log)
```
<relevant State: A → B and 🎙️ / 🧪 lines>
```

## Notes & deviations from spec
<…>

## Followups (separate from <RS-id> verdict)
<…>

VERDICT: PASS | FAIL — <reason>
```

Always end with a final `VERDICT:` line so future runs can be diffed.

#### 1f. Stop on first FAIL

If the scenario verdict is FAIL and `$ARGUMENTS` was `all`, **do not run the
remaining scenarios**. Surface the failure to the user with a one-line
summary and the path to the report. The user (or a separate fix session)
decides whether to triage and re-run.

## Step → tool map (canonical translations)

| Spec step | Tool call |
|---|---|
| Tap `<id>` | `snapshot_ui` to confirm presence/coords, then `tap({ id: "<id>" })`. If `tap` by id fails because of a shadowed parent identifier (RS-05 lesson), fall back to `tap` by coordinate using the snapshot frame center. |
| Wait for `question.state == X` | Poll `snapshot_ui` 250 ms intervals; check probe priority above; timeout per spec. |
| Wait for confirmation sheet | Poll for any node with `accessibilityIdentifier` matching `confirmation.state.transcript` or `confirmation.state.processing`. |
| `curl -s "http://127.0.0.1:9999/..." >/dev/null` | `Bash` tool, exact URL from spec. Verify HTTP 200 with `-w '%{http_code}'`. |
| Wait Ns | `sleep N` only when the spec says "wait N seconds with no STT events" (e.g. RS-02). For state transitions, always poll. |
| Snapshot+assert | Final `snapshot_ui`; evaluate the spec's assert list against the tree + captured log. |

## Important traps (do not relearn the hard way)

1. **Launch BEFORE log capture.** `start_sim_log_cap({captureConsole: true})`
   relaunches the app without args, dropping `--ui-test`. Always launch
   first, then start log capture with no `captureConsole`.
2. **Debug-Local config, not Debug.** Verify the resolved app path contains
   `Debug-Local-iphonesimulator`. A plain `Debug` build will not have the
   HTTP listener.
3. **HTTP listener only in DEBUG-Local builds.** Release / TestFlight does
   not bind. If `curl /stt/connected` returns connection-refused after
   launch, kill the app and relaunch once; if still failing, fail the run.
4. **Don't tap blind.** Always snapshot first to get coords or confirm the
   target id exists. Identifiers can be shadowed by a parent
   `accessibilityIdentifier` (RS-05 lesson — `confirmation.state.transcript`
   was shadowing `confirmation.reRecord` / `confirmation.confirm`).
5. **Polling, not sleeping.** Fast transitions (recording → processing)
   land in tens of ms. A single 1-second sleep + snapshot can land
   *after* the next-state, missing the assertion window.
6. **Two booted sims.** If multiple are booted, always pin to
   `918FD36A-8869-48F8-A1F8-3047CB122582` explicitly in raw `xcrun simctl`
   calls. XcodeBuildMCP picks it up via `simulatorUuid:`.
7. **WIP files.** If `git status` shows unrelated WIP that breaks the build,
   stop and ask the user to stash. Don't silently revert.
8. **Auto-confirm race (bug-A).** RS-05 fails today because the
   AnswerConfirmationView auto-confirm timer fires `resubmitAnswer` ~10 s
   after the sheet appears, before the agent can tap cancel/Re-record.
   This is **expected to fail** until bug-A is fixed; do not paper over
   it. If the failure mode matches the RS-05 timeline (REJECTED `processing
   → processing`, then `processing → error`), record it verbatim and stop.

## Output to user

After the run, print one line per scenario:
```
RS-01 PASS  docs/testing/runs/RS-01-2026-04-29.md
RS-02 PASS  docs/testing/runs/RS-02-2026-04-29.md
RS-03 FAIL  docs/testing/runs/RS-03-2026-04-29.md  — <reason>
(remaining scenarios skipped)
```

## Pre-push smoke

This skill drives the full RS-01..RS-NN suite via XcodeBuildMCP — that requires
Claude in the loop and is too heavy for a git hook. A complementary, *opt-in*
shell hook at `scripts/pre-push-rs01-smoke.sh` runs a **lite RS-01** as a smoke
gate on pushes to `main`. It catches the failure mode that breaks the entire
regression harness: the DEBUG-Local HTTP listener no longer binding on
`127.0.0.1:9999`.

What the hook checks (no Claude required):

1. The push targets `refs/heads/main` (otherwise: silent pass-through).
2. An iPhone simulator is already booted, found within 5s (otherwise:
   `VERDICT: SKIP` to stderr, exit 0 — the hook never blocks on env issues).
3. `Hangs.app` (`com.missinghue.hangs`) is installed on that sim.
4. Launching with `--ui-test` succeeds.
5. `GET http://127.0.0.1:9999/stt/connected` returns 200.
6. `GET http://127.0.0.1:9999/stt/committed?text=Paris` returns 200.

Total runtime is hard-capped at 90s (real RS-01 takes ~75s; the lite hook
is typically <15s once the app is installed).

**Failure conditions** (only these block the push):
- Listener never bound after launch (build broken, `UITestSupport` regression).
- `/stt/committed` rejected after listener was up.

Bypass per-push: `git push --no-verify`.

### Install / uninstall

The hook is **not** installed by default. To enable:

```bash
./scripts/install-pre-push-hook.sh
```

This copies `scripts/pre-push-rs01-smoke.sh` to `.git/hooks/pre-push` and
backs up any existing hook to `.git/hooks/pre-push.backup.<ts>`.

To remove: `rm .git/hooks/pre-push`.

### When to skip vs. fix

- `SKIP — no booted simulator`: env issue, push proceeds. Boot a sim with
  `open -a Simulator` if you want the gate active next time.
- `SKIP — Hangs.app not installed`: build+install once via Xcode or
  `/build-ios`, push again.
- `FAIL — HTTP listener never bound`: real regression. Run the full RS-01
  via this skill (`/regression RS-01`) before pushing again, or bypass with
  `--no-verify` if you've already triaged.
