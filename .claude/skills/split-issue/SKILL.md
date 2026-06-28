---
name: split-issue
description: Split a ready issue plan into atomic, independently-committable `- [ ]` tasks and — for large/multi-session issues — a self-contained `issue-NN-execution-prompts.md` (recon snapshot + locked-decisions table + session table + one paste-in prompt per session) matching the issue-61 template. Use as Phase 6 of /prepare-issue, or standalone on any existing ready issue.
allowed-tools: Read, Grep, Glob, Write, Edit, Agent, Bash
model: opus
---

# /split-issue

Phase 6 (the "Split") of the #75 issue-prep orchestrator, and a standalone skill. It turns a **ready** issue plan into the unit an autonomous session actually consumes: atomic tasks, and — when the issue is bigger than one session — a set of self-contained, paste-in session prompts so each runs in a **fresh context without re-mapping the codebase**.

This is the inverse of `/ready-check`: ready-check decides *whether* an issue is executable; `/split-issue` makes it *executable in session-sized pieces*. It does **not** judge or fix the plan's substance — the Phase 3/5 design-soundness + readiness gates already did that. It assumes the issue passed them.

**Per D3, this skill runs on Opus 4.8** — the #75 pipeline's deliberate, scoped override of the usual "don't default to Opus" rule (quality over token cost for high-leverage, low-frequency prep work).

## Invocation

`/split-issue <issue-number-or-path> [context-budget]` — e.g. `/split-issue 61`, `/split-issue docs/issues/issue-72-*.md "one backend layer per session"`. Resolve a bare number to `docs/issues/issue-NN-*.md`. With no budget, use the default heuristic below.

## Inputs

- **Issue plan** (required) — a ready issue file with `## Why` / `## Scope` / `## Resolved design decisions` / `## Tasks` / `## Acceptance`. **If it is not ready** (no machine-readable `## Acceptance`, no `**Reversibility:**` class, or a scope that is really two tasks), **stop and say so — run `/ready-check` first.** Splitting an unready issue only multiplies the under-specification.
- **Context budget** (optional) — how much work fits one fresh session before context pressure forces a handoff. **Default heuristic: one cohesive layer/component, independently committable, a handful of files, verifiable by a single test/build/RS-NN run.** issue-61's Session A (migration + models + verifier + unit tests, no live endpoints) is the reference size.

## What you do

1. **Read the issue in full** + the files its `## Tasks` / `## Scope` name (to ground the recon). Do not re-derive the design — it is decided. Note the `**Reversibility:**` class and any sensitive scope (auth / payments / migrations / schema).
2. **Decide single- vs multi-session** (this is what "large" means):
   - **Fits one budget** (≈1–3 tasks, one layer, class `a`, one verification run) → the issue needs only a clean `## Tasks (atomic)` block. Make each task atomic + independently committable; do **not** emit an execution-prompts file. Report *"single-session — no split needed"* and stop.
   - **Exceeds one budget** (multiple layers, more than ~4 tasks, sensitive / class `b`/`c` needing staged human gates, or cross-cutting) → produce `docs/issues/issue-NN-execution-prompts.md` (below).
