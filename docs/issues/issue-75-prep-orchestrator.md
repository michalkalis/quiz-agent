# Issue #75 — Automated issue-prep orchestrator (research → plan → review → split)

**Triage:** tooling/process · ready-for-human (interactive build, founder-in-loop)
**Reversibility:** a (commits-only — new Claude Code skills, no schema/auth/payments)
**Status:** design approved 2026-06-27; research on disk + build-vs-adopt recorded (2026-06-28). Built: **75.1 `/split-issue`** + **75.7 `/design-soundness`** + **75.2 `/prepare-issue` orchestrator** (`.claude/skills/prepare-issue/SKILL.md`, 2026-06-28) — the orchestrator also folds in **75.3** (phase wiring) / **75.4** (all-Opus) / **75.5** (class b/c guard), since a single-prompt skill isn't separable into those code modules; they're written into the one file, not as standalone units. **All skills authored; the one remaining task is 75.6 — the end-to-end dry-run**, which is also the first real exercise of `/design-soundness` and of `/split-issue`'s large-issue path (both unproven until then).

Research backing this issue: [`docs/research/issue-prep-pipeline-research-2026-06-27.md`](../research/issue-prep-pipeline-research-2026-06-27.md) — outward, cited prior-art + best-practices research per D9 (the build-vs-adopt outcome is recorded below).

## Why

Today the founder manually drives every preparation step before an issue is ready for the execution loop (Ralph): runs research, drafts the plan, reviews it, writes the implementation plan, re-reviews, and hand-splits the work into session-sized prompts — while babysitting context size and re-launching sessions. The *execution* loop already exists; the *preparation* front of the funnel is fully manual. This automates that front: one trigger turns a prompt or an existing issue into a ready, well-formed issue file.

## Scope

One input (a founder prompt **or** an existing `issue-NN-*.md`) → a 6-phase prep chain → a ready issue (+ for large issues, an `issue-NN-execution-prompts.md`). Each phase runs as a **fresh subagent**, so no single context bloats. The orchestrator runs in-session so the founder can watch and interject.

The six phases (mapped to existing tools where they exist):

