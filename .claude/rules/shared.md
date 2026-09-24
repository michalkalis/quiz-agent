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
| `Ralph` | Retired overnight agent loop (stopped 2026-09-16); appears in older docs only |
| `mba` | The agent Mac (reachable via Remote Control) that builds iOS |
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
Session driver: **Opus 5.5 at `high` effort** (founder, 2026-09-24; set in user `modelSettings`). Per-turn depth: `/effort` or `ultrathink` — changing effort keeps the prompt cache, switching models does not.

### Opus 5.5 vs Fable 5.1 — escalation ladder (founder, 2026-09-24)

Delegation is decided first (does this belong in a cheap subagent?), frontier tier second. Anthropic's own evals put Opus 5.5 at or above Fable 5.1 on every published benchmark (agentic coding, research, knowledge work) at ~⅖ the price (Fable $10/$50 vs Opus $4/$20 per MTok), so **Opus 5.5 does all frontier work by default** — implementation, planning, reviews, debugging, deploys.

Escalate in this order, never skipping a rung:
1. Opus 5.5 at `high` (default).
2. Same task at `xhigh`/`max` (`/effort`, or `ultrathink` for one turn).
3. **Fable 5.1** only when: Opus has failed twice on the same problem even at rung 2; or deep multistep research / an hours-long unattended task that ends in a finished document; or the founder asks for it.

Important plans (architecture, data model, anything costly to undo) get an **independent fresh-context review** (Opus subagent, `/design-soundness`) before implementation — a second pair of eyes buys more robustness than a pricier model.

**Prompting differs by model.**
- *Opus 5.5* wants **brakes**, not encouragement: it always thinks and self-verifies, so "think carefully" / "double-check your work" only adds cost. State what done means and explicit limits.
- *Fable 5.1* wants **goal + constraints + why**, not a procedure — step-by-step instructions degrade it. It sometimes ends a turn describing next steps instead of doing them: tell it to finish the whole task and to stop only for destructive actions or genuine blockers.

### Working with subagents

- **Verification only from a different pair of eyes** (security review, plan review, adversarial checks) — never self-check boilerplate.
- **Keep the fan-out narrow.** Roughly ≤ 3 concurrent subagents per step; go wider only deliberately (a `/regression` sweep, a broad audit).
- **Delegate for context, not for prestige.** Spawn one when the work would dump bulk file contents into the main context (Rule #12) or genuinely runs in parallel; check its evidence before accepting it.
- **Give subagents a tight output contract** — what to return and how long (findings only, `file:line` + one-line fix).
- **Match model to job explicitly.** Every `Agent` call passes `model`; unstated inherits the driver.

## Config & Infrastructure

Prefer local and project-scoped config. Before recommending a cloud service or global config change, check whether existing local hardware or project-scoped config already covers the need.
Use `.claude/settings.local.json` for repo-specific settings, not `~/.claude/settings.json`.
Ground every infrastructure plan in the actual current state of existing machines and config.
