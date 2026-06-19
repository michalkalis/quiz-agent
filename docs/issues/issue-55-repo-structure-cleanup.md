# Issue #55 — Repo file-structure cleanup (archive strays, add placement rules)

**Triage:** chore · in progress
**Opened:** 2026-06-12
**Status:** Plan re-verified 2026-06-16 against live repo state (was drafted 06-12 while another session ran; several assumptions had gone stale — corrected below). Execution started 2026-06-16.

## Problem

MD/HTML and other docs have accumulated in random places: legacy course-era files
at repo root, plan/research docs inside `apps/ios-app/`, task docs inside `data/`,
throwaway HTML reports in `docs/artifacts/`, and two memory files misplaced into
the repo. `docs/` itself is well-organized — the problem is files created *outside*
it, and no rule preventing recurrence.

## Plan

Default action is **archive, not delete** (per request). Delete only exact
duplicates and caches — git history keeps everything anyway.

New archive root: `docs/archive/<area>/`.

### A. Repo root — legacy course-era files (Nov–Dec 2025, pre-monorepo)

Verified 2026-06-16: nothing in `docs/`, `.claude/`, `.github/`, CLAUDE.md,
CONTEXT.md or app READMEs references the doc/code files below. `git log` confirms
`graph.py`/`quiz_main.py` are the "original quiz agent implementation from course"
— current code only *mentions* `graph.py` in three "Ported from graph.py" docstrings
(`parser.py`, `evaluator.py`, `text_normalization.py`), no real imports.

| File | Action |
|------|--------|
| `PRODUCT_SPEC.md`, `QUICK_START.md`, `SETUP_AND_TEST.md`, `IMPLEMENTATION_SUMMARY.md`, `CHATGPT_GENERATION_GUIDE.md`, `pub_quiz_generation_prompt.md` | → `docs/archive/legacy-course/` (all git-tracked → `git mv`) |
| `graph.py`, `quiz_main.py` | → `docs/archive/legacy-course/` (standalone legacy code; no imports, only docstring mentions) |
| `README.md` | Replace — current content describes the old LangGraph course assignment ("Assignment Context"). Write a short monorepo README (layout + pointer to CLAUDE.md/CONTEXT.md). Old one → `docs/archive/legacy-course/README-course.md`. Path `README.md` stays, so no inbound links break. |
| `Dockerfile`, `fly.toml` | **CORRECTED — archive, NOT delete.** They are **not** duplicates of `apps/quiz-agent/` versions: they are the stale *course-era single-app* ancestors (root `fly.toml` uses `[http_service]`/`primary_region=iad`/no `build_context`; root `Dockerfile` still installs `langchain*` and lacks `ffmpeg`). The live deploy uses `apps/quiz-agent/{Dockerfile,fly.toml}` — `fly deploy -c apps/quiz-agent/fly.toml` resolves `dockerfile="Dockerfile"` relative to the **config file's dir**, i.e. `apps/quiz-agent/Dockerfile` (which has `ffmpeg`, `COPY scripts`, `primary_region=cdg`). Both share `app="quiz-agent-api"`, so the root pair is harmless but obsolete. → `git mv` both to `docs/archive/legacy-course/`. **Also fix the doc lag:** `docs/runbooks/fly-deploy.md` Pitfall 1 still says "the repo-root `Dockerfile`" — update to `apps/quiz-agent/Dockerfile`. |
| `questions_export.json` | **Delete** (`git rm`) — confirmed byte-identical to `apps/quiz-agent/questions_export.json` (`diff` clean). |
| `__pycache__/` | Already gitignored — just `rm -rf` the dir. |
| `pyproject.toml`, `uv.lock`, `chroma_data/`, `.env*`, `infra/`, `design/` | **Keep** — workspace tooling / runtime data / live design+infra, out of scope (see allowlist in G). |

### B. `apps/ios-app/` — stray plan & design docs

`issue-15` (DONE, historical) line 140 already classifies the plan docs as
"historical notes — leave as-is" and explicitly excludes them from its rename
sweep; archiving them is consistent. We do **not** rewrite issue-15's prose to
chase the moved paths (it is a closed historical record).

| File | Action |
|------|--------|
| `DESIGN_SPEC.md`, `REFACTORING_PLAN.md`, `VOICE_AUTOMATION_RESEARCH.md`, `VOICE_COMMANDS_PHASE_2/3/4.md` | → `docs/archive/ios-plans/` (all stale; work since tracked via `docs/issues/`). Only inbound refs are in DONE `issue-15` (historical) — leave those. |
| `design/stitch_onboarding_mic_permission/**/*.{html,png}` (6 dirs) | → `docs/archive/design-stitch/` (superseded by Pencil `design/quiz-agent.pen` + `docs/design/`) |
| `Hangs/QUICK_SETUP.md`, `SETUP_ENVIRONMENTS.md`, `README_ENVIRONMENTS.md`, `TESTFLIGHT_SETUP.md` | → `docs/setup/` (**still current** — `TESTFLIGHT_SETUP.md` is the live runbook cited by the `testflight` skill). **Move + update the 2 path refs in `.claude/skills/testflight/SKILL.md`** (lines ~22, ~88). Consolidate only if trivial; otherwise move as-is. |
| `README.md` | Keep (apps keep exactly one README). |

