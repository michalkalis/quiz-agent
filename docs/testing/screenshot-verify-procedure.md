# Screenshot-Verify Procedure

Use this procedure after any change that can affect UI layout, colors,
visibility, or spacing. It captures a screenshot at each affected screen,
reads the image against a written checklist, and emits a `VISUAL:` verdict.

**Skill complement:** This procedure covers ad-hoc per-change verification.
For regression runs, the `/regression` skill embeds it at the assertion point
of each RS scenario.

**HIG grounding:** For deeper per-screen HIG critique, call the `/review-ui`
skill and pass the captured screenshot path. This procedure's checklists focus
on the most likely defects for this codebase — they are not exhaustive.

---

## Pre-conditions

- iPhone 17 Pro simulator booted (`918FD36A-8869-48F8-A1F8-3047CB122582`).
- `Debug-Local` build installed and launched (HTTP listener required for
  navigation; do **not** use a `Debug` or Release build).
- `mcp__XcodeBuildMCP__screenshot` available — it is in the `regression`
  skill's `allowed-tools`; outside that skill, confirm via ToolSearch before
  calling.

---

## Procedure

### Step 1 — Build and install

```
clean({ scheme: "Hangs-Local", configuration: "Debug-Local" })
build_sim({
  scheme: "Hangs-Local",
  configuration: "Debug-Local",
  simulatorName: "iPhone 17 Pro",
  workspacePath or projectPath: <discovered>
})
install_app_sim({ ... })
```

Verify the resolved app path contains `Debug-Local-iphonesimulator/Hangs.app`.
A `Debug-iphonesimulator` path means Debug-Local was not honoured — stop and
fix the build invocation.

### Step 2 — Launch in UI-test mode

```
launch_app_sim({
  simulatorUuid: "918FD36A-8869-48F8-A1F8-3047CB122582",
  bundleId: <bundle id>,
  args: ["--ui-test"]
})
```

Confirm the HTTP listener bound:
```bash
curl -sf -o /dev/null -w '%{http_code}' http://127.0.0.1:9999/stt/connected
```
Must return `200`. If not, kill and relaunch once; on second failure, abort and
write `VISUAL: FAIL — HTTP listener never bound`.

### Step 3 — Navigate to each affected screen

Navigate only to screens touched by the change — do not screenshot unaffected
screens.

| Screen | Navigation |
|---|---|
| HomeView | App is on Home immediately after launch with `--ui-test`. |
| QuestionView | Tap `home.startQuiz`; wait for `question.state` label `askingQuestion`. |
| ConfirmationSheet | QuestionView → tap `question.micButton` → wait `recording` → inject `committed` transcript → wait for `confirmation.state.transcript`. |
| ResultView / showingResult | Complete a quiz cycle through the confirmation sheet. |

Between navigation steps, poll `snapshot_ui` at 250–300 ms intervals rather
than sleeping.

### Step 4 — Capture screenshot

At each affected screen, call:
```
mcp__XcodeBuildMCP__screenshot({
  simulatorUuid: "918FD36A-8869-48F8-A1F8-3047CB122582"
})
```

Read the returned image immediately (the tool returns it as a visual artifact).

### Step 5 — Evaluate against the checklist

For each screen, evaluate every checklist item below. Mark each item `✓` or
`✗ — <description>`. One or more `✗` items ⇒ `VISUAL: FAIL`.

### Step 6 — Emit verdict

```
VISUAL: PASS
```
or
```
VISUAL: FAIL — <comma-separated list of failed checklist items>
```

A `VISUAL: FAIL` means the layout is broken. Fix the layout — do not soften
the checklist (see memory `feedback_root_cause_debugging.md`).

If the verify run produces more than one screen's output (multi-screen
report), render it to `docs/artifacts/visual-verify-<slug>-<date>.html`
and reply `open <path>`.

---

## Per-screen checklists

### HomeView

1. App title / logo fully visible, not clipped by Dynamic Island or status bar.
2. "Začať kvíz" (Start Quiz) button readable, tappable-sized (≥44 pt), not
   overlapping other elements.
3. Category picker (if visible) labels not truncated — Slovak category names
   are long; check for `…` mid-word.
4. No zero-frame artifacts (invisible-but-present containers leaking a visible
   border or background).
5. Safe-area respected — no content in the bottom home-indicator region.

### QuestionView (key screen — 7 criteria)

1. **Question text fully visible** — the entire question string rendered, not
   clipped at the bottom of the text container. Slovak sentences are
   significantly longer than English equivalents; multi-line wrap must not
   overflow into the mic button area.
2. **Mic button present and not overlapped** — `question.micButton` is fully
   visible, its tap area is not covered by another view, minimum 44 pt.
3. **Status pill legible** — `question.statusPill` text is readable; color
   matches the documented state palette (e.g. red for `recording`, neutral
   for `askingQuestion`); not cropped.
4. **No overlapping / z-fighting views** — no two sibling views visually
   overlap in a way that obscures readable content (e.g. the error banner
   behind the question card, or a transition ghost frame).
5. **Dynamic Island / notch clearance** — question text begins below the
   Dynamic Island (or notch cutout); no text is obscured by system chrome.
6. **Safe-area bottom** — mic button and any bottom affordances are above the
   home indicator safe-area inset; nothing clipped at screen bottom.
7. **Zero-frame probe not visible** — the hidden `question.state` probe Text
   is correctly hidden; no invisible element causing visible whitespace or
   layout shift.

### ConfirmationSheet

1. Transcribed answer text fully visible, not truncated — Slovak answers can
   be multi-word.
2. Action buttons (`confirmation.confirm`, `confirmation.cancel`,
   `confirmation.reRecord`) all within the sheet boundary, not clipped.
3. Sheet does not extend behind the home indicator safe area.
4. Edit affordance (`confirmation.edit` pencil) visible and not overlapped.

### ResultView

1. Result state (correct / incorrect) clearly communicated — color and/or
   icon matches the evaluation outcome.
2. Correct answer text (if shown) fully visible, not truncated.
3. Navigation affordance (next question / finish) readable and tappable.
4. No leftover confirmation sheet ghost behind the result view.

---

## Slovak-language truncation risk

The app is verified in Slovak mode. Slovak words are on average 30–40 %
longer than their English counterparts. The following checklist items are
elevated-risk for truncation:

- QuestionView question text (multi-line; watch for trailing `…`)
- Category labels in HomeView picker
- Error banner text in QuestionView (`question.errorBanner`)
- Button labels in ConfirmationSheet

When evaluating these items, zoom into the text region in the screenshot
image before marking the item `✓`. A clipped syllable at the edge of a
container is a `VISUAL: FAIL` even if the state machine passed.

---

## Traps

- **`snapshot_ui` ≠ screenshot.** The element tree can report an element
  at a coordinate while it is visually clipped or behind another view.
  The screenshot is the source of truth for visual checks.
- **Hidden probe is expected absent.** `question.state` is a `.hidden()`
  Text — its absence in the screenshot is correct, not a defect.
- **Two booted sims.** Always pass `simulatorUuid: "918FD36A-8869-48F8-A1F8-3047CB122582"`
  explicitly to `screenshot`.
- **WIP build breaks.** If `git status` shows unrelated WIP in
  `QuestionView.swift` / `AnswerConfirmationView.swift` that breaks the
  build, stop and ask the user to stash before proceeding.
