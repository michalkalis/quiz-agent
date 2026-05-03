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
- [ ] #29 Backfill `source_url` / `source_excerpt` on existing questions — [plan](../issues/issue-29-backfill-existing-questions.md)
- [ ] #30 Batch-generate questions for new categories — [plan](../issues/issue-30-batch-generate-categories.md) (gate on #28 + #29)
