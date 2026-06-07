# Issue 44: Mandatory screenshot-verify step — close the agent's "visual blindness" gap

**Triage:** enhancement · ready-for-agent
**Status:** Proposed — low-cost, no new dependencies. Spun out of `docs/research/cross-platform-vs-native-agent-testability.md` (2026-06-02). Ready to execute; no human decision needed.
**Created:** 2026-06-02
**Related:** `.claude/skills/regression`, `.claude/skills/review-ui`, `issue-18-rs01-end-to-end.md`, `issue-31-ios-test-hardening.md`

## TL;DR

The single real gap of native agent development (confirmed in the research report §3): **the agent can't see what it rendered.** SwiftUI that compiles cleanly can still render wrong — overlapping views, clipped text, wrong spacing, a `.hidden()` that swallowed a label — and produces **no build error**. The fix is not a different framework; it's making a **screenshot capture + visual check mandatory** after any UI-affecting change.

This formalizes something the harness can already do (`mcp__XcodeBuildMCP__screenshot` is loadable today) into a required, documented step so it stops being optional/ad-hoc.

## Why this matters here

We have a strong build-test-fix loop (XcodeBuildMCP headless build + `snapshot_ui` + RS scenarios), but every link in it is **structural**: it proves state-machine correctness (`question.state == recording`) and accessibility wiring, **not** that the screen looks right. A layout regression sails through green tests. For a glanceable, voice-first driving app, a visually broken question screen is a real failure even when the state machine is perfect.

`snapshot_ui` returns the element tree (positions, identifiers) — useful, but it's not pixels. A `screenshot` is the only signal that catches render-time defects. Cross-platform wouldn't help: Flutter/RN agents have the exact same blindness.

## What to implement

### Part A — a reusable verify step (the core)
Define one repeatable procedure the agent runs after any change that can affect the UI:

1. Build `Debug-Local` for the iPhone 17 Pro sim, install, launch (`--ui-test` when state injection is needed).
2. Drive to each affected screen (reuse RS navigation: `home.startQuiz` → question screen, etc.).
3. **Capture `mcp__XcodeBuildMCP__screenshot`** at each screen.
4. **Read the screenshot back** (the agent inspects the image) and check against an explicit, written checklist for that screen — not a vibe. Example for the question screen:
   - question text fully visible, not clipped/truncated
   - mic button present, tappable size, not overlapped
   - status pill legible, correct color for state
   - no overlapping/cut-off text, no zero-frame artifacts leaking visible
   - safe-area / Dynamic Island not covering content
5. Emit a verdict: `VISUAL: PASS` or `VISUAL: FAIL — <what's wrong>` with the screenshot referenced.

The checklist content can lean on the existing **`review-ui`** skill (HIG-based SwiftUI critique) for the per-screen criteria — don't reinvent it; call it.

### Part B — wire it into the regression flow
- Extend the `regression` skill so each RS scenario's report includes **at least one screenshot** at its key assertion point, and a `VISUAL:` line alongside the existing `VERDICT:` (state) line. A scenario is only fully PASS when **both** the state assertion and the visual check pass.
- Update `docs/testing/runs/` report template to carry the screenshot reference + `VISUAL:` line.

### Part C — document it as a behavioral expectation
- Add a short note to the `regression` skill (and optionally a line in `.claude/rules/ios.md`) that **any UI-affecting change requires a screenshot-verify before it's considered done** — direct application of CLAUDE.md rule #12 "Fail loud" ('"Tests pass" is wrong if … UI wasn't verified').

## Scope guards (rule #2, #3 — keep it small)
- **No new dependency, no new MCP server** — `screenshot` is already loadable.
- **Not** building a pixel-diff / snapshot-image-baseline system. That's a separate, heavier idea (flaky across OS/font changes); the agent reading the screenshot against a written checklist is the deliberately simple version. If we later want regression baselines, file a follow-up — don't gold-plate this one.
- **Don't** screenshot screens the change didn't touch. Affected screens only.

## Caveats & traps
- **`snapshot_ui` ≠ screenshot.** The tree can say an element exists at a coordinate while it's visually clipped or behind another view. The image is the source of truth for Part A; keep both.
- **Hidden/zero-frame probes** (`question.state` is a `.hidden()` Text) won't show in the screenshot — that's fine, it's a test probe, not UI. Don't flag its absence as a visual defect.
- **Two booted sims** — pin iPhone 17 Pro (`918FD36A-8869-48F8-A1F8-3047CB122582`).
- **Debug-Local** for anything needing the HTTP listener / `--ui-test`.
- **WIP files** — don't touch unrelated WIP in `QuestionView.swift` / `AnswerConfirmationView.swift`; stop and ask to stash if they break the build.
- **Slovak UI** — the app is tested in Slovak mode; checklist text legibility checks should expect Slovak strings (longer words; watch for truncation).

## Success criteria
- A documented, repeatable verify step exists and the agent can run it end-to-end on the question screen, producing a screenshot + `VISUAL:` verdict.
- The `regression` skill's RS reports include a screenshot + `VISUAL:` line at the key assertion point.
- "Fail loud" is satisfied: a layout regression that passes state asserts is still caught by the visual check.

## Memory references
- `feedback_modular_plans.md` — fresh-context executable brief
- `user_language.md` — app verified in Slovak; checklist accounts for longer strings
- `feedback_root_cause_debugging.md` — a `VISUAL: FAIL` means fix the layout, not soften the checklist
- `feedback_html_over_long_md.md` — if a verify run produces a long multi-screen report, render it to `docs/artifacts/<slug>.html`
