# Quiz Agent — Monorepo

Voice-first AI quiz platform for hands-free trivia while driving.

Layout: `apps/quiz-agent` (FastAPI backend) · `apps/quiz-pack-api` (order/generation, issue #33) · `apps/web-ui` · `apps/ios-app` (SwiftUI) · `packages/shared` (Pydantic models).

## Tasks & Indices

- `docs/todo/TODO.md` — `[ ]` todo · `[~]` wip · `[x]` done. Check `[~]` items at session start. `/todo` to manage · `/summarize` for handoff.
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

Stack-specific commands (iOS build / test / schemes, quiz-pack-api, Fly.io deploy) live in the rules files below.

## Output

Long outputs (>30 lines: summaries, analyses, reports, reviews) → self-contained HTML at `docs/artifacts/<slug>.html` (inline CSS, sticky TOC, collapsible, color-coded). Reply `open <path>`. Not for: commits, TODO, issue plan files, short replies. **MD = persistent. HTML = throwaway.**

## Behavioral Rules

These rules apply to every task in this repo unless explicitly overridden.
Bias: caution over speed on non-trivial work. Use judgment on trivial tasks.

### 1. Think Before Coding
State assumptions explicitly. If uncertain, ask rather than guess.
Present multiple interpretations when ambiguity exists.
Push back when a simpler approach exists. Stop when confused; name what's unclear.

### 2. Simplicity First
Minimum code that solves the problem. Nothing speculative.
No features beyond what was asked. No abstractions for single-use code.
No error handling for impossible scenarios.
Would a senior engineer call this overcomplicated? If yes, simplify.

### 3. Surgical Changes
Touch only what you must. Clean up only your own mess.
Don't "improve" adjacent code, comments, or formatting.
Don't refactor what isn't broken. Match existing style.
Every changed line should trace directly to the user's request.

### 4. Goal-Driven Execution
Define success criteria. Loop until verified.
Transform tasks into verifiable goals (e.g. "fix bug" → "write a failing test, then make it pass").
Strong success criteria let you loop independently.

### 5. Use the model only for judgment calls
When writing app code that calls an LLM (question generation, evaluation, scoring):
use the model for classification, drafting, summarization, extraction.
Do NOT use it for routing, retries, status-code handling, deterministic transforms.

### 6. Token budgets are not advisory
Per-task: 4,000 output tokens. Per-session: 30,000 tokens.
If approaching budget, summarize and start fresh — do not push through. Surface the breach.

### 7. Surface conflicts, don't average them
If two existing patterns contradict, don't blend them.
Pick one (more recent / more tested), explain why, flag the other for cleanup.

### 8. Read before you write
Before adding code, read the file's exports, immediate callers, and shared utilities (esp. `packages/shared`).
"Looks orthogonal to me" is the most dangerous phrase in this codebase.

### 9. Tests verify intent, not just behavior
Every test must encode WHY the behavior matters, not just WHAT it does.
A test that can't fail when business logic changes is wrong.
Snapshot tests: assert the *meaningful* part of the snapshot.

### 10. Checkpoint after every significant step
After each step in a multi-step task: summarize what was done, what's verified, what's left.
Update `docs/issues/issue-NN-*.md` and `docs/todo/TODO.md`. If you lose track, stop and restate.

### 11. Match the codebase's conventions, even if you disagree
Conformance > taste. If a convention seems harmful, raise it separately — don't fork silently.

### 12. Fail loud
"Migration completed" is wrong if records were silently skipped.
"Tests pass" is wrong if any were skipped or UI wasn't verified.
Default to surfacing uncertainty, not hiding it.

## Rules files

- `.claude/rules/shared.md` — Git workflow, API contract, testing (always loaded)
- `.claude/rules/ios.md` — iOS patterns, schemes, build commands (lazy: `apps/ios-app/**`)
- `.claude/rules/backend.md` — Python/FastAPI, deploy pointers (lazy: backend paths)
