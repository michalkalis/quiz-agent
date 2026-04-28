# Issue 17: UI-test trigger fallback — HTTP listener

**Status:** Ready to execute
**Created:** 2026-04-28
**Parent:** `issue-16-autonomous-ui-testing.md` (read first for full context)

## TL;DR for next session

The autonomous UI-test seam from issue-16 is wired and verified up to mock injection. The chosen trigger mechanism — `hangs-test://` URL scheme — does not work on iOS 26.3 simulator due to a LaunchServices bug (`kLSApplicationNotFoundErr -10814`). Replace it with a tiny DEBUG-only HTTP listener inside the app so the test runner can `curl` events from outside.

## What is already done (don't redo)

These commits are on `main`:

| SHA | Title |
|---|---|
| `54ceb19` | UI test seam (UITestSupport, AppState branch, URL handler, MockSTT.injectEvent) |
| `1fd3362` | Regression scenarios (RS-01..RS-05) |
| `888dba1` | State probe + a11y identifiers |
| `35e142a` | onOpenURL restructure (handler always-on, DEBUG-gated body) |

Verified working:
- App built with `Debug-Local` config and launched with `--ui-test` correctly enters UI-test mode.
- Logs confirm: `🧪 UITestSupport: mock services wired` + `🧪 AppState initialized in UI-test mode`.
- `accessibilityIdentifier("question.state")` hidden Text exposes current `QuizState` to UI tests.

The URL routing logic in `UITestSupport.handleTestURL(_:)` (file `apps/ios-app/Hangs/Hangs/Utilities/UITestSupport.swift`) already converts URL paths to mock STT events. **Reuse it from the new HTTP handler — do not duplicate.**

## What to implement

### Tiny HTTP listener inside the app (DEBUG only)

**Where:** `apps/ios-app/Hangs/Hangs/Utilities/UITestSupport.swift`

**Behavior:**
- When `isUITesting` is true at app start, bind a `Network.framework` `NWListener` on `127.0.0.1:9999`.
- Accept HTTP-style requests, parse the request line, route to existing `handleTestURL(_:)` by reconstructing a `URL("hangs-test://<path>?<query>")`.
- Return HTTP `200 OK\r\n\r\n` after dispatching. No response body needed.
- Log every request via `Logger.quiz.info("🧪 HTTP: \(method) \(path)")`.

**Routes** (already supported by `handleTestURL`):
- `GET /stt/partial?text=foo`
- `GET /stt/committed?text=foo`
- `GET /stt/connected`
- `GET /stt/disconnect?msg=...`

**Wire-up:** start the listener from `AppState.init()` UI-test branch, after mocks are built. Hold a strong reference (e.g., `private static var listener: NWListener?` in UITestSupport).

**Concurrency:** Listener uses its own dispatch queue. The handler hop must reach `@MainActor UITestSupport.handleTestURL` — wrap in `Task { @MainActor in await ... }`.

### Update regression scenarios doc

**Where:** `docs/testing/regression-scenarios.md`

Replace every `simctl openurl "hangs-test://..."` instruction with the equivalent curl:
```bash
curl -s "http://127.0.0.1:9999/stt/committed?text=Paris" >/dev/null
```

Keep the original URL scheme handler in `HangsApp.swift` — it costs nothing and may work on real devices.

### Smoke-test it end-to-end

After implementing:
1. `mcp__XcodeBuildMCP__session_set_defaults` with `configuration: "Debug-Local"` (the default Release won't compile the DEBUG block).
2. Clean + build via `mcp__XcodeBuildMCP__clean` then `build_sim`.
3. Install & launch with `--ui-test` arg.
4. From Bash: `curl -s "http://127.0.0.1:9999/stt/committed?text=Paris"`
5. `xcrun simctl spawn <SIM_ID> log show --predicate 'subsystem == "com.missinghue.hangs"' --info --last 30s` — expect to see `🧪 HTTP: GET /stt/committed` and `🧪 MockSTT injected event`.

## Important caveats and traps

**iOS sandboxing for localhost binding:** `NWListener` on `127.0.0.1` works in the simulator without entitlements. On a real device, app sandbox allows localhost in the foreground; background may require `NSLocalNetworkUsageDescription` + on-device permission prompt. Acceptable for DEBUG-only testing.

**Working-tree state at handoff:** the user has uncommitted WIP in
- `apps/ios-app/Hangs/Hangs/Views/QuestionView.swift`
- `apps/ios-app/Hangs/Hangs/Views/AnswerConfirmationView.swift`

This WIP is the "editable transcript" feature (their work, not yours). **Do not touch those files unless absolutely necessary.** The `UITestSupport.swift` and `AppState.swift` paths are clean of WIP.

**Build configuration:** XcodeBuildMCP defaults to Release. You MUST call `session_set_defaults({ configuration: "Debug-Local" })` BEFORE the first `build_sim` or the DEBUG-only seam code will not be compiled in.

**Sim ID:** there are two booted sims (iPhone 17 Pro + iPad Pro 13-inch). When using raw `xcrun simctl`, never use the `booted` alias — pass an explicit ID. The iPhone 17 Pro is `918FD36A-8869-48F8-A1F8-3047CB122582` (verify with `xcrun simctl list devices booted`).

**Stale builds:** XcodeBuildMCP's `build_sim` reports success without recompiling sometimes. If your code changes don't show in the binary (`strings .../Hangs.o | grep <new-string>`), call `clean` first.

**Bundle ID:** `com.missinghue.hangs`. App identifier in Sentry is still `carquiz` (legacy slug).

**Memory references:**
- `project_ios26_url_scheme_bug.md` — the LaunchServices bug, full context
- `feedback_no_gitflow.md` — commit directly to main, no feature branches
- `feedback_modular_plans.md` — this issue follows that pattern
- `feedback_file_size_limit.md` — keep `UITestSupport.swift` under 300 lines
- `feedback_subagent_model_routing.md` — pass explicit `model: sonnet/haiku` to Agent calls

## Suggested commit shape

One commit, conventional format:
```
feat(ios): add DEBUG HTTP listener for UI-test triggers

iOS 26.3 simulator drops custom URL scheme delivery
(kLSApplicationNotFoundErr in LaunchServices). Replace the
hangs-test:// trigger with a 127.0.0.1:9999 NWListener — same routing
logic, reused via UITestSupport.handleTestURL. URL scheme handler
remains in place for real-device fallback.
```

## After this issue

Once the HTTP listener works, run the first agent regression scenario (RS-01) end-to-end. That requires UI taps — XcodeBuildMCP's documented UI automation tools (tap/swipe/screenshot) need to be enabled in the MCP server config; check XcodeBuildMCP's CONFIGURATION.md if `tap` isn't a loadable tool. Without taps, the agent can still verify state transitions by firing curl events to a freshly-launched app and reading the accessibility tree.
