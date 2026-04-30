# TODO

Local task tracker. Manage with `/todo`. Generate a handoff for a fresh session with `/summarize`.

States: `[ ]` todo · `[~]` wip · `[x]` done. Numbers continue the `docs/issues/issue-NN-*.md` series — when an item needs a detailed plan, create `docs/issues/issue-NN-{slug}.md` and link it from the line.

- [x] #19 Auto-confirm resubmit bug fires twice — [plan](../issues/issue-19-auto-confirm-resubmit-bug.md)
- [ ] #20 Timer bug from crash-elimination Wave 3 (open since 2026-04-15)
- [ ] #21 Generate question Groups B-E (full pipeline already operational for Group A)
- [x] #22 ChromaDBClient — split into `QuestionStore` seam — [plan](../issues/issue-22-chroma-client-split.md)
- [ ] #23 QuestionRetriever — extend seam to cover all reads — [plan](../issues/issue-23-question-retriever-seam.md)
- [x] #24 Consolidate `question_to_dict_translated` into `serializers.py` — [plan](../issues/issue-24-translated-serializer-locality.md)
- [ ] #25 Backend `QuizSession.phase` — transition guard module — [plan](../issues/issue-25-session-phase-transition-guard.md)
- [ ] #26 `TaskBag` — concentrate `QuizViewModel` task lifecycle — [plan](../issues/issue-26-task-bag-lifecycle.md)
- [ ] #27 `PendingStore` — question pipeline pending state — [plan](../issues/issue-27-pending-store-question-pipeline.md)
