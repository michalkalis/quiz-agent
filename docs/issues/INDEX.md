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
| 18 | [First autonomous regression run — RS-01 end-to-end](issue-18-rs01-end-to-end.md) | enhancement · done | | RS-01 PASS `fa892c9` (2026-04-30); RS-01..08 reports landed. Reconciled by triage 2026-06-09 (was stale ready-for-agent) |
| 19 | [Auto-confirm of unedited transcript routes through `resubmitAnswer`](issue-19-auto-confirm-resubmit-bug.md) | bug · done | `[x]` #19 | Fixed `fa892c9` — resubmit path resolved, RS-01 PASS. Reconciled by triage 2026-06-09 (was stale needs-info; conflicted with TODO `[x]`) |
| 28 | [iOS category picker — expand catalog + add `age_appropriate`](issue-28-ios-category-picker-expansion.md) | enhancement · done | `[x]` #28 | Shipped 544eeb3 (2026-05-03) |
| 30 | [Batch-generate questions for new categories](issue-30-batch-generate-categories.md) | enhancement · ready-for-agent | `[ ]` #30 | Core prod-sync DONE `bab26b1`. **Founder decision 2026-06-09: NO disney/football top-up** — instead grow **`general` → ~500, incrementally** (~52 now). `launch-issue30.sh` repurposed (task 30.G, re-runnable, `MAX_ITERS=6`/run, dedup-guarded). Post-launch; runs on mba when reachable |
| 31 | [iOS test hardening — lock in current behavior](issue-31-ios-test-hardening.md) | enhancement · done (Phase 5 partial) | `[x]` #31 | Phases 1–4 done 2026-05-11; Phase 5 snapshots done 2026-05-15 (225 tests green). XCUITest scaffolding written; needs `HangsUITests` added to Hangs-Local scheme Test action |
| 32 | [On-demand question generation service — review + strategy](issue-32-on-demand-generation-service.md) | enhancement · ready-for-human | `[ ]` #32 | Umbrella; Phase 1 decomposed into #33. Post-review revisions C1/C2/C3 (pgvector, non-consumable-only, fact-pool cache) live in #33 |
| 33 | [quiz-pack-api Phase 1 — domain entities + ordered flow](issue-33-quiz-pack-api-phase-1.md) | enhancement · done | `[x]` #33 | 1.1–1.12 code-complete 2026-05-15; awaits next CI green to confirm e2e |
| 34 | [Claude Code context/token optimization](issue-34-claude-context-optimization.md) | infra · done | `[x]` #34 | Tier 1+2.2+3.1/3.2/3.3 hotové; validácia po session restart |
| 35 | [Parallel backlog burn-down via subagents](issue-35-parallel-backlog-burndown.md) | infra · done | `[x]` #35 | Tracks A/B/C all landed 2026-05-15 in single session |
| 36 | [quiz-pack-api Phase 2 — `PackGenerator` orchestrator + voice-quiz pgvector cutover](issue-36-quiz-pack-api-phase-2.md) | enhancement · done | `[x]` #36 | Shipped 2026-05-28 — `PackGenerator` 6-stage orchestrator, duplicate generators deleted, M-2 retry endpoint, voice-quiz read-path cut over to pgvector (ChromaDB read-only until Phase 6/#41) |
| 42 | [Question quality sweep + multichoice activation](issue-42-question-quality-and-mcq.md) | enhancement · ready-for-agent | `[ ]` #42 | Retriever now admits `text_multichoice` (`tests/test_question_retriever_filters.py`, 100 passed). **Founder decision 2026-06-09: generate a fresh MCQ batch first** (gen→verify→score, brief review), then founder approves what makes sense → import to prod. **Ralph-ready 2026-06-10**: Track F (42.19–42.24) + `launch-issue42-mcq.sh`; Workflow distractor-screen (42.21) before founder review. iOS track E (45.x) human + simulator |
| 43 | [Maestro MCP — natural-language UI flows on the iOS sim](issue-43-maestro-mcp-ui-flows.md) | enhancement · wontfix | | **Won't-do 2026-06-09** (launch decision #10a): RS harness + #44 screenshot-verify cover the loop; second framework not worth it |
| 44 | [Mandatory screenshot-verify step](issue-44-screenshot-verify-step.md) | enhancement · ready-for-agent | `[ ]` #44 | From research 2026-06-02; closes agent visual-blindness gap. **Ralph-ready 2026-06-09**: Agent Brief + `launch-issue44.sh` (tasks 44.1–44.5). **fast-follow** (strengthens #48 gauntlet) |
| 45 | [iOS MCQ voice + design-port redesign](issue-45-ios-mcq-voice-and-redesign.md) | enhancement · ready-for-agent (partial) | `[ ]` #45 | From handoff 2026-06-03. Supersedes #42 Track E (42.14–42.18). 6 Ralph tasks (45.1–45.6, logic+components, unit/inspector-tested) + 7 `[HUMAN]` (integration/visual/sim). ⛔ Ralph BLOCKED on mba: Xcode 16.4 lacks iOS 26 SDK (SpeechAnalyzer won't compile) — upgrade mba to Xcode 26.x or run loop on laptop. Related: #14 (redesign umbrella) |
| 46 | [Canonical-answer enforcement + branch for open/logical questions](issue-46-answer-shape-and-logical-branch.md) | enhancement · done | `[x]` #46 | Ralph loop completed 2026-06-07 on mba; all A1–B9 landed including iOS B8/B9 under Xcode 26.3. Serializer fix (`generated_by` + `headline_answer`) shipped 2026-06-08 (`16161de`) |
| 47 | [Upgrade GitHub Actions to Node.js 24-compatible versions](issue-47-github-actions-node24-upgrade.md) | enhancement · done | `[x]` #47 | Done 2026-06-08: `webfactory/ssh-agent@v0.9.0`→`@v0.10.0` + `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24` in all 4 workflows |
| 49 | [Daily free-limit cost research](issue-49-daily-limit-cost-research.md) | enhancement · ready-for-agent | `[ ]` #49 | From launch decision #4. Research-only: per-question LLM + Fly hosting cost model, is 20/day sustainable, paid-tier price band. **Ralph-ready 2026-06-09**: Agent Brief + `launch-issue49.sh` (tasks 49.1–49.8). **fast-follow** (paywall prep, not a launch blocker) |
| 50 | [App Store Connect listing + ASC API setup](issue-50-app-store-connect-setup.md) | enhancement · ready-for-human | `[ ]` #50 | From launch decisions #5/#7. **Founder decision 2026-06-09: not started — founder will do the `[HUMAN]` steps**; exact step-by-step issued → `docs/artifacts/asc-setup-instructions-2026-06-09.html`. `[AGENT]` (wire fastlane, draft SK/CZ/EN metadata) unblocks once the ASC API key lands in `.env`. Pack purchasing only |
| 51 | [Product analytics for PRD success metrics](issue-51-product-analytics.md) | enhancement · ready-for-agent | `[ ]` #51 | From launch decision #11. **Founder decision 2026-06-09: free tool — reuse Sentry** (already integrated, EU-aligned, no second SDK per the issue's own guard; Firebase Analytics as fallback if funnels too thin). Next: event taxonomy → instrument completion/voice-reliability/wrong-answer funnel |

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
