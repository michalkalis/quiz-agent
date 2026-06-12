# Issue #55 — Repo file-structure cleanup (archive strays, add placement rules)

**Triage:** chore · planned
**Opened:** 2026-06-12
**Status:** Plan only — execution deferred because another session is active. No files moved yet. TODO.md / INDEX.md links to be added at execution time (left untouched now to avoid conflicting with the running session).

## Problem

MD/HTML and other docs have accumulated in random places: legacy course-era files
at repo root, plan/research docs inside `apps/ios-app/`, task docs inside `data/`,
28 throwaway HTML reports in `docs/artifacts/`, and two memory files misplaced into
the repo. `docs/` itself is well-organized — the problem is files created *outside*
it, and no rule preventing recurrence.

## Plan

Default action is **archive, not delete** (per request). Delete only exact
duplicates and caches — git history keeps everything anyway.

New archive root: `docs/archive/<area>/`.

### A. Repo root — legacy course-era files (Nov–Dec 2025, pre-monorepo)

Verified: nothing in `docs/`, `.claude/`, `.github/`, CLAUDE.md, CONTEXT.md or app
READMEs references any of these. `git log` confirms `graph.py`/`quiz_main.py` are
the "original quiz agent implementation from course".

| File | Action |
|------|--------|
| `PRODUCT_SPEC.md`, `QUICK_START.md`, `SETUP_AND_TEST.md`, `IMPLEMENTATION_SUMMARY.md`, `CHATGPT_GENERATION_GUIDE.md`, `pub_quiz_generation_prompt.md` | → `docs/archive/legacy-course/` |
| `graph.py`, `quiz_main.py` | → `docs/archive/legacy-course/` (standalone legacy code; verify no imports first: `grep -r "import graph\|quiz_main" apps packages scripts`) |
| `README.md` | Replace — current content describes the old LangGraph course assignment. Write a short monorepo README (layout + pointer to CLAUDE.md/CONTEXT.md). Old one → archive. |
| `Dockerfile`, `fly.toml` | **Delete** — exact duplicates of `apps/quiz-agent/` versions (same `app = "quiz-agent-api"`); runbook `docs/runbooks/fly-deploy.md` deploys from `apps/quiz-agent`, CI never deploys from root. |
| `questions_export.json` | **Delete** after diff against `apps/quiz-agent/questions_export.json` (apparent duplicate; if they differ, archive instead). |
| `__pycache__/` | **Delete** + ensure gitignored. |
| `pyproject.toml`, `uv.lock`, `chroma_data/` | **Keep** — workspace tooling / runtime data, out of scope. |

### B. `apps/ios-app/` — stray plan & design docs

| File | Action |
|------|--------|
| `DESIGN_SPEC.md`, `REFACTORING_PLAN.md`, `VOICE_AUTOMATION_RESEARCH.md`, `VOICE_COMMANDS_PHASE_2/3/4.md` | → `docs/archive/ios-plans/` (all stale; work since tracked via `docs/issues/`) |
| `design/stitch_onboarding_mic_permission/**/*.html` (6 files) | → `docs/archive/design-stitch/` (superseded by Pencil `.pen` file + `docs/design/`) |
| `Hangs/QUICK_SETUP.md`, `SETUP_ENVIRONMENTS.md`, `README_ENVIRONMENTS.md`, `TESTFLIGHT_SETUP.md` | → `docs/setup/` (likely still current — review during execution; consolidate overlap into one `ios-environments.md` if trivial, else move as-is) |
| `README.md` | Keep (apps keep exactly one README). |

### C. `data/` — task docs mixed into data

| File | Action |
|------|--------|
| `data/NEXT_TASKS.md`, `data/ENGAGEMENT_PATH_FOLLOWUP.md`, `data/examples/REVIEW_TASK.md` | → `docs/archive/data-tasks/` |
| `data/questions/batch-*.md`, `backfill-needs-fix.md` | **Keep** — live question-pipeline data, correctly placed. |

### D. `docs/artifacts/` — 28 throwaway HTML reports

Policy already says **HTML = throwaway**. Move everything not from June 2026
(≈20 files) to `docs/archive/artifacts/`; keep the current month in place.
Optionally purge the archive later — no decision needed now.

### E. `docs/handoffs/`

Archive convention already exists. Move all but the 2 newest handoffs into
`docs/handoffs/archive/` (5 files: 2026-06-08 → 2026-06-11-2136).

### F. Misplaced memory files

| File | Action |
|------|--------|
| `memory/project_agent_mac_setup.md` (repo root, untracked) | Delete after confirming the same fact exists in the real memory dir (`~/.claude/projects/.../memory/` — MEMORY.md already lists `project_agent_mac_setup.md`). Remove empty `memory/` dir. |
| `.claude/projects/-Users-.../memory/project_product_vision.md` (tracked — accidental commit) | `git rm -r .claude/projects/` after the same content check. |

### G. Prevention — file-placement rule

1. Add a short **File placement** section to CLAUDE.md (or `.claude/rules/shared.md`):
   - Repo root allowlist for docs: `README.md`, `CLAUDE.md`, `CONTEXT.md` only.
   - Each `apps/*` keeps exactly one `README.md`; no plan/research docs inside apps.
   - Everything else goes under `docs/` by type: issues → `docs/issues/`, research →
     `docs/research/`, HTML reports → `docs/artifacts/`, handoffs → `docs/handoffs/`,
     test runs → `docs/testing/runs/`, setup guides → `docs/setup/`, design →
     `docs/design/`.
   - Outdated docs → `docs/archive/<area>/`, never deleted ad hoc.
2. Optional hard gate: pre-commit check in `.githooks/` rejecting new `.md`/`.html`
   outside allowed paths (root allowlist + `docs/` + `data/questions/` +
   `.claude/` + `apps/*/README.md` + prompts/templates dirs). Decide during
   execution whether the CLAUDE.md rule alone is enough.

## Execution order

1. `git mv` moves per sections A–E (one commit per section, type `chore`).
2. Memory cleanup (F).
3. New root README + CLAUDE.md placement rule (G).
4. Link this issue from `docs/todo/TODO.md` and regenerate `docs/issues/INDEX.md`
   (deferred from planning to avoid clashing with the parallel session).
5. Verify: backend tests still pass (`cd apps/quiz-agent && pytest tests/`),
   `rg` for any broken doc links to moved files.

## Risks

- Another session may touch the same files — execute only when no parallel session runs.
- Root `Dockerfile`/`fly.toml` deletion: re-verify before deleting that no script
  invokes `fly deploy` from repo root (`rg "fly deploy" scripts .github`).
- `Hangs/*SETUP*.md` may contain still-current TestFlight/match steps — read before
  archiving; current ones move to `docs/setup/`, not archive.
