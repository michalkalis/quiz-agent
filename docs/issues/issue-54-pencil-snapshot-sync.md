# Plan — Pencil 1:1 sync + snapshot re-record (cross-cutting, run LAST)

**Parent:** `issue-54-design-refresh-regressions.md` (§54.8 item 3, and the founder's "Pencil 1:1"
requirement) · **Priority:** P1 · **Status:** ✅ DONE 2026-06-12 (third session) — see
implementation notes at the bottom.

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
- [x] Every shipped #54 UI change is reflected in `design/quiz-agent.pen` (screenshots match app).
- [x] The snapshots re-recorded with reviewed diffs; full `xcodebuild test` green.
- [x] CI gate added; TSan crash triaged (watch item, did not recur). Update parent §54.8.

---

## Implementation notes (2026-06-12, third session)

**Part A — Pencil sync (remaining items):** 54.18 typed-answer toggle ("Type answer instead",
keyboard icon, `$text-secondary`) added to voice frames `f9csl` (enabled) and `uGhZg` (recording —
opacity 0.45 mirroring `canInteract == false`), placed between the context hint and the
Record/Skip row. Settings frame `Jjcs5` about card (`hui1y`): added the two rows the app has and
the design lacked — "Replay intro" (chevron) and the 54.17 "Reset question history" row
(`137 / 500` in `$accent-pink`), with hairlines. All three frames screenshot-verified, no overflow.
(Result/Error/Minimized frames were already synced in earlier #54 sessions.)

**Part B — snapshot re-record:** all **5** drifted baselines re-recorded (not 3 — the P2 batch
added `streakBeforeLastAnswer` + `sessionCorrect/IncorrectCount`, drifting ResultView's two
baselines as well). Diffs reviewed line-by-line: only the predicted model-drift fields + the 54.18
`@State` fields (`_showTextInput`, `_textAnswer`, `_isTextFieldFocused`) — no unintended changes.

Two latent test bugs found by the full-suite run and fixed structurally (rule: root cause, not
re-record-and-hope):
- **HomeViewSnapshotTests order-dependence:** it dumped the shared `QuizViewModel.preview`
  singleton; the 54.17 `SettingsViewHistoryTests` host views on that same singleton, and hosting
  subscribes → `@Published` storage flips `.value`→`.publisher` → dump pulls in unstable
  Observation internals. Fix: fresh per-test VM mirroring `.preview` (same pattern as the other
  snapshot suites).
- **`tapSubmitsOnceWithoutVoiceMatch` flake:** fixed 900 ms sleep vs. the 500 ms delayed submit
  under parallel-suite load — switched to the poll-up-to-~3 s pattern from the handoff decisions.

**Part C — process gate:** two layers. (1) `scripts/ralph/ralph.sh` end-of-run gate: if the run
touched `apps/ios-app/**`, it runs `xcodebuild test -only-testing:HangsTests` and exits 4 with a
loud `TEST GATE RED` verdict on failure, so the nightly scheduler surfaces a red run (UI tests
excluded — too slow/flaky for unattended headless; CI covers them). (2) `ios-ci.yml` now also
triggers on push to `ralph/**` (red is visible at review-push time, before merge) with a
`concurrency` group cancelling superseded runs to bound macOS-runner cost. TSan BUS crash: did not
recur in any of this session's full runs — stays a watch item per the 2026-06-12 downgrade.

## In-sim verify pass (2026-06-13, follow-up session)

The batched verifies owed by this plan — artifact:
`docs/artifacts/visual-verify-54-pencil-snapshot-sync-2026-06-13.html` (VISUAL: PASS).

- **54.18** toggle + typed input row + full typed submit: PASS (matches Pencil `f9csl`).
- **54.17** Settings reset row: PASS (live counter 2/500 → confirm → 0/500).
- **CompletionView**: unreachable in the UI-test harness (mock session never advances phase) —
  both `displayScore` paths stay unit-covered (`QuizCompleteSummaryTests`,
  `CompletionViewInspectorTests`); noted in the artifact, no harness scope added.
- **54.16 found a real bug**: the MCQ voice match resolved but the submit threw
  `URLError(.cancelled)` → OOPS screen. `handleCommittedTranscript` cancels the `.sttEvent`
  listener task it runs inside, then the MCQ branch submitted inline from that cancelled
  context — same self-cancellation class as 54.5; invisible to the direct-call unit tests and
  to prod (no MCQ questions shipped yet, #42 Track F parked). Fixed with the 54.5
  unstructured-task hop (awaited, so direct callers stay synchronous); regression test
  `mcqVoiceMatchSubmitsThroughEventStream` drives the real event stream — verified red
  without the fix, green with it. Full unit suite green after fix (385/385).
- **CI run 27445302573 triaged first-hand**: macOS job red = ONE starved-runner flake
  (`autoStopCapFiresOnRerecord`; 394/395 passed, all 11 UI tests passed — the predicted
  `testRS*`/micButton failures did NOT occur). `waitUntil` hardened (real 1 ms sleep per spin
  + post-deadline re-check). The API-verify job's uv issue remains (fix on main post-merge).
