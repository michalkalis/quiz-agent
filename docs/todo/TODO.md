# TODO

Local task tracker. Manage with `/todo`. Generate a handoff for a fresh session with `/summarize`.

States: `[ ]` todo · `[~]` wip · `[x]` done. Numbers continue the `docs/issues/issue-NN-*.md` series — when an item needs a detailed plan, create `docs/issues/issue-NN-{slug}.md` and link it from the line.

- [x] #19 Auto-confirm resubmit bug fires twice — [plan](../issues/issue-19-auto-confirm-resubmit-bug.md)
- [x] #20 Timer bug from crash-elimination Wave 3 — fixed 2026-04-15 in `1a19438` (thinkingTimeTask cancellation), follow-ups `991eaba` + `4d34e3b`; RS-01..08 PASS 2026-04-29/30
- [x] #21 Generate question Groups B-E — superseded 2026-05-02; split into #28 / #29 / #30; Groups C/D2/D3 deferred (data-blocked)
- [x] #22 ChromaDBClient — split into `QuestionStore` seam — [plan](../issues/issue-22-chroma-client-split.md)
- [x] #23 QuestionRetriever — extend seam to cover all reads — [plan](../issues/issue-23-question-retriever-seam.md)
- [x] #24 Consolidate `question_to_dict_translated` into `serializers.py` — [plan](../issues/issue-24-translated-serializer-locality.md)
- [x] #25 Backend `QuizSession.phase` — transition guard module — [plan](../issues/issue-25-session-phase-transition-guard.md)
- [x] #26 `TaskBag` — concentrate `QuizViewModel` task lifecycle — [plan](../issues/issue-26-task-bag-lifecycle.md)
- [x] #27 `PendingStore` — question pipeline pending state — [plan](../issues/issue-27-pending-store-question-pipeline.md)
- [x] #28 iOS category picker — expand catalog + add `age_appropriate` — [plan](../issues/issue-28-ios-category-picker-expansion.md)
- [x] #29 Backfill `source_url` / `source_excerpt` on existing questions — [plan](../issues/issue-29-backfill-existing-questions.md) — done 2026-05-04 (67/67 approved locally + prod synced; 8 flagged questions corrected per human review)
- [ ] #30 Batch-generate questions for new categories — [plan](../issues/issue-30-batch-generate-categories.md) (gate on #28 + #29) — `general` 55/50 DONE 2026-05-15 via #35 Track C; JSON pending ChromaDB import; `sports-mix` / `disney` / `football` / `superheroes` still open
- [x] #31 iOS test hardening — lock in current behavior — [strategy](../issues/issue-31-ios-test-hardening.md) · [handoff](../issues/issue-31-handoff.md) — Phases 1–4 done 2026-05-11; Phase 5 snapshots done 2026-05-15 (5 new snapshot tests + `.stableDump` helper, 225 tests green); XCUITest scaffolding (4 scenarios + Page Objects) written but needs `HangsUITests` target added to Hangs-Local scheme Test action before it can run
- [ ] #32 On-demand question generation service — umbrella strategy — [plan](../issues/issue-32-on-demand-generation-service.md) — Phase 1 decomposed into #33; post-review revisions C1/C2/C3 in #33
- [x] #33 quiz-pack-api Phase 1 — domain entities + ordered flow — [plan](../issues/issue-33-quiz-pack-api-phase-1.md) — 1.1–1.12 code-complete 2026-05-15 (1.11 SSE stream + JWS verify cache, 1.12 e2e test + CI services); awaits next CI green to confirm e2e
- [x] #34 Claude Code context/token optimization — [plan](../issues/issue-34-claude-context-optimization.md) — Tier 1+2.2+3.1/3.2/3.3 hotové; validácia po session restart
- [x] #35 Parallel backlog burn-down via subagents (#30 + #31 + #33) — [plan](../issues/issue-35-parallel-backlog-burndown.md) — Track A (#33) + Track B (#31 Phase 5 partial) + Track C (#30 general) done 2026-05-15
- [x] Fix last backend-ci failure (test_create_order_happy_path_202: await expire_all) → deploy quiz-pack-api; OOM-resilience fix deployed 2026-05-18 (517ce12)