3. **Gather recon once** so sessions don't each re-map. Reuse the issue's recon if it already carries one; otherwise spawn read-only **Explore** subagents (one per affected subsystem — backend / iOS / web / …) to map exact files, symbols, idioms, the head migration, test patterns, and gotchas. Pass an explicit model (Opus per D3; Sonnet is acceptable for this mechanical mapping if optimising cost). **Compress each subagent's return to recon-snapshot bullets — keep raw file dumps out of the main context** (CLAUDE.md Rule #12).
4. **Cut sessions along dependency + risk + budget seams**, never arbitrarily. Each session must be atomic, independently committable, and ordered so it depends only on **already-merged** sessions. Size each to the budget. Mark which sessions may run in **parallel** and which **block** others (Spec-Kit-style dependency/parallel markers — see research). Sensitive (class `b`/`c`) or human-prerequisite work gets **its own session + a readiness-gate note**; never fold a human gate silently into an `a`-class session.
5. **Write each session prompt to the subagent Definition-of-Ready.** Every paste-in block must carry the four things a delegated agent needs to execute blind (research: Anthropic multi-agent system):
   - **objective** — the scope *and* explicit boundaries of what NOT to touch ("do not build the endpoint — that's Session B");
   - **output format** — commit/push cadence + which docs to tick/update;
   - **tool/source guidance** — the "Read first" list of exact files (so it doesn't re-map);
   - **clear task boundaries** — `Done =` an *objective* check (a pytest path green / build clean / RS-NN pass), never "works correctly".
   Keep each prompt **short, well-scoped, with explicit artifact hints + implementation guidance** — long, vague, or externally-dependent prompts measurably lower an agent's success rate (research: arXiv 2512.21426). **Resolve/inline context rather than send the agent to chase config/setup/external APIs.**

## Output — `issue-NN-execution-prompts.md`

Match the canonical structure of [`docs/issues/issue-61-execution-prompts.md`](../../../docs/issues/issue-61-execution-prompts.md) (the worked reference — read it before writing). Sections, in order:

1. **Title + header** — created date (from the session, not invented), a one-line "why split" (large / sensitive / N tasks), and the how-to-use line ("open a fresh session, paste the fenced block, go").
2. **Parent-plan link** (+ plan-review artifact link if one exists).
3. **`## Recon snapshot`** — what the codebase already gives us, grouped per subsystem, with **exact file paths, symbols, idioms, head migration, test patterns, and ⚠️ gotchas**. This is the shared context every session reads instead of re-mapping.
4. **`## Locked decisions`** — a table lifting the issue's `## Resolved design decisions` (+ any named founder decisions) **verbatim by id**, plus audience/coordination notes. Never invent a decision here (see Guardrails).
5. **`## Session breakdown`** — a table: `Session | Tasks | Risk | Notes`, with explicit dependency/parallel markers.
6. **`## Human prerequisites`** (only if class `b`/`c` or external setup) — exact, numbered, zero-prior-knowledge steps the founder must do outside the code (secrets, portal settings, keys), and which sessions they gate.
7. **One `## Ready prompt — Session X` per session** — a fenced ` ``` ` block, each self-contained: scope + boundaries → `Read first:` list → `Build:` numbered steps → `Done =` objective check → commit/push/tick instructions. A reader with only the fenced block + the named files must be able to finish the session.
8. **`## Status`** — `⬜`/`✅` per session, updated as sessions land (the durable "where are we" tracker).

When a downstream session exposes symbols a later session imports, add a short *"Session X delivered — exact symbols for Y"* note under Status (as issue-61 does) so the chain stays decoupled.

## Guardrails

- **Don't split an unready issue** — bounce to `/ready-check` (see Inputs).
- **Don't invent decisions.** Lift "Locked decisions" verbatim from the issue. If a session genuinely needs a decision the issue doesn't make, that's a *readiness gap* → surface it (escalate to the founder / back to the gate), never paper over it with a guess.
- **Class `b`/`c` guard (D6).** Sensitive scope (auth / payments / migrations / schema) lands as `ready-for-human` with a human-prerequisite block; **never** mark such an issue `ready-for-agent` (Ralph runs class `a` only).
- **Self-containment is the bar.** Each prompt must run from the fenced block + named files **with zero access to the authoring conversation** — the same isolation `/ready-check` enforces. If a prompt only makes sense with chat context, it isn't done.
- **In-pipeline vs standalone.** Inside `/prepare-issue`, also update the issue's `## Prep progress` + the `docs/todo/TODO.md` line. Run standalone, just write/refresh the file and report the path + the session count.

## References

- **Template (read first):** `docs/issues/issue-61-execution-prompts.md` — the canonical worked example this skill reproduces.
- **Isolation + DoR twin:** `.claude/skills/ready-check/SKILL.md` — C1–C7 and the plan-only independence rule.
- **Evidence base:** `docs/research/issue-prep-pipeline-research-2026-06-27.md` — subagent DoR (objective/format/tools/boundaries), the "short + well-scoped + artifact-hints → merged" empirics, the external-reference failure mode, and Spec-Kit dependency/parallel task markers.
