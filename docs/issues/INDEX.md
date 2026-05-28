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
| 28 | [iOS category picker — expand catalog + add `age_appropriate`](issue-28-ios-category-picker-expansion.md) | enhancement · done | `[x]` #28 | Shipped 544eeb3 (2026-05-03) |
| 30 | [Batch-generate questions for new categories](issue-30-batch-generate-categories.md) | enhancement · ready-for-agent | `[ ]` #30 | Was Group E of #21; gate on #28 + #29 |
| 31 | [iOS test hardening — lock in current behavior](issue-31-ios-test-hardening.md) | enhancement · done (Phase 5 partial) | `[x]` #31 | Phases 1–4 done 2026-05-11; Phase 5 snapshots done 2026-05-15 (225 tests green). XCUITest scaffolding written; needs `HangsUITests` added to Hangs-Local scheme Test action |
| 32 | [On-demand question generation service — review + strategy](issue-32-on-demand-generation-service.md) | enhancement · ready-for-human | `[ ]` #32 | Umbrella; Phase 1 decomposed into #33. Post-review revisions C1/C2/C3 (pgvector, non-consumable-only, fact-pool cache) live in #33 |
| 33 | [quiz-pack-api Phase 1 — domain entities + ordered flow](issue-33-quiz-pack-api-phase-1.md) | enhancement · done | `[x]` #33 | 1.1–1.12 code-complete 2026-05-15; awaits next CI green to confirm e2e |
| 34 | [Claude Code context/token optimization](issue-34-claude-context-optimization.md) | infra · done | `[x]` #34 | Tier 1+2.2+3.1/3.2/3.3 hotové; validácia po session restart |
| 35 | [Parallel backlog burn-down via subagents](issue-35-parallel-backlog-burndown.md) | infra · done | `[x]` #35 | Tracks A/B/C all landed 2026-05-15 in single session |
| 36 | [quiz-pack-api Phase 2 — `PackGenerator` orchestrator + voice-quiz pgvector cutover](issue-36-quiz-pack-api-phase-2.md) | enhancement · ready-for-agent | `[ ]` #36 | Decomposed 2026-05-20 from #32 §3 Phase 2; 22 atomic Ralph-ordered tasks targeting `apps/quiz-pack-api/app/orchestrator/` + voice-quiz cutover (#32 §2.4.1) |
| 42 | [Question quality sweep + multichoice activation](issue-42-question-quality-and-mcq.md) | enhancement · ready-for-agent | `[ ]` #42 | Verified 2026-05-28 against codebase (6 plan bugs fixed; see issue Changelog); backend tracks A–D Ralph-suitable (19 atomic tasks after 42.9 split), iOS track E human + simulator. Skipped #37–#41 (reserved for quiz-pack-api Phase 3–6 forecast in `issue-36`). Gated on #36 close |

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
| 26 | [TaskBag — concentrate QuizViewModel task lifecycle](issue-26-task-bag-lifecycle.md) | Done 2026-05-02 |
| 27 | [PendingStore — question pipeline pending state](issue-27-pending-store-question-pipeline.md) | Done 2026-05-02 — unblocks autonomous Groups B-E |
| 29 | [Backfill `source_url` / `source_excerpt` on existing questions](issue-29-backfill-existing-questions.md) | Done 2026-05-04 — local + prod sourced; 8 flagged questions corrected per human review |
| 21 | Generate question Groups B-E | Superseded 2026-05-02 — split into #28 (Group B), #29 (Group D1), #30 (Group E); Groups C/D2/D3 deferred (data-blocked) |

## Conventions

- New issue: created by `/triage` (free text → file) or by hand. Numbering continues the sequence — find next via `ls issue-*-*.md \| sort -V \| tail -1`.
- File header must carry `**Triage:** <category> · <state>` and a `**Status:**` line (free-text human commentary).
- Backfill old files with the `**Triage:**` line opportunistically — when you touch an old issue for any reason, add the line.
- The index is regenerable. If it drifts, run `/triage "regenerate INDEX.md"`.
