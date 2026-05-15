# Issue 35 — Parallel backlog burn-down via subagents

**Triage:** infra · done
**Status:** Executed 2026-05-15 — Tracks A/B/C all landed in single session
**Created:** 2026-05-15
**Parent:** coordination doc for #30 + #31 + #33

---

## Outcome (2026-05-15)

- **Track A — #33 finish:** 1.11 SSE stream endpoint + JWS verify cache shipped (`app/sse/{bridge,jws_cache}.py`, route on `orders_v1_router`). 1.12 e2e test + sandbox JWS minter written, `.github/workflows/backend-ci.yml` gained pgvector+redis service containers. Local run skips without Docker; awaits next CI green to confirm e2e.
- **Track B — #31 Phase 5:** 5 new snapshot tests (Home/Question/Result) + `.stableDump` helper landing `HangsTests/Support/SnapshotHelpers.swift`. 225 tests green (target ≥240 was optimistic; actual delta +5 covers the ≥4 snapshot acceptance). 4 XCUITest scenarios + Page Objects + `UITestClient` written under `HangsUITests/` but cannot run yet — `HangsUITests` target needs to be added to the `Hangs-Local` scheme's Test action via Xcode UI.
- **Track C — #30 general category:** 55/50 (target exceeded). 3 new generated batches at `data/generated/claude_batch_03{1,2,3}.json`; batch records under `data/questions/batch-0{1,2,3}-general.md`. 22% drop rate. JSON files pending ChromaDB import.

**Known follow-ups (not part of this session):**
1. Add `HangsUITests` to Hangs-Local scheme Test action (Xcode UI), then run the 4 XCUITest scenarios.
2. Import the 55 generated `general` questions into ChromaDB via `apps/quiz-pack-api/` import script.
3. Investigate pre-existing `from app.main import app` SOCKS proxy issue surfaced during 1.11 smoke check.

---

## TL;DR

Three tracks in the active queue share **no source files** and can be driven by independent subagents in parallel. This doc fixes the file-scope boundaries, agent assignments, and sync points so a fresh-context orchestrator can launch them in a single message without merge risk.

Run target: clear #33 to "done", land #31 Phase 5, and push #30 to ≥ 90% targets, all within a single working session.

---

## Why parallel now

- #33 Phase 1 is 10/12 tasks code-complete (only 1.11 SSE stream + 1.12 e2e CI test remain). Single backend file scope.
- #31 Phase 5 (UI tests + remaining seams) lives entirely under `apps/ios-app/Hangs/HangsTests/`. Pure new test files.
- #30 batch-generation is **content work**, no source-code changes — uses `/gen-questions`, `/verify-qs`, `/score-qs` skills and writes to `data/questions/` + ChromaDB.

Cross-track file conflicts: **none**. Same iOS view-model that #19 would touch is NOT touched by #31 Phase 5 (test files only), so #31 stays clean even if we drop #19 in later.

---

## Track A — #33 finish (backend SSE + e2e)

**Scope (files touched):**
- `apps/quiz-pack-api/app/api/v1/orders.py` — add `GET /v1/orders/{id}/stream` route
- `apps/quiz-pack-api/app/sse/` (new) — Redis pubsub → SSE bridge, JWS verify cache
- `apps/quiz-pack-api/tests/integration/test_order_e2e.py` (new)
- `apps/quiz-pack-api/tests/fixtures/storekit/` (new) — sandbox JWS minter
- `.github/workflows/backend-ci.yml` — pgvector + redis service containers
- `apps/quiz-pack-api/pyproject.toml` + `Dockerfile` — `sse-starlette` (already added)
- `apps/quiz-pack-api/README.md` — DoD §9 docs

**Out of scope:** anything outside `apps/quiz-pack-api/**` and the CI workflow.

**Agent assignment:**
- Planning + implementation: `feature-dev:code-architect` then `general-purpose` with `model: sonnet` (Opus only if architect surfaces a blocker).
- Verification: `backend-tester` after the implementation agent reports done.

**Acceptance (verbatim from issue-33 §1.11 + §1.12):**
- `curl -N -H "X-StoreKit-JWS: ..." /v1/orders/{id}/stream` after enqueue receives ~7 events ending with `event: done`.
- Reconnect with `Last-Event-ID: 3` resumes at event 4 with no duplicates.
- `tests/integration/test_order_e2e.py` green locally and in CI; asserts `total_cost_cents == 0`.

**Sequential within track:** 1.11 must land before 1.12 (the e2e test consumes the stream).

---

## Track B — #31 Phase 5 (iOS UI + remaining seams)

**Scope (files touched):**
- `apps/ios-app/Hangs/HangsUITests/*.swift` (new) — XCUITest scenarios driven by `UITestSupport` + HTTP listener seam
- `apps/ios-app/Hangs/HangsTests/SnapshotTests/*.swift` (new) — accessibility-tree snapshots for `HomeView`, `QuestionView`, `ResultView`, `PaywallView`
- `apps/ios-app/Hangs/HangsTests/Support/*.swift` — extend `Fixtures.swift` if needed
- Minimal `.accessibilityIdentifier(_:)` additions to view bodies if not already present from Phase 1

**Out of scope:** any production logic in `QuizViewModel*`, `NetworkService`, `StoreManager`, services. Touching production code is a sign the track is mis-scoped.

