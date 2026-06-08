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
- [ ] #30 Batch-generate questions for new categories — [plan](../issues/issue-30-batch-generate-categories.md) (gate on #28 + #29) — `general` 52/50 + `superheroes` 34/30 + `sports-mix` 30/30 approved LOCALLY 2026-05-19; prod ChromaDB sync pending for all three; `disney` 20/30 / `football` 22/30 still open
- [x] #31 iOS test hardening — lock in current behavior — [strategy](../issues/issue-31-ios-test-hardening.md) · [handoff](../issues/issue-31-handoff.md) — Phases 1–4 done 2026-05-11; Phase 5 snapshots done 2026-05-15; XCUITest infra unblocked 2026-05-18 (pbxproj config backfill); **2026-05-19 — all 4 RS scenarios GREEN (38s, 0 failures)** after fixing 3 a11y wiring bugs (StaticText vs Other query mismatch on `question.text` / `question.statusPill`; `.hidden()` stripping label from `question.state` probe; container-level identifiers in `AnswerConfirmationView` overriding child button identifiers) and adding mic-tap + recording-state wait to `testRSCorrect` / `testRSIncorrect`
- [ ] #32 On-demand question generation service — umbrella strategy — [plan](../issues/issue-32-on-demand-generation-service.md) — Phase 1 decomposed into #33; post-review revisions C1/C2/C3 in #33
- [x] #33 quiz-pack-api Phase 1 — domain entities + ordered flow — [plan](../issues/issue-33-quiz-pack-api-phase-1.md) — 1.1–1.12 code-complete 2026-05-15 (1.11 SSE stream + JWS verify cache, 1.12 e2e test + CI services); awaits next CI green to confirm e2e
- [x] #34 Claude Code context/token optimization — [plan](../issues/issue-34-claude-context-optimization.md) — Tier 1+2.2+3.1/3.2/3.3 hotové; validácia po session restart
- [x] #35 Parallel backlog burn-down via subagents (#30 + #31 + #33) — [plan](../issues/issue-35-parallel-backlog-burndown.md) — Track A (#33) + Track B (#31 Phase 5 partial) + Track C (#30 general) done 2026-05-15
- [x] Fix last backend-ci failure (test_create_order_happy_path_202: await expire_all) → deploy quiz-pack-api; OOM-resilience fix deployed 2026-05-18 (517ce12)
- [x] #36 quiz-pack-api Phase 2 — `PackGenerator` orchestrator + voice-quiz pgvector cutover — [plan](../issues/issue-36-quiz-pack-api-phase-2.md) — shipped 2026-05-28 (22 atomic Ralph-ordered tasks; orchestrator 6 stages, duplicate generators deleted, M-2 retry endpoint, voice-quiz cut over to pgvector — ChromaDB read-only until Phase 6/#41)
- [~] #42 Question quality sweep + multichoice activation — [plan](../issues/issue-42-question-quality-and-mcq.md) (Ralph done tracks A–D: tasks 42.1–42.13 backend, run 2026-05-29 `cf074df..1eee3a6`, pushed + CI green at `945bcac` after a ruff-format fix; Track E 42.14–42.18 iOS `[HUMAN]` remaining; pgvector count R15 still unverified)
- [x] Ralph autonomous loop on agent Mac (`ssh mba`) for #36 — all 22 tasks done (2.1–2.15 in 2026-05-20 run `a92098a..6aa70b6`; 2.16–2.22 in 2026-05-28 run `2ce3aba..e97e972`); #36 Phase 2 fully shipped — see [handoff](../handoffs/handoff-2026-05-28-1640.md)
- [ ] #43 Maestro MCP — natural-language UI flows on the iOS sim — [plan](../issues/issue-43-maestro-mcp-ui-flows.md) (from research 2026-06-02; needs human go/no-go on Cloud API key + scope before setup)
- [ ] #44 Mandatory screenshot-verify step — close the agent's visual-blindness gap — [plan](../issues/issue-44-screenshot-verify-step.md) (from research 2026-06-02; no new deps, ready-for-agent)
- [~] #45 iOS MCQ voice + design-port redesign — [plan](../issues/issue-45-ios-mcq-voice-and-redesign.md) (Ralph loop on mba completed 2026-06-07; 45.1–45.6 done; 7 `[HUMAN]` tasks remain (45.7–45.13): do on laptop with simulator + design/quiz-agent.pen; see [handoff](../handoffs/handoff-2026-06-07-1856.md))
- [x] #46 Canonical-answer enforcement + branch for open/logical questions (code-complete 2026-06-07; all 46.A1–B9 landed including iOS B8/B9 under Xcode 26.3 on mba) — [plan](../issues/issue-46-answer-shape-and-logical-branch.md)
- [x] #47 Upgrade GitHub Actions to Node.js 24 — [plan](../issues/issue-47-github-actions-node24-upgrade.md) (done 2026-06-08: `webfactory/ssh-agent@v0.9.0`→`@v0.10.0` + `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24` in all 4 workflows)
- [ ] #48 Pre-release review gauntlet (App Store) — architecture → security → `/code-review ultra` — [plan](../issues/issue-48-pre-release-review-gauntlet.md) (gate before App Store submission; reviews are **interactive**, only the remediation phase → `#49` is Ralph-able)
- [ ] Logical-puzzle reference URLs — populate a source/reference link for `pipeline=logical_puzzle` questions (deferred from #46 D5; F8 currently lets puzzles persist with `source_url=null`)
- [~] Implement Claude Code setup-review recommendations — see docs/handoffs/handoff-2026-06-08-1659.md