1. **Research** — *outward + inward.* Cheap local strands always run: code-recon (Explore subagents) + a **prior-art scan** (is there a proven library/service/pattern that already solves this?). The outward web pass — facts via `/deep-research` (cited, adversarially-verified web sources: official docs, standards/best-practice guides, reputable maintainers, well-regarded blogs, GitHub reference impls) — is **default-OFF**, gated to a genuine open external technical unknown or an explicit founder ask. → `docs/research/*` and/or the issue file, every non-obvious choice sourced (D9, D10).
2. **Plan** — draft `## Why` / `## Scope` / `## Resolved design decisions`, applying the **second-order lens**: how the change affects the whole system and named future directions (e.g. Apple sign-in today must not wall off Google/email/passkey or a future Android/web client). Target: simple **and** robust — no first-order hack, no speculative over-abstraction (D11).
3. **Plan review** — *two adversarial reviewers, plan-only isolation* (see the plan, not the authoring chat): (a) `/ready-check` for executability (DoR C1–C7) and (b) a **design-soundness critic** that hunts for flaws and checks D9–D11 (sound approach? not reinventing the wheel? forward-compatible?). **Loop until both pass** (cap N, then escalate to founder) (D12).
4. **Implementation plan** — draft `## Tasks (atomic)` + machine-evaluable `## Acceptance`.
5. **Impl-plan review** — `/ready-check` (DoR C1–C7, from #57) **+ the design-soundness critic again** on the concrete tasks/acceptance (D12).
6. **Split** — new `/split-issue` → atomic `- [ ]` tasks + `issue-NN-execution-prompts.md` (template = `issue-61-execution-prompts.md`).

## Resolved design decisions

- **D1 — One orchestrator, not 6 manual skills.** `/prepare-issue` is the single trigger. Per-phase units exist underneath (as sub-prompts) so the founder can re-run *one* phase manually when needed, but the normal interface is one command.
- **D2 — Cadence: "stop only when blocked"** (founder choice 2026-06-27). Auto-advances through all phases; pauses **only** when a review gate fails N times (research suggests a **2–3 attempt cap**) or a genuine product question surfaces. Founder can interject any time (it runs in-session).
- **D3 — Each phase = fresh subagent, all on Opus 4.8** (founder choice 2026-06-27, overriding the earlier cheap-recon/strong-gate split). Issue-prep is high-leverage and low-frequency — every phase (research, planning, flaw-hunting reviews) benefits from the strongest reasoning, so quality wins over token cost here. Fresh-subagent-per-phase still keeps each context small. This is a deliberate, scoped override of the usual "don't default to Opus" routing rule — it applies to this pipeline only.
- **D4 — Visibility via a durable `## Prep progress` block** written into the issue file (checked-off phases + latest gate verdict), the source of truth for "what phase is it in"; survives a session restart. Plus live chat narration on every phase transition.
- **D5 — Reuse, don't rebuild.** Phases 1–5 wrap existing skills/conventions where they exist (and reuse `/deep-research` for the facts pass rather than a new researcher). The two genuinely new capabilities are the **splitter** (Phase 6) and the **design-soundness critic** (the substance gate at P3/P5, D12) — `/ready-check` only covers form.
- **D6 — Class b/c guard.** Auth/payments/migrations and schema changes route to `ready-for-human`, **never** `ready-for-agent` (Ralph runs class `a` only).
- **D7 — Out of scope now:** the unattended/night "prep-Ralph" loop draining a queue of ideas. Deferred to a later issue once `/prepare-issue` earns trust.
- **D8 — Queue handoff stays manual.** Adding the finished issue to `overnight-queue.md` remains the founder's editorial step.
- **D9 — Research outward, but the web pass is gated (cost discipline; revised 2026-06-29).** Phase 1 **always** runs the two cheap local strands — code recon (Explore subagents) + a prior-art scan. The expensive outward web pass (`/deep-research`: cited, adversarially-verified external sources — official docs, standards/best-practice guides, reputable maintainers, well-regarded blogs, GitHub reference implementations) is **default-OFF**: it runs only on a genuine open *external* technical unknown (a new/unfamiliar third-party API, library, standard, or protocol the local strands can't settle) **or** when the founder explicitly asks. Most issues skip it. Every non-obvious technical choice still carries a source (recon / prior-art / — when the web pass ran — a cited external reference).
- **D10 — Prior-art first; don't reinvent the wheel.** Before proposing custom code, Phases 1–2 check for a proven library, service, or established pattern that already solves the problem. The plan records the build-vs-adopt call and why. Bias to adopt proven, maintained solutions; build only when adoption is genuinely worse.
- **D11 — Second-order / forward-compatibility lens.** Plans address how the change affects the whole system and the named near-term roadmap, not just the immediate ask (e.g. Sign in with Apple must leave room for Google/email/passkey logins and future Android/web clients). Standing bar: simple (not over-engineered) **and** robust/extensible.
- **D12 — Design-soundness gate ≠ readiness gate.** `/ready-check` validates only *executability* (DoR C1–C7); it does not judge whether the approach is correct, non-reinventing, or future-proof. So Phases 3 & 5 add a second adversarial reviewer — the design-soundness critic — that actively hunts for flaws and enforces D9–D11. A phase passes only when *both* reviewers pass; same loop-cap → escalate-to-founder rule.

## Prior art & build-vs-adopt (D10 outcome)

Outward research (`docs/research/issue-prep-pipeline-research-2026-06-27.md`) confirms **no drop-in tool to adopt** for the whole job. Closest prior art:

- **GitHub Spec Kit** (open-source) — `/specify → /plan → /tasks → /implement` with between-phase gates (`/clarify`, `/analyze`, `/checklist`). It independently arrives at #75's exact shape (decompose + gate), so it **validates the architecture** — but it targets spec→build of one feature, not "idea → ready *backlog issue* in this repo's `issue-NN` format → the existing Ralph loop + `ready-for-agent`/`ready-for-human` triage + DoR C1–C7." Adopting wholesale would mean abandoning that substrate.
- **GitHub Copilot coding agent** — issue→PR execution; the analogue of *Ralph*, not of this prep front-end.
- **Port** — ticket context-enrichment only, no decomposition.

**Decision: build the custom skills, borrow Spec Kit's phase+gate vocabulary** (clarify-before-plan, a cross-artifact consistency check ≈ the design-soundness critic, `tasks.md`-style dependency/parallel markers in `execution-prompts.md`). Keep the output **GitHub-Issue-convertible** so a future GitHub/Copilot or Spec-Kit path stays open (D11). Every load-bearing choice (fresh-subagent-per-phase, evaluator-optimizer critic loop, cap-then-escalate, subagent DoR) is externally corroborated — sources in the research file.

## Size & dependencies

Size **M**. New code is markdown skill prompts + (optionally) one Workflow script; no app/runtime changes. Depends on #57 (DoR C1–C7 + `/ready-check`, already shipped) and reuses `/deep-research` for the facts pass (D9). Adjacent to #71 (Ralph restore) — independent. All phase subagents run on Opus 4.8 (D3).

## Tasks (atomic)

- [x] 75.1 — `/split-issue` skill (Phase 0): input a ready issue plan + a context budget → emit atomic `- [ ]` tasks and, for large issues, `issue-NN-execution-prompts.md` matching the `issue-61-execution-prompts.md` structure (recon snapshot, locked-decisions table, session table, one self-contained paste-in prompt per session). Independently usable on existing issues. → authored `.claude/skills/split-issue/SKILL.md` (2026-06-28); structurally verified vs the issue-61 template; live end-to-end dry-run tracked under 75.6.
- [x] 75.2 — `/prepare-issue` orchestrator skill: chain phases 1–5, call 75.1 for phase 6, write/update the `## Prep progress` block, narrate transitions, run the gate-loop with a failure cap → escalate to founder, pause-and-ask on product questions. → authored `.claude/skills/prepare-issue/SKILL.md` (2026-06-28); 108 lines, all composed-skill refs resolve, harness-discoverable. **Not yet exercised** — live verification is 75.6.
- [x] 75.3 — Phase implementations: **specified within `prepare-issue/SKILL.md`** (a single-prompt skill folds the wiring into the orchestrator, not separable code modules): P1 `/deep-research` + prior-art scan + read-only `Explore` recon (D9/D10), P2 second-order-lens plan draft (D11), P3+P5 the two reviewers in strict plan-only isolation (fresh-subagent = isolation), P4 impl-plan draft. Exercised by 75.6.
- [x] 75.4 — Model: every phase **and** gate subagent pinned to Opus 4.8 (D3) — in the skill's Operating rules + each phase ("Every `Agent` call passes `model: opus`"); `/ready-check`'s standalone sonnet default is overridden inside this pipeline. No cheap-model routing. Folded into 75.2.
- [x] 75.5 — Class b/c guard: written into the skill (Operating rules + Finalize + Guardrails) — auth/payments/migrations/schema land `ready-for-human`, never `ready-for-agent`; `/split-issue` re-enforces it. Folded into 75.2.
- [ ] 75.6 — Dry-run end-to-end on one small existing backlog issue; founder eyeballs the produced issue file + `execution-prompts.md`.
- [x] 75.7 — Design-soundness critic (new): an adversarial, plan-only reviewer subagent that hunts for flaws and renders pass/fail on D9–D11 (sound + cited approach, prior-art considered, forward-compatible, simple-and-robust). Runs alongside `/ready-check` at P3 and P5; a phase passes only when both pass (D12). **Cited rubric** (research file): score 0.0–1.0 on — (a) short, well-scoped, explicit artifact hints + implementation guidance; (b) no unresolved external-reference dependencies (config/setup/external APIs measurably hurt agent merge rates); (c) sound / non-reinventing / forward-compatible (D9–D11). The critic **defaults to disprove** (Refute-or-Promote) and may **abstain / flag-uncertain** rather than rubber-stamp (guards against LLM-judge "silent overconfidence"); it is a *separate* agent, never self-critique.

## Acceptance

- [ ] `/prepare-issue <prompt-or-issue>` produces a populated issue file (`## Why` / `## Scope` / `## Resolved design decisions` / `## Tasks (atomic)` / `## Acceptance`) — and, for a large issue, a matching `execution-prompts.md` — **without** the founder triggering each phase.
- [ ] The `## Prep progress` block reflects the current phase at every step and is correct after a fresh-session reopen of the file.
- [ ] A failing plan-review gate causes a re-plan; after N consecutive failures the run **stops and asks the founder** rather than shipping a weak plan.
- [ ] A class b/c input lands as `ready-for-human` and is never marked `ready-for-agent`.
- [ ] `/split-issue` run alone on an existing ready issue emits a valid `execution-prompts.md` whose structure matches the `issue-61` template.
- [ ] The plan's non-obvious technical choices each carry a source (an external citation where the gated web pass ran; otherwise recon / prior-art), and the plan explicitly records a build-vs-adopt (prior-art) decision (D9/D10).
- [ ] The design-soundness critic runs at P3 and P5; a flaw it raises (unsound approach, reinvented wheel, or forward-compat break) blocks the phase until resolved, independently of `/ready-check` (D12).
- [ ] Every phase subagent is invoked on Opus 4.8 (D3).

## Open / deferred

- Unattended "prep-Ralph" loop over an idea queue, with night-only guardrails (cutoff, lockfile, 3-fail halt) — **deferred** (D7).
- Auto-populating `overnight-queue.md` from the `ready-for-agent` state — kept manual (D8).

## Cross-refs

#57 (loop-verification backbone — `/ready-check`, DoR C1–C7) · #71 (Ralph restore) · research `docs/research/issue-prep-pipeline-research-2026-06-27.md`.
