# Issue 18: First autonomous regression run — RS-01 end-to-end

**Status:** Ready to execute (pending pre-session config — see below)
**Created:** 2026-04-28
**Parents:** `issue-16-autonomous-ui-testing.md`, `issue-17-ui-test-http-fallback.md`

## TL;DR for next session

The HTTP listener fallback is shipped (`becd1b2`). Mock-STT injection is verified end-to-end via `curl http://127.0.0.1:9999/...`. Next: drive `RS-01: Recording stops on committed transcript` (in `docs/testing/regression-scenarios.md`) entirely autonomously — UI taps + curl event injection + state assertions — and confirm the scenario passes against `main`.

The whole point: prove that the regression doc can be executed as a script by the agent without human help. Once RS-01 works, the same harness runs RS-02..RS-05.

## What is already done (don't redo)

| SHA | Title |
|---|---|
| `54ceb19` | UI test seam |
| `1fd3362` | Regression scenarios doc |
| `888dba1` | State probe + a11y identifiers |
| `35e142a` | onOpenURL restructure |
| `cb3fee3` | Issue 17 brief |
| `becd1b2` | HTTP listener for UI-test triggers |

Verified working in issue 17:
- `Debug-Local` build with `--ui-test` boots into UI-test mode.
- `curl http://127.0.0.1:9999/stt/{connected,partial,committed,disconnect}` returns 200 and produces `🧪 HTTP: GET …` → `handling URL host=stt path=…` → `🎙️ MockSTT injected event` in logs.
- `accessibilityIdentifier("question.state")` exposes `QuizState` for assertions.

## What to implement

### Step 1 — confirm UI automation tools are loadable

`mcp__XcodeBuildMCP__screenshot` and `snapshot_ui` are already loadable (they were in the deferred-tool list during issue 17). For RS-01 we additionally need **tap** and ideally **swipe / press_button**. If they aren't in the deferred-tool list at session start, the user must enable the UI automation workflow in XcodeBuildMCP config first (see CONFIGURATION.md link in the user-facing instructions below).

**Sanity check at session start:** call `ToolSearch({ query: "mcp__XcodeBuildMCP__tap" })`. If the tool doesn't appear, stop and tell the user. Without taps, RS-01 cannot run end-to-end — only state-probe-only variants would work, and those aren't the goal.

### Step 2 — write a small RS runner

**Where:** `scripts/run_regression_scenario.py` (new file, ~150 lines max)

**Why a script:** the regression doc is human-readable. The runner translates one scenario at a time into the concrete tool calls. Keeps the doc declarative and the orchestration auditable.

**Behavior for RS-01:**
1. Build (`session_show_defaults` → `clean` → `build_sim` → `install_app_sim`).
2. Launch with `--ui-test`.
3. Start log capture.
4. Use `snapshot_ui` to find the coordinate of `home.startQuiz`, then `tap` it.
5. Poll `snapshot_ui` until the `question.state` static-text label reads `askingQuestion` (timeout 5s).
6. Find `question.micButton` coords via `snapshot_ui`, tap it.
7. Poll for `question.state` == `recording` (timeout 5s).
8. Shell-out: `curl -s "http://127.0.0.1:9999/stt/committed?text=Paris" >/dev/null`.
9. Wait up to 3s, then snapshot.
10. Run RS-01 asserts (see `regression-scenarios.md`).
11. Stop log capture, kill the app, write a verdict line.

**Note:** the runner is mostly orchestration glue — reasonable to write as a Python script that shells out to `xcrun simctl` and uses raw `curl`, since XcodeBuildMCP tools are only callable from inside Claude. So in practice the **agent itself** is the runner; the .py is a thin helper for the simctl/curl bits, not for the MCP tool calls. Decide which way to go in the first 2 minutes — I lean toward "the agent orchestrates, no script", because half the steps require MCP tools that a script can't call.

**Alternative (recommended):** skip the script. Have the agent execute the steps directly, log each step's outcome, and produce a one-screen verdict. Save the verdict to `docs/testing/runs/RS-01-<date>.md`.

### Step 3 — produce a run report

**Where:** `docs/testing/runs/RS-01-2026-04-XX.md`

**Contents:** for each step, the action taken, the relevant log/snapshot excerpt, and pass/fail. End with a single `VERDICT: PASS` or `VERDICT: FAIL — <reason>` line so future runs can be diffed.

### Step 4 — only if RS-01 passes

Run RS-02..RS-05 with the same pattern. Don't batch — one report per scenario. If any scenario fails on the first run, stop and triage; it likely indicates a real bug or a flaky assertion in the doc.

## Important caveats and traps

**The `home.startQuiz` identifier:** verify it actually exists in `HomeView.swift` before assuming. Issue 16 added a11y identifiers but the audit may have missed `HomeView`. If missing, add it before running. Same for `confirmation.cancel`, `confirmation.reRecord`, `confirmation.answer`.

**`question.state` is a hidden Text:** `snapshot_ui` returns it as `StaticText` with `accessibilityIdentifier="question.state"`. Read the *label* attribute, not the visible text — the view may render it as `.frame(width: 0, height: 0)` or `.hidden()` and parsers can drop empty strings.

**Polling cadence:** snapshot every 200–300 ms with a hard timeout (3–5 s for state transitions, 18 s for the auto-stop scenario RS-02). Don't `sleep` then snapshot once — the transition can land mid-sleep and you'll miss the window.

**HTTP listener only binds in DEBUG-Local builds.** A Release build won't have the listener — verify `Debug-Local` is the active configuration before the build. Re-binding fails silently if a previous app instance left a TIME_WAIT socket — `allowLocalEndpointReuse` is set so this shouldn't bite, but if curl gets connection refused, kill the app and relaunch.

**Two booted sims.** Use the explicit iPhone 17 Pro id (`918FD36A-8869-48F8-A1F8-3047CB122582`) in raw `xcrun simctl` calls. XcodeBuildMCP picks it up from session defaults automatically.

**WIP files:** the user usually has unrelated WIP in `QuestionView.swift` / `AnswerConfirmationView.swift`. Don't touch them. If a build fails because of WIP compile errors, stop and ask the user to stash before continuing.

**Memory references:**
- `feedback_modular_plans.md` — this brief follows that pattern
- `feedback_no_gitflow.md` — commit directly to main
- `feedback_root_cause_debugging.md` — if RS-01 fails, fix the bug, not the assertion
- `project_ios26_url_scheme_bug.md` — explains why HTTP not URL scheme

## After this issue

If all five scenarios pass: the regression harness is real. Next steps would be:
1. Wire the runner into a `/regression` slash command (or skill) so it can be invoked manually before commits.
2. Consider a pre-push git hook that runs RS-01 as a smoke gate.
3. Expand the suite with scenarios for the answer-confirmation editing feature once that WIP lands on main.