### C. `data/` — task docs mixed into data

| File | Action |
|------|--------|
| `data/NEXT_TASKS.md`, `data/ENGAGEMENT_PATH_FOLLOWUP.md`, `data/examples/REVIEW_TASK.md` | → `docs/archive/data-tasks/` (verified 2026-06-16: no inbound references). |
| `data/questions/batch-*.md`, `backfill-needs-fix.md`, `data/examples/*.json` | **Keep** — live question-pipeline data, correctly placed. |

### D. `docs/artifacts/` — throwaway HTML reports — **DEFERRED**

Policy says **HTML = throwaway**, but the dir now holds ~46 entries and **many are
linked from live `docs/todo/TODO.md` and `docs/issues/*`** (e.g.
`voice-answer-screen-fix-plan.html`, `agent-loops-readiness-v2-*.html`,
`visual-verify-54-*.html`, `asc-setup-instructions-*.html`). Blanket-archiving
pre-June files would break those links. **Deferred** — low value, real link cost.
Revisit later as a targeted pass that only moves artifacts with **zero** inbound
references, updating any links it does touch. No decision needed now.

### E. `docs/handoffs/`

Archive convention already exists (`docs/handoffs/archive/`). Current top-level
handoffs (2026-06-16): `06-08-1659`, `06-09-1455`, `06-13-1049`, `06-15-1431`,
`06-15-1618`, `06-15-2047`. Keep the 2 newest (`06-15-2047`, `06-15-1618`); move
the other 4 to `archive/`. **`06-08-1659` and `06-09-1455` are linked from
`docs/todo/TODO.md`** (lines ~49, ~51) — update those 2 links to the archive path
in the same commit.

### F. Misplaced memory files

Both repo copies **differ** from the canonical files in the real memory dir
(`~/.claude/projects/.../memory/`, indexed in `MEMORY.md`) — they are stale /
accidentally-committed snapshots, so removing them loses no live fact.

| File | Action |
|------|--------|
| `memory/project_agent_mac_setup.md` (repo root, **untracked**, May 29 — older than the canonical Jun 11 copy) | `rm` the file + remove the empty `memory/` dir. |
| `.claude/projects/-Users-.../memory/project_product_vision.md` (**tracked** — accidental commit) | `git rm -r .claude/projects/`. |

### G. Prevention — file-placement rule

1. Add a short **File placement** section to `.claude/rules/shared.md`:
   - Repo-root doc allowlist: `README.md`, `CLAUDE.md`, `CONTEXT.md` only.
   - Root non-doc allowlist (out of scope, keep): `pyproject.toml`, `uv.lock`,
     `.env*`, `chroma_data/`, `infra/`, `design/` (live Pencil source —
     `design/quiz-agent.pen`, referenced by #52/#54), plus dotdirs.
   - Each `apps/*` keeps exactly one `README.md`; no plan/research docs inside apps.
   - Everything else under `docs/` by type: issues → `docs/issues/`, research →
     `docs/research/`, HTML reports → `docs/artifacts/`, handoffs →
     `docs/handoffs/`, test runs → `docs/testing/runs/`, setup guides →
     `docs/setup/`, design → `docs/design/`.
   - Outdated docs → `docs/archive/<area>/`, never deleted ad hoc.
2. Optional hard gate: pre-commit check in `.githooks/` rejecting new `.md`/`.html`
   outside allowed paths. Decide during execution whether the rule alone suffices
   (lean: rule only — a hook risks false-positives on the many valid `docs/` paths).

### Deferred follow-up (not this issue)

- `design/quiz-agent.pen` logically belongs in `docs/design/`, but it is the live
  Pencil source with **pending in-editor edits awaiting a ⌘S save** (#52) and ~10
  inbound references across issues. Moving it now risks confusing the open Pencil
  session and breaking refs. Allowlist it at root for now; relocate in a dedicated
  pass once #52's save lands.

## Execution order

1. `git mv` / archive moves per A–C, E (one commit per section, type `chore(repo)`).
2. Memory cleanup (F).
3. New root README + `.claude/rules/shared.md` placement rule (G) + runbook fix (A).
4. Link this issue from `docs/todo/TODO.md`; add to `docs/issues/INDEX.md`.
5. Verify: backend tests still pass (`cd apps/quiz-agent && pytest tests/`),
   `rg` for any broken doc links to moved files.

## Risks

- Root `Dockerfile`/`fly.toml`: re-verified they are **not** what deploy uses
  (`-c apps/quiz-agent/fly.toml` → `apps/quiz-agent/Dockerfile`). Archived (not
  deleted) so the move is trivially reversible if a deploy surprises us; runbook
  Pitfall 1 corrected in the same change.
- `TESTFLIGHT_SETUP.md` is a live runbook (testflight skill) — move + fix skill
  refs in one commit, don't archive.
- `docs/artifacts/` mass-move deferred precisely because of inbound links.

<!-- obsidian-links:start -->
## Súvisiace issues
[[issue-52-design-refresh-sweep|#52 iOS design-refresh sweep]] · [[issue-54-design-refresh-regressions|#54 Design-refresh sweep regressions]]
<!-- obsidian-links:end -->
