# Quiz Agent — Monorepo

Voice-first AI quiz platform for hands-free trivia while driving.

Layout: `apps/quiz-agent` (FastAPI backend) · `apps/quiz-pack-api` (order/generation, issue #33) · `apps/web-ui` · `apps/ios-app` (SwiftUI) · `packages/shared` (Pydantic models).

## Tasks & Indices

- `docs/todo/TODO.md` — `[ ]` todo · `[~]` wip · `[x]` done. Check `[~]` items at session start. `/todo` to manage. Session handoff: `/handoff` (durable committed file — work crosses a session/day/machine, e.g. Ralph on `mba`) · `/summarize` (ephemeral copy-paste block — finishing today in a new window) · `/catchup` (resume from git diff after a break).
- Plan files for sizable tasks: `docs/issues/issue-NN-{slug}.md`, linked from TODO line.
- `CONTEXT.md` — domain glossary, read before PRDs / issues / arch suggestions.
- `docs/product/INDEX.md` — PRDs with Draft / Approved / Shipped / Deferred status.
- `docs/issues/INDEX.md` — issues with `**Triage:**` state in header.

## Quick Reference

| Task | Command |
|------|---------|
| Install deps | `uv pip install -e apps/quiz-agent && uv pip install -e packages/shared` |
| Backend tests | `cd apps/quiz-agent && pytest tests/ -v` |
| Start backend (:8002) | `cd apps/quiz-agent && uvicorn app.main:app --reload --port 8002` |
| Quiz-pack-api tests | `cd apps/quiz-pack-api && pytest tests/ -v` |
| Start quiz-pack-api (:8003) | `cd apps/quiz-pack-api && uvicorn app.main:app --reload --port 8003` |

Stack-specific commands (iOS build / test / schemes, Fly.io deploy) live in the rules files below.

## Output

Long outputs (>30 lines: summaries, analyses, reports, reviews, recaps) → self-contained HTML at `docs/artifacts/<slug>.html` (inline CSS, no external deps/CDN, no network). Reply `open <path>`. Not for: commits, TODO, issue plan files, short replies. **MD = persistent. HTML = throwaway.**

**Visual-first, not a wall of text.** Default to actual visual structure over prose: status boards / card grids, color-coded status + priority badges, area tags, count dashboards, dependency-chain / flow diagrams (ASCII or inline SVG), collapsible `<details>` for depth, sticky TOC for long docs. Dark theme, scannable at a glance. Reference exemplar: `docs/artifacts/issues-visual-recap-2026-06-18.html`. This is our local equivalent of agent-native `/visual-recap` — no external service, opens in any browser.

## File Placement

New files go in their typed home — never at repo root, never as plan/research docs inside an app.

- **Repo-root docs:** only `README.md`, `CLAUDE.md`, `CONTEXT.md`. (Out-of-scope root entries that stay: `pyproject.toml`, `uv.lock`, `.env*`, `chroma_data/`, `infra/`, `design/` — the live Pencil source `design/quiz-agent.pen`.)
- **Apps:** each `apps/*` keeps exactly one `README.md`; no plan/research/setup docs inside app source.
- **Everything else under `docs/` by type:** issues → `docs/issues/` · research → `docs/research/` · HTML reports → `docs/artifacts/` · handoffs → `docs/handoffs/` (archive old ones in `docs/handoffs/archive/`) · test runs → `docs/testing/runs/` · setup guides → `docs/setup/` · design → `docs/design/`.
- **Outdated docs** → `docs/archive/<area>/`, never deleted ad hoc (git history is the safety net).

## Behavioral Rules

These rules apply to every task in this repo unless explicitly overridden.
Bias: caution over speed on non-trivial work. Use judgment on trivial tasks.
Keep per-task output tight; manage context per Rule #12.

### 1. Minimal Footprint
State assumptions explicitly; if uncertain, ask rather than guess, and present multiple interpretations when ambiguity exists. Push back when a simpler approach exists; stop when confused and name what's unclear.
Write the minimum code that solves the problem — nothing speculative, no features beyond what was asked, no abstractions for single-use code, no error handling for impossible scenarios. Would a senior engineer call this overcomplicated? If yes, simplify.
Touch only what you must. Don't "improve" adjacent code, comments, or formatting; don't refactor what isn't broken. Match existing style and conventions even if you disagree — conformance > taste; if a convention seems harmful, raise it separately rather than forking silently. Every changed line should trace directly to the user's request.

### 2. Goal-Driven + Fail Loud
Define success criteria and loop until verified. Transform tasks into verifiable goals (e.g. "fix bug" → "write a failing test, then make it pass"); strong success criteria let you loop independently.
Fail loud. "Migration completed" is wrong if records were silently skipped; "tests pass" is wrong if any were skipped or UI wasn't verified. Default to surfacing uncertainty, not hiding it.

### 3. Communication
Answer the exact question first, then expand only if it helps. Lead with the answer in whatever form fits the question, and address the user's stated constraint directly (e.g. "what is X" wants a definition; "how do I do Y given Z" wants Z handled). Don't surface adjacent scenarios, future states, or implementation details unless necessary.
Explain at the conceptual level — what technology or approach, and why, not how it's coded. Never include code snippets, SQL, or implementation abbreviations unless explicitly asked.

### 4. Surface conflicts, don't average them
If two existing patterns contradict, don't blend them.
Pick one (more recent / more tested), explain why, flag the other for cleanup.

### 5. Read before you write
Before adding code, read the file's exports, immediate callers, and shared utilities (esp. `packages/shared`).
"Looks orthogonal to me" is the most dangerous phrase in this codebase.

### 6. Tests verify intent, not just behavior
Every test must encode WHY the behavior matters, not just WHAT it does.
A test that can't fail when business logic changes is wrong.
Snapshot tests: assert the *meaningful* part of the snapshot.

### 7. Checkpoint for recoverability
On multi-step work, keep state durable enough that a fresh context could resume — update `docs/issues/issue-NN-*.md` and `docs/todo/TODO.md` at meaningful milestones, not after every step. If you lose track, stop and restate.

### 8. Commit and Build Autonomously
Commit at every natural checkpoint without asking for permission — incomplete downstream subtasks do not block a valid commit.
Trigger TestFlight or deploy steps as soon as a testable increment exists; don't wait for the full feature to be complete.
Push to remote autonomously once commits are ready — no approval needed. Ask before destructive git operations only (force-push, reset --hard, amend, history rewrites). When in doubt, act rather than defer.

### 9. Pivot When Approach Is Rejected
When a user reports that an approach failed or explicitly rejects it, do not re-offer the same approach in different syntax.
Pivot immediately: execute the step directly via available tooling, or ask once whether the user wants you to take over.
Interpret "I can't do this" or "it doesn't work" as a handoff request — act rather than explaining the technical cause.

### 10. Verify Before Stating Constraints
Treat claims about available software versions, UI option locations, and tool accessibility as hypotheses, not conclusions.
Before stating a constraint as final (e.g., "X is the maximum version", "this option is at Settings > Y"), either verify it or flag it as unverified.
When diagnosing a failure, confirm that a suggested workaround is not itself blocked by the same root cause.

### 11. Proactively Surface Cost & Infra Optimizations
When you notice an optimization the user hasn't asked for — consolidating fragmented services/keys/billing, cheaper or simpler tooling, a unified gateway, reducing per-task token spend, removing duplicated infra — flag it briefly and unprompted.
Keep it brief enough not to derail the current task — roughly "worth considering: X, because Y, tradeoff Z". Only raise it once per distinct opportunity, and respect prior decisions (don't re-pitch something already declined).
Examples worth flagging: multiple provider keys/bills for one logical capability, paying for a managed service that local/project-scoped config already covers, an obviously cheaper model for a low-stakes call.

### 12. Context Discipline
Delegate bulk reading/searching to subagents so raw file contents don't accumulate in the main context. Scope work so it stays navigable; use judgment on size rather than a fixed token cap — don't pre-emptively fragment work that fits one context.
If a task genuinely won't fit, split it at a clean boundary, commit what's valid, and write a handoff via `/handoff` so a fresh session can resume without re-explaining context. Surface that you did this — never silently push past a limit.

### 13. Ask the User Sparingly, In-Session, With Full Context
Before asking the user for anything — a decision, an answer, or an action for them to perform — first confirm you genuinely can't resolve it better yourself from the code, conventions, or a sensible default. Most questions never need to reach them: decide what you can, state the assumption, and proceed.
**Always decide product matters *with* the user** (UX, scope, feature behavior, monetization, vision) — these need their input even when a reasonable default exists.
When you do need them, **ask interactively during the session** (e.g. an in-session question prompt) with enough context to answer without digging. Never bury a question for the user inside a plan/issue/handoff doc where it gets lost — surface it live.
When the user must perform an action outside the code (set a secret or API key, change a console/dashboard setting, run an auth or login flow), give **exact, numbered, step-by-step instructions** and assume zero prior knowledge — they rarely know how on their own.

## Rules files

- `.claude/rules/shared.md` — Git workflow, API contract, testing (always loaded)
- `.claude/rules/ios.md` — iOS patterns, schemes, build commands (lazy: `apps/ios-app/**`)
- `.claude/rules/backend.md` — Python/FastAPI, deploy pointers (lazy: backend paths)