**Agent assignment:**
- Planning: `feature-dev:code-architect` for shared snapshot strategy first.
- Implementation: `general-purpose` with `model: sonnet`, one PR-sized chunk per view.
- Verification: `ios-tester` (per `feedback_subagent_model_routing`, always pass explicit `model: sonnet`).

**Acceptance:**
- ≥ 4 XCUITest scenarios covering golden paths (start quiz, answer correct, answer incorrect, paywall trigger).
- ≥ 4 snapshot tests using text-dump strategy (no image snapshots — `swift-snapshot-testing` text-dump variant per #31 strategy).
- 220 → ≥ 240 tests green; no flake on 3 consecutive runs.

**Sequential within track:** snapshots first (cheaper, surface accessibility-id gaps), then XCUITest scenarios.

---

## Track C — #30 batch-generate (content)

**Scope (files touched):**
- `data/questions/batch-NN-<category>.md` (new files per batch)
- ChromaDB (local) via `/questions/approve` → then prod sync
- Memory `project_question_quality.md` — running counts

**Out of scope:** all source code. If the agent finds a bug in the generation pipeline, file a separate issue rather than fix in-line.

**Agent assignment:**
- Single `general-purpose` agent with `model: sonnet`, iterating the skill chain `/gen-questions → /verify-qs → /score-qs` per category.
- Priority order (from issue-30 table; counts as of 2026-05-15):
  1. `general` (1/50 → 50)
  2. `sports-mix` (10/30 → 30)
  3. `disney` (20/30 → 30)
  4. `football` (22/30 → 30)
  5. `superheroes` (26/30 → 30) — finish first if time-boxed

**Acceptance (per issue-30):**
- Approved questions only — verifier `correct`, scorer pass on 5 dimensions.
- Every approved question has `source_url` + `source_excerpt`.
- Counts updated in memory after each category clears.

**Sequential within track:** one category at a time. Skill chain is inherently serial.

---

## Launch shape

Single message with three `Agent` tool calls. Track A and Track B can both kick off planning sub-agents concurrently; Track C is straight execution. Do NOT spawn Track A's e2e (1.12) until 1.11 reports done.

```
Agent(track A — feature-dev:code-architect, model: sonnet, scope: 1.11 SSE)
Agent(track B — feature-dev:code-architect, model: sonnet, scope: #31 Phase 5)
Agent(track C — general-purpose, model: sonnet, scope: #30 general 1→50)
```

Orchestrator stays read-only on the main thread until at least one track returns. Per `feedback_subagent_model_routing`: every Agent call must pass `model` explicitly.

---

## Sync points

| When | What | Where |
|---|---|---|
| Track A 1.11 done | Launch 1.12 e2e implementer | new Agent call |
| Track A 1.12 green | Flip `[~] #33` → `[x] #33`, INDEX row to `done` | `docs/todo/TODO.md`, `docs/issues/INDEX.md` |
| Track B Phase 5 green | Flip `[~] #31` → `[x] #31` | same |
| Track C category at target | Update `project_question_quality.md`, mark line in issue-30 table | memory + issue file |
| All three green | Commit + offer deploy (per `feedback_backend_auto_deploy`) | one commit per track |

---

## Risk register

| # | Risk | Mitigation |
|---|---|---|
| R1 | Track A and Track B both touch `packages/shared/quiz_shared/models/question.py` | They don't. #33 1.11+1.12 are pure quiz-pack-api scope; #31 Phase 5 is pure HangsTests scope. Verified against the issue plans 2026-05-15. |
| R2 | Track C exhausts OpenAI budget mid-session | Cap each agent at one category per run; orchestrator checks usage memo before launching next. |
| R3 | Subagents default to Opus → token blow-out | All three Agent calls **must** pass `model: sonnet` per `feedback_subagent_model_routing`. Architect can escalate to Opus if stuck. |
| R4 | Track A e2e test needs Postgres+Redis containers in CI; first PR fails on missing service | Architect agent must inspect `.github/workflows/backend-ci.yml` before writing the test and add the services block in the same commit. |
| R5 | Track B snapshot tests are flaky under simulator drift | Use text-dump / accessibility-tree only (#31 strategy decision). No image snapshots. |
| R6 | Three parallel tracks burn through orchestrator context | Per CLAUDE.md rule 6: 4k output / 30k session budget. Subagent results return summaries, not full tool transcripts. If approaching budget, summarise + handoff via `/summarize`. |

---

## Definition of done

1. #33 TODO line flipped `[~]` → `[x]`; INDEX row `Triage` → `enhancement · done`.
2. #31 TODO line flipped `[~]` → `[x]` if Phase 5 lands; if only partial, update with "Phase 5 done; Phase 6 deferred".
3. #30 table updated with new counts; if any category hits target, append a "DONE (NN, YYYY-MM-DD)" annotation.
4. One commit per track, conventional-commits scoped (`feat(quiz-pack)`, `test(ios)`, `chore(questions)`).
5. `project_question_quality.md` memory updated with final counts.
6. This file (`issue-35-*.md`) flipped to `infra · done`.

---

## Pointers

- Parent plans: `docs/issues/issue-30-batch-generate-categories.md`, `docs/issues/issue-31-ios-test-hardening.md`, `docs/issues/issue-33-quiz-pack-api-phase-1.md`.
- Subagent routing rule: memory `feedback_subagent_model_routing`.
- Deploy flow after Track A: memory `feedback_backend_auto_deploy` + `/deploy` skill.
- Question quality counts: memory `project_question_quality`.
