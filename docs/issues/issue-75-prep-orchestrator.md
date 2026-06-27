# Issue #75 — Automated issue-prep orchestrator (research → plan → review → split)

**Triage:** tooling/process · ready-for-human (interactive build, founder-in-loop)
**Reversibility:** a (commits-only — new Claude Code skills, no schema/auth/payments)
**Status:** design approved 2026-06-27 (cadence = "stop only when blocked"); building Phase 0 next

Research backing this issue: `docs/artifacts/issue-prep-pipeline-research-2026-06-27.html`.

## Why

Today the founder manually drives every preparation step before an issue is ready for the execution loop (Ralph): runs research, drafts the plan, reviews it, writes the implementation plan, re-reviews, and hand-splits the work into session-sized prompts — while babysitting context size and re-launching sessions. The *execution* loop already exists; the *preparation* front of the funnel is fully manual. This automates that front: one trigger turns a prompt or an existing issue into a ready, well-formed issue file.

## Scope

One input (a founder prompt **or** an existing `issue-NN-*.md`) → a 6-phase prep chain → a ready issue (+ for large issues, an `issue-NN-execution-prompts.md`). Each phase runs as a **fresh subagent**, so no single context bloats. The orchestrator runs in-session so the founder can watch and interject.

The six phases (mapped to existing tools where they exist):

1. **Research** — facts (`/research` / `/deep-research`) + code-recon (Explore subagents) → `docs/research/*` and/or the issue file.
2. **Plan** — draft `## Why` / `## Scope` / `## Resolved design decisions`.
3. **Plan review** — adversarial reviewer with *plan-only isolation* (sees the plan, not the authoring chat), reusing `/ready-check` semantics; **loop until it passes** (cap N, then escalate to founder).
4. **Implementation plan** — draft `## Tasks (atomic)` + machine-evaluable `## Acceptance`.
5. **Impl-plan review** — `/ready-check` again + DoR C1–C7 (from #57).
6. **Split** — new `/split-issue` → atomic `- [ ]` tasks + `issue-NN-execution-prompts.md` (template = `issue-61-execution-prompts.md`).

## Resolved design decisions

- **D1 — One orchestrator, not 6 manual skills.** `/prepare-issue` is the single trigger. Per-phase units exist underneath (as sub-prompts) so the founder can re-run *one* phase manually when needed, but the normal interface is one command.
- **D2 — Cadence: "stop only when blocked"** (founder choice 2026-06-27). Auto-advances through all phases; pauses **only** when a review gate fails N times or a genuine product question surfaces. Founder can interject any time (it runs in-session).
- **D3 — Each phase = fresh subagent.** Cheap model (sonnet/haiku) for recon/synthesis, strong model only for the adversarial gates. Reuse Ralph's `route-model` logic — do **not** run the whole pipeline on Opus.
- **D4 — Visibility via a durable `## Prep progress` block** written into the issue file (checked-off phases + latest gate verdict), the source of truth for "what phase is it in"; survives a session restart. Plus live chat narration on every phase transition.
- **D5 — Reuse, don't rebuild.** Phases 1–5 wrap existing skills/conventions. The only genuinely new capability is the **splitter** (Phase 6).
- **D6 — Class b/c guard.** Auth/payments/migrations and schema changes route to `ready-for-human`, **never** `ready-for-agent` (Ralph runs class `a` only).
- **D7 — Out of scope now:** the unattended/night "prep-Ralph" loop draining a queue of ideas. Deferred to a later issue once `/prepare-issue` earns trust.
- **D8 — Queue handoff stays manual.** Adding the finished issue to `overnight-queue.md` remains the founder's editorial step.

## Size & dependencies

Size **M**. New code is markdown skill prompts + (optionally) one Workflow script; no app/runtime changes. Depends on #57 (DoR C1–C7 + `/ready-check`, already shipped). Adjacent to #71 (Ralph restore) — independent.

## Tasks (atomic)

- [ ] 75.1 — `/split-issue` skill (Phase 0): input a ready issue plan + a context budget → emit atomic `- [ ]` tasks and, for large issues, `issue-NN-execution-prompts.md` matching the `issue-61-execution-prompts.md` structure (recon snapshot, locked-decisions table, session table, one self-contained paste-in prompt per session). Independently usable on existing issues.
- [ ] 75.2 — `/prepare-issue` orchestrator skill: chain phases 1–5, call 75.1 for phase 6, write/update the `## Prep progress` block, narrate transitions, run the gate-loop with a failure cap → escalate to founder, pause-and-ask on product questions.
- [ ] 75.3 — Phase implementations: wire `/research` + Explore recon (P1), plan draft (P2), an adversarial plan-review subagent that reuses `/ready-check` with strict plan-only isolation (P3 + P5), impl-plan draft (P4).
- [ ] 75.4 — Model routing: reuse Ralph's `route-model` so recon/synthesis run on a cheap model and only the gates use a strong model.
- [ ] 75.5 — Class b/c guard: detect schema/auth/payment scope and land the output as `ready-for-human`.
- [ ] 75.6 — Dry-run end-to-end on one small existing backlog issue; founder eyeballs the produced issue file + `execution-prompts.md`.

## Acceptance

- [ ] `/prepare-issue <prompt-or-issue>` produces a populated issue file (`## Why` / `## Scope` / `## Resolved design decisions` / `## Tasks (atomic)` / `## Acceptance`) — and, for a large issue, a matching `execution-prompts.md` — **without** the founder triggering each phase.
- [ ] The `## Prep progress` block reflects the current phase at every step and is correct after a fresh-session reopen of the file.
- [ ] A failing plan-review gate causes a re-plan; after N consecutive failures the run **stops and asks the founder** rather than shipping a weak plan.
- [ ] A class b/c input lands as `ready-for-human` and is never marked `ready-for-agent`.
- [ ] `/split-issue` run alone on an existing ready issue emits a valid `execution-prompts.md` whose structure matches the `issue-61` template.

## Open / deferred

- Unattended "prep-Ralph" loop over an idea queue, with night-only guardrails (cutoff, lockfile, 3-fail halt) — **deferred** (D7).
- Auto-populating `overnight-queue.md` from the `ready-for-agent` state — kept manual (D8).

## Cross-refs

#57 (loop-verification backbone — `/ready-check`, DoR C1–C7) · #71 (Ralph restore) · research artifact `docs/artifacts/issue-prep-pipeline-research-2026-06-27.html`.
