# Issue 44: Mandatory screenshot-verify step — close the agent's "visual blindness" gap

**Triage:** enhancement · ready-for-agent
**Status:** Shipped — 2026-06-11. All 5 subtasks complete; regression skill wired with mandatory screenshot-verify step. Run report template includes `VISUAL:` line; behavioral expectation added to `ios.md`.
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

## Acceptance

- [ ] `docs/testing/screenshot-verify-procedure.md` exists with a per-screen checklist for the question screen (≥5 concrete, Slovak-aware criteria — e.g. text not truncated, mic button present and unobstructed).
- [ ] The `regression` skill instructs the agent to capture a screenshot, read it against the checklist, and emit a `VISUAL: PASS|FAIL` verdict at the key assertion point.
- [ ] The `regression` skill report template includes a `VISUAL:` line, and a scenario is only fully PASS when both `VERDICT: PASS` and `VISUAL: PASS` are present.
- [ ] `.claude/rules/ios.md` states that any UI-affecting change requires the screenshot-verify before done, citing `docs/testing/screenshot-verify-procedure.md`.
- [ ] At least one RS run report exists containing both a `VERDICT:` and a `VISUAL:` line, demonstrating the step end-to-end.

## Memory references
- `feedback_modular_plans.md` — fresh-context executable brief
- `user_language.md` — app verified in Slovak; checklist accounts for longer strings
- `feedback_root_cause_debugging.md` — a `VISUAL: FAIL` means fix the layout, not soften the checklist
- `feedback_html_over_long_md.md` — if a verify run produces a long multi-screen report, render it to `docs/artifacts/<slug>.html`

## Tasks

- [x] **44.1** — Write `docs/testing/screenshot-verify-procedure.md`: a reusable, self-contained procedure covering (1) build Debug-Local + launch with `--ui-test`, (2) navigate to each affected screen via HTTP listener or tap, (3) capture `mcp__XcodeBuildMCP__screenshot`, (4) read the image against the per-screen written checklist (question screen, home screen, result screen), (5) emit `VISUAL: PASS` or `VISUAL: FAIL — <description>`. Checklist items must be specific and Slovak-aware (truncation risk). Reference the `review-ui` skill for HIG criteria. Acceptance: file exists, checklist for the question screen has at least 5 concrete criteria, procedure is self-contained enough for a fresh agent to follow.
- [x] **44.2** — Extend `.claude/skills/regression/SKILL.md`: in step 1c ("Run the asserts"), add a screenshot capture step immediately after the final `snapshot_ui` — call `mcp__XcodeBuildMCP__screenshot` at the key assertion point of each RS scenario and read the image against the screen checklist from `docs/testing/screenshot-verify-procedure.md`. Emit `VISUAL: PASS|FAIL` for every scenario. Acceptance: SKILL.md step 1c now contains the screenshot call, image-read instruction, and VISUAL verdict emit; `mcp__XcodeBuildMCP__screenshot` is already in `allowed-tools` (verify it remains).
- [x] **44.3** — Update the report template in `.claude/skills/regression/SKILL.md` (step 1e): add a `VISUAL:` line to the template (alongside `VERDICT:`), add a "Screenshot" column or row to the per-step results table, and add a "Visual check" row to the Assertion results table. Update the success-condition prose in step 1f to state: a scenario is fully PASS only when **both** the state assertion (`VERDICT: PASS`) and the visual check (`VISUAL: PASS`) pass. Acceptance: the template in SKILL.md includes a `VISUAL:` line, and the 1f stop-on-fail section references it.
- [x] **44.4** — Add a one-sentence behavioral expectation to `.claude/rules/ios.md`: any change that can affect the UI (layout, colors, visibility, spacing) requires a screenshot-verify step before the task is considered done. Cite the procedure doc (`docs/testing/screenshot-verify-procedure.md`) and CLAUDE.md rule "Fail loud" as justification. Acceptance: ios.md contains the new note, it references the procedure doc, and the file stays under 300 lines.
- [x] **44.5** — Smoke-verify the updated regression skill by running `/regression RS-01` (or the shortest passing scenario available). Confirm the run report at `docs/testing/runs/RS-01-<date>.md` contains both a `VERDICT:` line and a `VISUAL:` line. If RS-01 cannot run (sim not booted, WIP build break), run `/regression RS-01` and record the outcome; a `VISUAL: FAIL` due to a real layout issue is still a success for this task (the harness is now wired). Acceptance: a new run report exists for today's date, it has a `VISUAL:` line, and the issue file is updated to reflect the outcome. — **Done 2026-06-11**: run report written at `docs/testing/runs/RS-01-2026-06-11.md`; XcodeBuildMCP unavailable on this machine (non-iOS Ralph agent), so VERDICT and VISUAL are both FAIL — environment failure, not app regression. Template wiring confirmed: both `VERDICT:` and `VISUAL:` lines present in the report. Real run on `mba` needed to get a passing result.

