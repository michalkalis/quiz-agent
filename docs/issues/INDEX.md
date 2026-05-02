# Issue Index

Dashboard of all `issue-NN-*.md` files. Updated by `/triage` whenever a `**Triage:**` line changes. The active queue (what's next) lives in `docs/todo/TODO.md` — this index is the full state.

## How to read this

- **Triage** — `<category> · <state>`. Categories: `bug` | `enhancement`. States: `needs-triage` | `needs-info` | `ready-for-agent` | `ready-for-human` | `done` | `wontfix`.
- **TODO** — whether the issue currently sits in `docs/todo/TODO.md`. Empty cell = not on active queue.
- **Notes** — one-line context. For `done` items, the commit or commit range that landed it.

> First-pass triage was inferred from existing `**Status:**` lines on 2026-04-29 and may need reconciliation. Run `/triage` to refine.

## Open

| # | Title | Triage | TODO | Notes |
|---|---|---|---|---|
| 14 | [Hangs Redesign (Pencil → iOS)](issue-14-hangs-redesign.md) | enhancement · ready-for-human | | Phased plan exists; needs design judgment per phase |
| 18 | [First autonomous regression run — RS-01 end-to-end](issue-18-rs01-end-to-end.md) | enhancement · ready-for-agent | | Listener landed in `becd1b2`; ready to drive RS-01 |
| 19 | [Auto-confirm of unedited transcript routes through `resubmitAnswer`](issue-19-auto-confirm-resubmit-bug.md) | bug · needs-info | `[ ]` #19 | Fix path not yet chosen — user needs to pick approach |
| 21 | Generate question Groups B-E | enhancement · ready-for-agent | `[ ]` #21 | Pipeline operational for Group A; B-E queued |
| 26 | [TaskBag — concentrate QuizViewModel task lifecycle](issue-26-task-bag-lifecycle.md) | enhancement · ready-for-agent | `[ ]` #26 | Shrinks 1085-line ViewModel; helps Wave 3 timer bug |
| 27 | [PendingStore — question pipeline pending state](issue-27-pending-store-question-pipeline.md) | enhancement · ready-for-agent | `[ ]` #27 | Unblocks autonomous Groups B-E pipeline |
| – | [Question Pipeline — Remaining Tasks](question-pipeline-remaining.md) | enhancement · needs-triage | | Mixed — some shipped (`c7b0743`), some queued; needs split |

## Done

| # | Title | Notes |
|---|---|---|
| 2 | [Configurable Thinking Time Before Recording](issue-02-thinking-time.md) | Status: DONE |
| 3 | [Translation Validation ("suchy bodliak")](issue-03-translation-validation.md) | Status: DONE |
| 5 | [Slovak Transcription Quality](issue-05-slovak-transcription.md) | Status: IMPLEMENTED |
| 7 | [Result Screen UI/UX](issue-07-result-screen-ux.md) | Status: DONE |
| 8 | [Workflow & Architecture Research](issue-08-workflow-research.md) | DONE 2026-04-03 |
| 10 | [Real-time Word-by-Word Transcription](issue-10-word-by-word-transcript.md) | Status: DONE |
| 11 | [Question Screen Layout](issue-11-question-screen-layout.md) | Status: DONE |
| 12 | [Product Review](issue-12-product-review.md) | Status: DONE |
| 13 | [Repeat Question + Mute Toggle](issue-13-repeat-mute.md) | Status: DONE |
| 15 | [Full rename CarQuiz → Hangs](issue-15-full-rename-carquiz-to-hangs.md) | Executed 2026-04-19 |
| 16 | [Autonomous UI Testing](issue-16-autonomous-ui-testing.md) | Umbrella; work moved into 17 + 18 |
| 17 | [UI-test trigger fallback — HTTP listener](issue-17-ui-test-http-fallback.md) | Landed in `becd1b2` |
| 20 | Timer bug from crash-elimination Wave 3 | Fixed 2026-04-15 in `1a19438` (thinkingTimeTask cancellation); follow-ups `991eaba`, `4d34e3b`; RS-01..08 PASS 2026-04-29/30 |
| 22 | [ChromaDBClient — split into QuestionStore seam](issue-22-chroma-client-split.md) | Done 2026-04-30 |
| 23 | [QuestionRetriever — extend seam to all reads](issue-23-question-retriever-seam.md) | Done 2026-05-02 |
| 24 | [Consolidate `question_to_dict_translated`](issue-24-translated-serializer-locality.md) | Done 2026-04-30 |
| 25 | [Backend session phase — transition guard](issue-25-session-phase-transition-guard.md) | Done 2026-05-02 |

## Conventions

- New issue: created by `/triage` (free text → file) or by hand. Numbering continues the sequence — find next via `ls issue-*-*.md \| sort -V \| tail -1`.
- File header must carry `**Triage:** <category> · <state>` and a `**Status:**` line (free-text human commentary).
- Backfill old files with the `**Triage:**` line opportunistically — when you touch an old issue for any reason, add the line.
- The index is regenerable. If it drifts, run `/triage "regenerate INDEX.md"`.
