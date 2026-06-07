# Issue 43: Maestro MCP — natural-language UI flows on the iOS simulator

**Triage:** enhancement · needs-info
**Status:** Proposed — low-cost upgrade to the agent UI-test loop. Spun out of `docs/research/cross-platform-vs-native-agent-testability.md` (2026-06-02). Needs a human go/no-go before setup (new MCP server + a Maestro Cloud API key decision).
**Created:** 2026-06-02
**Related:** `issue-18-rs01-end-to-end.md`, `issue-17-ui-test-http-fallback.md`, `.claude/skills/regression`

## TL;DR

Add [Maestro](https://github.com/mobile-dev-inc/maestro) as an MCP server next to XcodeBuildMCP so Claude can author and run **human-readable YAML UI flows** against the running Hangs simulator from natural language, inspect the view hierarchy when a flow fails, and propose a corrected selector — all in-conversation. This is **complementary** to the existing RS-01..RS-NN harness, not a replacement.

The research that motivated this concluded: cross-platform frameworks give the agent **no UI-testing advantage** because Maestro MCP works identically on a native iOS app (it drives the compiled `.ipa`, no instrumentation). So we get the "richer natural-language UI testing" benefit **without** leaving SwiftUI.

## Why this, why now

Today the agent drives the simulator with `snapshot_ui` + `tap` + `curl` event injection (issue 18). That works but every scenario is hand-orchestrated step-by-step in the conversation, and the orchestration isn't reusable outside a Claude session. Maestro flows are:

- **Declarative + persistent** — a `.yaml` file (`launchApp`, `tapOn`, `assertVisible`) that lives in the repo and runs the same way in a session, in CI, or by hand.
- **Framework-agnostic** — drives compiled IPA/APK, no app changes needed.
- **Agent-friendly via MCP** — `maestro mcp` exposes the full CLI to Claude: generate a flow from plain language, validate YAML before running, inspect the nested view hierarchy in CSV to debug a failing selector.

It pairs naturally with our existing accessibility identifiers (`question.state`, `question.micButton`, `home.startQuiz`, `confirmation.*`) — Maestro selectors can target those directly.

## Open questions for the human (resolve before Step 1)

1. **Maestro Cloud API key.** Core Maestro (local flows, MCP, Studio) is free and open-source and covers everything we need. Only the **AI commands** (`assertWithAI`, `assertNoDefectsWithAi`) need `MAESTRO_CLOUD_API_KEY`. Decision: **start without the key** (deterministic asserts only) — matches behavioral rule #5 (model only for judgment calls) and #2 (simplicity). Confirm we're OK skipping AI asserts initially.
2. **Scope of first flow.** Recommend porting **only RS-01** (recording stops on committed transcript) to a Maestro flow as a proof, then deciding whether to port the rest. Don't port all RS scenarios up front.
3. **Voice injection inside a flow.** Maestro can't speak into the mic. The flow must still shell out to the HTTP listener (`curl http://127.0.0.1:9999/stt/committed?text=Paris`) for the voice event. Maestro supports `runScript` / shell steps — verify that covers it, or run the curl as a flow-adjacent step the agent fires between Maestro commands.

## What to implement

### Step 1 — install + smoke-test Maestro locally
- Install the Maestro CLI (`curl -fsSL https://get.maestro.mobile.dev | bash` or Homebrew).
- Boot the Hangs sim with the **`Debug-Local`** config + `--ui-test` (HTTP listener only binds in Debug-Local — see issue 18).
- Smoke test with a one-liner flow: `launchApp` → `assertVisible: id: home.startQuiz`. Confirm Maestro sees our a11y identifiers. **If identifiers don't resolve, stop** — that's the whole bet; report before proceeding.

### Step 2 — register Maestro as an MCP server for Claude Code
- Run `maestro mcp` and add it to the Claude Code MCP config (mirror how XcodeBuildMCP is registered).
- Sanity check at session start, same pattern as issue 18: `ToolSearch({ query: "maestro" })` — if no Maestro tools appear, the server isn't wired; stop and tell the user.

### Step 3 — port RS-01 to a Maestro flow
- **Where:** `apps/ios-app/maestro/RS-01-recording-stops-on-commit.yaml` (new dir; keep flows out of the Xcode target so they never touch `.pbxproj`).
- Steps: launch with `--ui-test` → tap `home.startQuiz` → wait for `question.state == askingQuestion` → tap `question.micButton` → wait for `question.state == recording` → **shell: curl committed transcript** → assert `question.state` left `recording` and the confirmation surface is visible.
- Keep the flow declarative; the voice event is the one imperative shell step.

### Step 4 — verdict + decision point
- Run the flow via Maestro MCP, capture the view-hierarchy CSV on any failure, and write a one-screen verdict to `docs/testing/runs/RS-01-maestro-<date>.md` (`VERDICT: PASS` / `VERDICT: FAIL — <reason>`, matching issue 18's format).
- **Decision:** if the flow is clearly more maintainable than the hand-orchestrated version, port RS-02..RS-NN and document Maestro in the `regression` skill as an alternative driver. If it's not a clear win, stop here and keep the existing harness — record why in this issue.

## Caveats & traps

- **Don't touch `.pbxproj`.** Maestro flows are external YAML — keep them out of the Xcode project entirely. (See `issue-ios-agent-development` friction notes in the research report: `.pbxproj` edits by an agent corrupt the project.)
- **Debug-Local only** for the HTTP listener (Release builds have no listener).
- **Explicit sim id** for any raw `xcrun simctl` calls (iPhone 17 Pro `918FD36A-8869-48F8-A1F8-3047CB122582`); Maestro otherwise picks the booted sim.
- **WIP files** — user often has unrelated WIP in `QuestionView.swift` / `AnswerConfirmationView.swift`. Don't touch; if a build fails on WIP compile errors, stop and ask to stash.
- **Voice is still not real-audio tested.** Maestro injects taps + our curl events, not microphone audio. Real-audio E2E remains a manual / device-farm concern — out of scope here (see research report §4).

## Success criteria

- `maestro` tools loadable in a Claude Code session via `ToolSearch`.
- RS-01 runs green as a Maestro flow driven by Claude, with a written verdict.
- A clear documented go/no-go on porting the rest.

## Memory references
- `feedback_modular_plans.md` — fresh-context executable brief
- `feedback_api_first_tools.md` — Maestro CLI/MCP is exactly the API-first, agent-drivable tool we prefer
- `feedback_no_gitflow.md` — commit directly to main
- `project_ios26_url_scheme_bug.md` — why voice events go through the HTTP listener, not URL scheme