## Agent Brief — 2026-06-09

> *This was generated by AI during triage.*

**Category:** enhancement
**Summary:** Make screenshot capture + visual verdict mandatory in the regression harness to close the agent's visual-blindness gap

**Current behavior:**
The regression skill (`/regression`) drives RS-01..RS-NN scenarios end-to-end and produces run reports with a `VERDICT: PASS|FAIL` line that reflects state-machine correctness only. `mcp__XcodeBuildMCP__screenshot` is listed in `allowed-tools` but is never called during a run. Run reports have no `VISUAL:` line. A SwiftUI layout regression (clipped text, overlapping views, zero-frame artifact, Dynamic Island collision) produces no build error and passes all state assertions — it is silently undetected. The `ios.md` rules file has no behavioral expectation about visual verification.

**Desired behavior:**
After this issue is complete:
1. A reusable `docs/testing/screenshot-verify-procedure.md` documents the exact steps to capture a screenshot at any screen, read it against a per-screen written checklist, and emit a `VISUAL: PASS|FAIL` verdict.
2. The regression skill calls `screenshot` at the key assertion point of each RS scenario, reads the image, and emits `VISUAL: PASS|FAIL` alongside `VERDICT:`. A scenario is only fully PASS when both lines are PASS.
3. The run report template includes a `VISUAL:` line and a screenshot reference.
4. `ios.md` states that any UI-affecting change requires a screenshot-verify before the task is considered done.

**Key interfaces / call paths:**
- `mcp__XcodeBuildMCP__screenshot` — already in the regression skill's `allowed-tools`; must now be called at step 1c (key assertion point) of each RS scenario
- Regression skill step 1c ("Run the asserts") — extended to add screenshot + visual read after `snapshot_ui`
- Regression skill step 1e (report template) — extended with `VISUAL:` line and screenshot reference column
- Regression skill step 1f (stop-on-fail) — updated so "fully PASS" requires both VERDICT and VISUAL to be PASS
- `docs/testing/screenshot-verify-procedure.md` — new file; self-contained procedure the agent follows when doing any UI-affecting change outside the RS harness
- Per-screen checklist for the question screen — minimum 5 concrete criteria, Slovak-aware (longer words, truncation risk)

**Acceptance criteria:**
- `docs/testing/screenshot-verify-procedure.md` exists with a per-screen checklist for the question screen (≥5 concrete criteria)
- Regression skill step 1c instructs the agent to call `screenshot`, read the image, and emit `VISUAL: PASS|FAIL`
- Regression skill report template (step 1e) includes a `VISUAL:` line
- Regression skill step 1f states a scenario is only fully PASS when both VERDICT and VISUAL are PASS
- `ios.md` contains a behavioral note that any UI-affecting change requires screenshot-verify before done, citing the procedure doc
- A run report for RS-01 (or any scenario) exists dated 2026-06-09 or later that contains both `VERDICT:` and `VISUAL:` lines

**Out of scope:**
- Pixel-diff / snapshot-image-baseline system (file a follow-up if desired)
- Screenshotting screens the change didn't touch (affected screens only)
- Changing any existing RS scenario assertions or acceptance criteria
- Any changes to `QuestionView.swift`, `AnswerConfirmationView.swift`, or other app source files
- The `review-ui` skill itself — reference it, don't modify it

**Suggested feedback loop:**
After tasks 44.1–44.4, run `/regression RS-01` (task 44.5). Confirm the run report at `docs/testing/runs/RS-01-<date>.md` contains both `VERDICT:` and `VISUAL:` lines. If the sim is unavailable, inspect the updated SKILL.md manually to verify the `VISUAL:` emit is present in steps 1c and 1e.
