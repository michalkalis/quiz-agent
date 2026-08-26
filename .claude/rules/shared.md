# Shared Development Standards

## Git Workflow

**PR workflow with independent review (founder, 2026-08-26).** Every change lands on `main` through a pull request — no direct pushes (soft lock: repo ruleset with admin bypass reserved for emergencies only; using the bypass requires an explicit founder heads-up).

Flow per change/feature:
1. Branch from `main`: `<type>/<slug>` (e.g. `feat/166-fact-check`, `fix/timer-crash`). Commits on the branch follow Conventional Commits as before.
2. Push the branch and open a PR (`gh pr create`) with a conventional title and a short body (what + why, issue ref).
3. Wait for the independent review: the **Claude Code Review** GitHub Action (fresh cloud context, no session bias) posts inline findings on every PR, plus path-filtered CI.
4. Address review findings: fix or explicitly rebut each one in the PR thread. Pushing fixes re-triggers the review.
5. Merge autonomously (**squash**, PR title becomes the commit subject) once the review is clean/addressed and CI is green. Product-level findings (UX, scope, monetization) go to the founder before merge; technical findings the agent resolves itself.

Granularity: one PR per coherent change — roughly what was previously one push-worthy checkpoint. Don't batch unrelated work into one PR; don't split one logical change across PRs. Docs-only/memory-only housekeeping follows the same flow (review is cheap on tiny diffs).

Destructive ops (force-push, reset --hard, amend, history rewrites) still require a heads-up. Force-push to your own un-merged PR branch after a rebase is fine.

### Commit Messages
Follow Conventional Commits: `<type>(<scope>): <subject>`

**Types:** feat, fix, docs, style, refactor, test, chore
**Scopes:** ios, backend, questions, web, shared, ci

## Referring to Issues & Tasks

A number is an identifier, never a label. Never write a bare `#45` or `42.20` in prose, commits, or docs — always pair it with its short human title so it reads on its own:

- ✅ `#45 — iOS MCQ voice + redesign`, `task 42.20 (make MCQ patterns selectable)`
- ❌ `reclassified #45`, `42.20 unblocked`

The number stays as the stable anchor (file names, cross-refs, git); the title is what makes it legible to someone without the backlog open. Expand project shorthand on first use in a given doc/message.

### Project shorthand glossary

| Term | Meaning |
|------|---------|
| `#NN` | Issue number → `docs/issues/issue-NN-{slug}.md`; the slug is its human title |
| `NN.X` | Sub-task X within issue #NN (e.g. `42.20`) — name it when referenced |
| `RS-01`..`RS-NN` | iOS regression scenario (end-to-end sim test), see `/regression` |
| `Track A/B/…` | A parallel stream of work inside one issue |
| `Ralph` | Overnight autonomous agent loop (runs on `mba`) |
| `mba` | The agent Mac (`ssh mba`) that builds iOS + runs Ralph |
| `MCQ` | Multiple-choice question (vs. open/voice answer) |

## API Contract

**OpenAPI as source of truth.** FastAPI generates the spec; iOS Codable structs must match backend Pydantic models.

When changing API models:
1. Update Pydantic model in `packages/shared/` or `apps/quiz-agent/`
2. Verify OpenAPI spec: `curl http://localhost:8002/openapi.json`
3. Update iOS Codable structs to match
4. Run `/verify-api` to confirm sync

## Testing

- **Backend:** `pytest tests/ -v` — mock OpenAI calls, use fixtures
- **iOS:** Unit test ViewModels with mocked services
- Test commands in CLAUDE.md quick reference table

## Model Routing (token economy)

Advisor/orchestrator pattern via native `Agent`/Workflow `model` only — no third-party plugins or hooks.
Bulk work (reads, searches, mechanical edits, tests) → Sonnet/Haiku subagents. Frontier only at decision points: planning, architecture, security, verify-before-done, or after 2+ failed attempts. For multi-file work let frontier plan, cheap workers execute.
Session driver model is a per-session `/model` choice (not file-set); cheapest = Sonnet driver + frontier advisor subagents.

### Opus 5 vs Fable 5

This section picks *which frontier model* — it does **not** override the delegation rule above. Delegation is decided first (does this work belong in a cheap subagent?), model tier second (if it is frontier work, Opus or Fable?). Mechanical edits and test runs still go to Sonnet/Haiku subagents regardless of what the driver is running on.

**Opus 5 is the default frontier model.** Fable 5 costs roughly 2× Opus 5, so it is never the automatic choice for "this feels important".

Reach for **Fable 5** only when one of these holds:
- The problem is genuinely hard and Opus has already failed or stalled on it.
- A long unattended autonomous run (Ralph on `mba`) where nobody is watching to course-correct.
- Architecture / design decisions or adversarial flaw-hunting where a wrong call is expensive to undo.
- Orchestrating many parallel subagents at once.
- First shot at a large, well-specified implementation.

Stay on **Opus 5** for every other frontier-level call: the interactive driver, reviews, deploys, debugging, and anything where Opus at medium/high effort already lands the right answer. Paying double for the same output is a defect, not caution.

**Prompting differs by model — this matters more than the price.**
- *Fable 5* wants **goal + constraints + why**, not a procedure. Step-by-step instructions degrade it. The prescriptive pipeline skills (`prepare-issue`, `split-issue`) are written for Opus; do not point them at Fable without loosening them first.
- *Opus 5* wants **brakes**, not encouragement. It self-verifies and self-critiques already, so "double-check your work at the end" only adds cost. Keep instructions short and give it explicit limits.

### Working with Opus 5 subagents

- **Don't add self-verification boilerplate.** Opus 5 already re-checks its own work. Ask for verification only where a *different* pair of eyes is the point (security review, gate reviewers, adversarial checks).
- **Keep the fan-out narrow.** Roughly ≤ 3 subagents per step is the normal shape — not a hard ceiling (Rule #12 governs *work size* by judgment; this is about *concurrent helpers*, a different axis). Going wider is fine when the work genuinely parallelises — a `/regression` sweep, a broad audit — but it should be a deliberate call, not the reflex. Delegating is not free.
- **Delegate for context, not for prestige.** Spawn a subagent when the work would dump bulk file contents into the main context (Rule #12), or when it genuinely runs in parallel. Never spawn one for work that is faster done inline.
- **Give subagents a tight output contract.** State what to return and how long (findings only, `file:line` + one-line fix, no audit trails) — otherwise Opus returns long reports and the token saving evaporates.
- **Match model to job explicitly.** Every `Agent` call passes `model`; unstated means it inherits the driver, which is usually more expensive than the job deserves.

## Config & Infrastructure

Prefer local and project-scoped config. Before recommending a cloud service or global config change, check whether existing local hardware or project-scoped config already covers the need.
Use `.claude/settings.local.json` for repo-specific settings, not `~/.claude/settings.json`.
Ground every infrastructure plan in the actual current state of existing machines and config.
