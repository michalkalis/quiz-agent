---
name: prepare-issue
description: Orchestrate the whole issue-prep pipeline — turn a founder prompt or an existing issue-NN file into a ready, well-formed issue (+ an execution-prompts.md for large ones). Chains research → plan → dual-gate review → impl-plan → re-review → split; each phase a fresh Opus subagent; auto-advances and pauses only on a failed gate (cap then escalate) or a genuine product question. Use to prep an idea/issue for the Ralph loop without driving each phase by hand.
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Agent, Skill, AskUserQuestion
model: opus
---

# /prepare-issue

The **single trigger** (D1) that automates the manual front of the funnel. Today the founder hand-drives every prep step — research, draft, review, impl-plan, re-review, hand-split — while babysitting context size. The *execution* loop (Ralph) already exists; this automates everything *before* it. One input → a ready `issue-NN-*.md` (+ `issue-NN-execution-prompts.md` for large issues).

It **composes existing skills** (D5) — `/deep-research`, `/ready-check`, `/design-soundness`, `/split-issue` — and orchestrates them in-session so the founder can watch and interject. This skill is the conductor; the work happens in fresh subagents. **It is not a `Workflow`**: prep must run interactively (pause-and-ask the founder, D2) — a background Workflow can't.

## Invocation

`/prepare-issue <prompt-or-issue>` — e.g. `/prepare-issue "add Google sign-in alongside Apple"`, `/prepare-issue 51`, `/prepare-issue docs/issues/issue-51-*.md`. A bare number/path → that existing issue. Free text → a new idea (create the issue file first, below).

## Operating rules (read before running)

