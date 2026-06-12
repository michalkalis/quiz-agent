# Plan — Pencil 1:1 sync + snapshot re-record (cross-cutting, run LAST)

**Parent:** `issue-54-design-refresh-regressions.md` (§54.8 item 3, and the founder's "Pencil 1:1"
requirement) · **Priority:** P1 · **Status:** ongoing — run **after** the UI-changing fixes land so
nothing is touched twice.

## Why one cross-cutting task
The founder's directive: **Pencil must match the app 1:1** (`design/quiz-agent.pen`); later Pencil
becomes the source of truth. Several #54 fixes change pixels (54.9 done; 54.1, 54.2, 54.6 pending).
Doing Pencil + snapshot re-record once, after the UI is final, avoids re-touching the same frames.

## Part A — Pencil 1:1 sync
Use the **pencil MCP** tools (never `Read`/`Grep` on `.pen` — it's encrypted). Start with
`get_editor_state(include_schema: true)` to load the schema, then `batch_get` the target frames,
`batch_design` to edit, `get_screenshot`/`snapshot_layout` to verify.

Frames to reconcile with the shipped app (accumulate as fixes land):
- **Result** (`X4o4l` correct / `31AzE` incorrect) — **remove the "Try this question again" button**
  (54.9, already removed in-app, commit `40b9ff0`). Also confirm the recap-text colour decision for
  54.14 (`secondaryValueColor`) and apply it to both app + Pencil together.
- **Voice question** (`f9csl` ready / `uGhZg` recording) — scroll region + pinned Record/Skip (54.2).
- **Home / cards** — dark-mode variants once 54.1 Phase 2 (asset-catalog) is designed.
- **Minimized quiz** — add the redesigned frame (none exists today) for 54.6.
- **Error** (`Fwafe`) — copy/CTA per `AppErrorModel.from` (54.15).

## Part B — re-record the 3 stale snapshots
After the UI is final, re-record the dump baselines left red on purpose:
`HomeViewSnapshotTests` (idle), `QuestionViewSnapshotTests` (asking, recording). Baselines live at
`HangsTests/Snapshots/__Snapshots__/.../*.txt` (`.stableDump`, deterministic). Re-record via the
SnapshotTesting record mode, then **review the diff** so you re-baseline the *intended* change only —
don't blindly accept (rule #6: assert the meaningful part).

> **Diff root cause known (2026-06-12 verification run):** all three failures are pure **model
> drift**, not pixel/layout drift — the live dump adds four fields the baselines predate:
> `Question.headlineAnswer`, `QuizViewModel._mcqVoiceMatchedKey`,
> `MockAudioService.micPermissionResult`, `HomeView.onReplayOnboarding`. When re-recording,
> these four are the *expected* delta; anything else in the diff is unintended and must be
> investigated, not accepted.

## Part C — process gate (54.8 item 1)
The branch was committed red because the overnight loop/CI didn't run the full `xcodebuild test`
action. Add a gate so design-scale changes can't land red. Also re-check the **ThreadSanitizer BUS
crash** (`objc_release`) seen in the full-suite UI-test phase — determine if it's a real data race or
teardown noise; if real, file/fix it.

> **TSan update (2026-06-12 verification run):** full unit (TSan-compiled) + RS UI-test runs did
> **not** reproduce the crash — consistent with sporadic teardown noise. Keep a watch item, but
> don't block the CI-gate work on it; downgrade to "investigate only if it recurs in the gated runs".

Also fold in here (test hygiene, same files): **54.20** — remove the stale `QuestionPage.statusPill`
member + snapshot-test comments (see `issue-54-data-cleanups.md` §54.20) if not already done.

## Done criteria
- [ ] Every shipped #54 UI change is reflected in `design/quiz-agent.pen` (screenshots match app).
- [ ] The 3 snapshots re-recorded with reviewed diffs; full `xcodebuild test` green.
- [ ] CI gate added; TSan crash triaged. Update parent §54.8.
