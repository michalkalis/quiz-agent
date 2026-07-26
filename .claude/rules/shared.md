# Shared Development Standards

## Git Workflow

Solo project — push directly to main. No feature branches or PRs needed.
Agent may push to `origin/main` at its own discretion in-session — no per-push approval needed. Destructive ops (force-push, reset --hard, amend, history rewrites) still require a heads-up.

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

**Opus 5 is the default frontier model.** Fable 5 costs roughly 2× Opus 5, so it is never the automatic choice for "this feels important".

Reach for **Fable 5** only when one of these holds:
- The problem is genuinely hard and Opus has already failed or stalled on it.
- A long unattended autonomous run (Ralph on `mba`) where nobody is watching to course-correct.
- Architecture / design decisions or adversarial flaw-hunting where a wrong call is expensive to undo.
- Orchestrating many parallel subagents at once.
- First shot at a large, well-specified implementation.

Stay on **Opus 5** for everything else: normal edits, fixes, tests, review, deploy, interactive work, and anything where Opus at medium/high effort already lands the right answer. Paying double for the same output is a defect, not caution.

**Prompting differs by model — this matters more than the price.**
- *Fable 5* wants **goal + constraints + why**, not a procedure. Step-by-step instructions degrade it. The prescriptive pipeline skills (`prepare-issue`, `split-issue`) are written for Opus; do not point them at Fable without loosening them first.
- *Opus 5* wants **brakes**, not encouragement. It self-verifies and self-critiques already, so "double-check your work at the end" only adds cost. Keep instructions short and give it explicit limits.

### Working with Opus 5 subagents

- **Don't add self-verification boilerplate.** Opus 5 already re-checks its own work. Ask for verification only where a *different* pair of eyes is the point (security review, gate reviewers, adversarial checks).
- **Cap the fan-out.** Default to ≤ 3 subagents per step and ≤ 8 per task; delegating is not free. If a step seems to need more, the step is scoped wrong — split it instead.
- **Delegate for context, not for prestige.** Spawn a subagent when the work would dump bulk file contents into the main context (Rule #12), or when it genuinely runs in parallel. Never spawn one for work that is faster done inline.
- **Give subagents a tight output contract.** State what to return and how long (findings only, `file:line` + one-line fix, no audit trails) — otherwise Opus returns long reports and the token saving evaporates.
- **Match model to job explicitly.** Every `Agent` call passes `model`; unstated means it inherits the driver, which is usually more expensive than the job deserves.

## Config & Infrastructure

Prefer local and project-scoped config. Before recommending a cloud service or global config change, check whether existing local hardware or project-scoped config already covers the need.
Use `.claude/settings.local.json` for repo-specific settings, not `~/.claude/settings.json`.
Ground every infrastructure plan in the actual current state of existing machines and config.