- **All phases on Opus 4.8 (D3).** Every `Agent`/subagent call passes `model: opus` explicitly — including the gate reviewers (a deliberate, scoped override of the usual "don't default to Opus" routing rule; `/ready-check` defaults to sonnet *standalone*, but inside this pipeline its gate runs on Opus). Issue-prep is high-leverage, low-frequency: quality over token cost.
- **Fresh subagent per phase** (research: fresh-subagent-per-phase context discipline). The main session stays the **coordinator, never the worker** — it spawns a subagent, gets a *compressed* return (a verdict / a one-paragraph summary / "issue file updated"), and never pulls raw research dumps or recon into its own context (CLAUDE.md Rule #12).
- **Durable progress (D4).** Maintain a `## Prep progress` block in the issue file (template below) — refreshed at **every** phase transition. It is the source of truth for "what phase is it in" and lets a fresh session resume. Plus narrate every transition live in chat.
- **Stop only when blocked (D2).** Auto-advance through all phases. Pause **only** when (a) a review gate fails the cap, or (b) a genuine **product** question surfaces — then ask the founder live (Rule #13), never guess.
- **Class b/c guard (D6).** Auth / payments / migrations / schema → land the issue `ready-for-human`, **never** `ready-for-agent` (Ralph runs class `a` only). `/split-issue` enforces this too.

## Setup

1. **Resolve the input.** Bare number / path → that issue (resolve `NN` → `docs/issues/issue-NN-*.md`). Free text → **create** `docs/issues/issue-NN-{kebab-slug}.md` at the next free `NN` using the triage "new issue" header convention (`**Triage:** <category> · needs-triage` / `**Status:**` / `**Created:**`), seeded with the founder's prompt as the raw idea under a `## Why` stub.
2. **Resume-aware.** If the issue already has a `## Prep progress` block, read it and resume at the first incomplete phase — do **not** redo finished phases. Otherwise start at Phase 1 and write the initial block.
3. Confirm the plan in one line to the founder (input → which phases will run), then go.

## The pipeline

Each phase below is **one fresh Opus subagent** (spawn via `Agent`, `model: opus`, scoped prompt + the issue path). After each phase: refresh `## Prep progress`, narrate the transition, checkpoint. Hand each subagent only what it needs; have it edit the issue file directly and return a short summary.

**Phase 1 — Research (D9 / D10).** The subagent runs three strands and inlines the result into the issue / `docs/research/*`:
- **Outward facts** — run `/deep-research` on the issue's open *technical* questions: cited, adversarially-verified external sources (official docs, standards/best-practice guides, reputable maintainers, GitHub reference impls).
- **Prior-art scan (D10)** — is there a proven library / service / established pattern that already solves this? Record an explicit **build-vs-adopt** call with a real reason; bias to adopt proven, maintained solutions.
- **Code recon** — read-only `Explore` subagents map the exact files / symbols / idioms / test patterns / head migration the work touches.
- **Inline context, don't defer it** — resolve config / setup / external-API details now (research: issues with unresolved external references merge at lower rates). Every non-obvious choice ends up cited.

**Phase 2 — Plan (D11).** The subagent drafts `## Why` / `## Scope` / `## Resolved design decisions`, applying the **second-order lens**: how the change affects the whole system and the **named** near-term roadmap, not just the immediate ask (e.g. Sign in with Apple must leave room for Google / email / passkey and a future Android/web client). Record the build-vs-adopt outcome from P1. Bar: **simple *and* robust** — no first-order hack, no speculative over-abstraction.

**Phase 3 — Plan review (D12 · dual gate).** Spawn **two** fresh Opus subagents **in parallel**, both in strict **plan-only isolation** — they read **only** the issue file and the sources it cites; neither sees this conversation (a fresh subagent context *is* the isolation guarantee):
- **Gate A — readiness/form:** apply the `/ready-check` rubric (DoR C1–C7). Returns `READY` / `NOT-READY` + Blockers.
- **Gate B — design soundness/substance:** apply the `/design-soundness` rubric (S1–S5, defaults to disprove, may abstain). Returns `SOUND` / `UNSOUND` + Flaws + a 0.0–1.0 score.

A phase **passes only when both are green** (`READY` *and* `SOUND`). The gate loop (below) handles failures.

**Phase 4 — Implementation plan.** The subagent drafts `## Tasks (atomic)` + a machine-evaluable `## Acceptance` block — each criterion falsifiable and naming **how** it's checked (a pytest path, `/verify-api`, an `RS-NN` GREEN, a curl, a file/state inspection), per the triage `## Acceptance` contract.

**Phase 5 — Impl-plan review (D12).** The **same dual gate** as Phase 3, now aimed at the concrete tasks/acceptance (is each task atomic, self-contained, objectively checkable; is the decomposition sound). Same pass rule, same loop + cap.

**Phase 6 — Split.** Invoke `/split-issue <issue>` (the Phase-0 skill): atomic `- [ ]` tasks and — for a large/multi-session issue — `issue-NN-execution-prompts.md` (recon snapshot + locked-decisions table + session table + one self-contained paste-in prompt per session). It applies the class b/c guard and self-containment bar itself.

## The gate loop (evaluator-optimizer + cap → escalate)

Phases 3 and 5 are an **evaluator-optimizer loop** (the named pattern for review gates — research: Anthropic *Building Effective Agents*):

1. Run both gates (fresh subagents, parallel). If both green → advance.
2. If either fails, collect its **Blockers** (ready-check) **+ Flaws** (design-soundness) **verbatim**, hand them to a fresh re-plan / re-impl subagent (Phase 2 / 4 again, scoped to the named defects), then **re-run both gates**.
3. **Cap = 3 cycles per phase** (research-grounded 2–3, D2). At the cap, **stop and escalate to the founder** (`AskUserQuestion`) with the outstanding items — re-plan once more / accept-with-a-recorded-caveat / abandon. **Never silently ship a plan a gate rejected.**

Each gate subagent is **independent and fresh** every cycle — "max 3 findings, one revision cycle, don't move the goalposts" lives *inside* each reviewer skill; the **3-cycle cap lives here**. The reviewers must be separate adversarial agents, not self-critique (research: self-reflection repeats the original failure category above chance).

## Pause-and-ask — product questions only (D2 · Rule #13)

If any phase surfaces a genuine **product** question — UX, scope boundary, feature behavior, monetization, vision — **stop and ask the founder live** (`AskUserQuestion`) with enough context to answer without digging, then weave the answer in. **Decide product matters *with* the founder** even when a default exists; never bake a guess into the plan. *Technical* gaps are not product questions — those go back through the gate loop, not to the founder.

## Finalize

- **Set the `**Triage:**` state.** `ready-for-agent` **only if** class `a` *and* both final gates green. Class `b`/`c` (auth / payments / migrations / schema) → `ready-for-human` (D6).
- **Close out the `## Prep progress` block** (all phases ✅, final gate verdicts recorded), update `docs/issues/INDEX.md`, and refresh the `docs/todo/TODO.md` line.
- **Queue handoff stays manual (D8).** Tell the founder the issue is ready and where it landed; do **not** auto-add it to `overnight-queue.md`.

## `## Prep progress` block (D4)

Write/refresh this exact block in the issue file. It is the durable resume point:

```markdown
## Prep progress

> *Maintained by `/prepare-issue` — durable record of where prep is; safe to resume from a fresh session.*

| Phase | State | Latest gate verdict |
|-------|-------|---------------------|
| 1 · Research          | ⬜ pending / 🔄 wip / ✅ done | — |
| 2 · Plan              | ⬜ pending | — |
| 3 · Plan review       | ⬜ pending | ready-check … · design-soundness … |
| 4 · Impl-plan         | ⬜ pending | — |
| 5 · Impl-plan review  | ⬜ pending | ready-check … · design-soundness … |
| 6 · Split             | ⬜ pending | — |

**Last updated:** <YYYY-MM-DD HH:MM> · **Next:** <phase> · **Gate attempts:** P3 0/3 · P5 0/3
```

## Guardrails

- **Coordinator, not worker.** Never do a phase's heavy lifting in the main context — always delegate to a subagent and keep only the compressed return (Rule #12). If a return is large, tell the subagent to write it to the issue/research file and return a pointer.
- **Don't skip the gates to "save time."** Both gates, both phases, every run. The whole value is catching under-specified or unsound plans before Ralph wastes a night on them.
- **Don't invent decisions or sources.** A `## Resolved design decisions` entry needs a real rationale; a non-obvious choice needs a real citation. A gap is a *finding*, surfaced — never papered over.
- **Reversibility is load-bearing.** Detect sensitive scope early; if class `b`/`c`, say so up front and route to `ready-for-human` — the splitter and triage both depend on the `**Reversibility:**` line being honest.

## References

- **Composed skills:** `.claude/skills/split-issue/SKILL.md` (Phase 6), `.claude/skills/design-soundness/SKILL.md` (substance gate, S1–S5), `.claude/skills/ready-check/SKILL.md` (form gate, C1–C7 + plan-only isolation), `/deep-research` (Phase 1 facts), `.claude/skills/triage/SKILL.md` (DoR C1–C7, states, `## Acceptance` contract, issue headers).
- **Evidence base:** `docs/research/issue-prep-pipeline-research-2026-06-27.md` — evaluator-optimizer gates, fresh-subagent-per-phase, delegated-task DoR (objective/format/tools/boundaries), cap-then-escalate (2–3), the external-reference failure mode, Refute-or-Promote, and the GitHub Spec-Kit prior art the pipeline borrows from.
- **Plan:** `docs/issues/issue-75-prep-orchestrator.md` — D1–D12 and the acceptance criteria this skill must satisfy.
