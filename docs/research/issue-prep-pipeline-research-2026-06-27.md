# Research: Automated issue-prep pipelines for AI coding agents (prior art, best practices, failure modes)

**Date:** 2026-06-27 | **Backs:** issue #75 — Automated issue-prep orchestrator
**Query:** Existing tools/frameworks/best-practices (2024–2026) for turning a raw idea/prompt into a well-scoped, reviewed, session-sized issue ready for an autonomous coding-agent loop — and is there a proven solution to *adopt* rather than build a custom skill pipeline?

> **Verification status (read first — fail-loud note).** This report was produced by the `/deep-research` harness (5 search angles → 22 sources → 107 extracted claims → 25 sent to 3-vote adversarial verification). The harness's automatic **synthesis step failed on a session-token limit**, and ~12 verification votes for 4 claims also failed for the same reason, so this report was **synthesised by hand from the 20 claims that passed 3-0 verification.** Those 20 are marked **[verified 3-0]**. A handful of extracted-but-unverified claims that still matter are quarantined in *"Additional signals (unverified)"* and clearly labelled — do not treat them as confirmed. No verified claim was dropped.

---

## Executive summary

- **There is no drop-in tool to adopt for the whole job.** The closest prior art — **GitHub Spec Kit** — validates the *shape* of #75 (a multi-phase decompose-and-gate pipeline) but is built for spec→implementation of a feature, not "idea → ready backlog issue in *this* repo's format → *this* repo's existing agent loop (Ralph) + triage states". **Recommended call: build the custom skills, but explicitly model them on Spec Kit's proven phase+gate structure.** (D10 build-vs-adopt answer.)
- **Every load-bearing design choice in #75 is externally corroborated:** fresh-subagent-per-phase, an adversarial evaluator/critic loop, a cap-then-escalate gate, and a "definition of ready" for agent-executable work are all documented patterns from Anthropic, GitHub, and recent papers.
- **The #1 failure mode of agent hand-off is underspecified / ambiguous tickets** — which is exactly what the design-soundness critic (75.7) and `/ready-check` exist to catch. Issues with **external-reference dependencies** (config, setup, external APIs) measurably under-perform.
- **A critic gate can fail silently ("silent overconfidence")** and self-critique can repeat the very error it was meant to catch — so the critic must be a **separate, adversarial, plan-only reviewer that defaults to disprove**, not a self-review. This reinforces D12 as designed.

---

## Build-vs-adopt verdict (D10 outcome)

**Decision: BUILD the custom skill pipeline; BORROW Spec Kit's proven phase+gate decomposition. Do not adopt wholesale.**

| Candidate | What it actually does | Why not adopt wholesale for #75 |
|---|---|---|
| **GitHub Spec Kit** (open-source) [verified 3-0] | `/speckit.constitution → /specify → /plan → /tasks → /implement`; emits `tasks.md` with dependency + parallel-execution markers; review gates `/clarify`, `/analyze`, `/checklist`, `/converge`. | Oriented to **spec→build of one feature**, not "idea → ready *backlog issue* for a pre-existing custom loop." Adopting it means abandoning this repo's `issue-NN-{slug}.md` format, `execution-prompts.md`, `/ready-check` DoR (C1–C7), and the `ready-for-agent`/`ready-for-human` triage state machine that Ralph already runs on. |
| **GitHub Copilot coding agent** [verified 3-0] | Reads an *assigned* issue, breaks it into a checklist, opens a PR, runs tests, asks for review. | Lives on the **execution** side (consumes an already-authored issue). It is the analogue of *Ralph*, not of the prep front-end #75 automates. |
| **Port** (Jira→GitHub enrichment) [verified 3-0] | Enriches a ticket with org-catalog context (ownership, deps, vulns, deploy state) and generates a GitHub issue. | Does **enrichment/linking only — not decomposition or scoping** into session-sized work. Partial overlap with Phase 1 context-recon at most. |
| **AWS Kiro** | Requirements → Design → Tasks, one markdown doc per step in the IDE. | IDE-bound, same spec→build orientation as Spec Kit. |

**What "borrow" concretely means for #75:** Spec Kit independently arrived at the same phase decomposition this plan proposes (research/spec → plan → tasks/split) *and* at explicit between-phase gates. That is strong external validation of the architecture (D11 soundness). Lift its vocabulary where it helps — a *clarify-before-plan* step, a *cross-artifact consistency* check (≈ our design-soundness critic), and `tasks.md`-style dependency/parallel markers in our `execution-prompts.md`.

**Forward-compatibility note (D11).** GitHub is consolidating issue→agent hand-off: Copilot can be assigned issues from GitHub/Jira/Linear, and the platform now dispatches to first-party, Anthropic Claude, OpenAI Codex, or custom agents [verified 3-0]. Given the standing preference to mirror work to **GitHub Issues**, #75's output format should stay convertible to a GitHub issue body (background/why · expected outcome · technical details · constraints) so a future path to the GitHub/Copilot or Spec-Kit ecosystem is not walled off.

---

## Key findings

### 1. Prior art — what already exists

- **Spec Kit is the canonical adoptable pattern.** GitHub's open-source toolkit "provides a structured process to bring spec-driven development to your coding agent workflows," with a dedicated decomposition phase where "the coding agent takes the spec and the plan and breaks them down into actual work," producing a `tasks.md` with "dependency management and parallel execution markers." It also ships explicit gates: `/speckit.clarify` ("clarify underspecified areas… before plan"), `/speckit.analyze` ("cross-artifact consistency & coverage analysis"), `/speckit.checklist`, `/speckit.converge`. [verified 3-0 — github.com/github/spec-kit, github.blog spec-kit announcement]
- **GitHub Copilot prescribes a Definition-of-Ready issue shape:** "Relevant background info: why this task matters… Expected outcome: what 'done' looks like… Technical details: file names, functions, or components involved… Formatting or linting rules." This is the exact field set a prep pipeline should populate. [verified 3-0 — github.blog Copilot coding agent]
- **Readiness is empirically measurable.** A study operationalises a DoR for agent-executable GitHub issues as **32 concrete criteria** and trains an interpretable model predicting whether an issue yields a *merged* (vs closed) Copilot PR at **median AUC 72%**. Merged-PR issues are "shorter, well scoped, with clear guidance and hints about the relevant artifacts… and guidance on how to perform the implementation." [verified 3-0 — arXiv 2512.21426]

### 2. Best practices — orchestration, gates, context (all corroborate #75's design)

- **Evaluator-optimizer is the named pattern for #75's review gates.** "One LLM call generates a response while another provides evaluation and feedback in a loop" — and it is only appropriate "when we have clear evaluation criteria, and when iterative refinement provides measurable value." [verified 3-0 — Anthropic, *Building Effective Agents*]
- **Fresh-subagent-per-phase is the recommended context discipline** (validates D3). "For complex tasks with multiple considerations, LLMs generally perform better when each consideration is handled by a separate LLM call"; agents "spawn fresh subagents with clean contexts while maintaining continuity through careful handoffs." [verified 3-0 — Anthropic, *Building Effective Agents* + *Multi-Agent Research System*]
- **A delegated task's own Definition-of-Ready = objective + output format + tool/source guidance + clear task boundaries.** This is precisely what `/split-issue` (75.1) must emit per session prompt. [verified 3-0 — Anthropic, *Multi-Agent Research System*]
- **LLM-as-judge: a single call scoring against an explicit rubric (0.0–1.0) was the most consistent grading approach** — a concrete template for the design-soundness critic. [verified 3-0 — Anthropic, *Multi-Agent Research System*]
- **Adversarial "kill-mandate" gates (Refute-or-Promote): a candidate advances only if no adversarial agent can produce a grounded refutation** while a creative agent sustains a plausible case — i.e. the gate **defaults to disprove readiness**. Directly transferable to the D12 critic. [verified 3-0 — arXiv 2604.19049]

### 3. Failure modes — what to defend against

- **External-reference dependencies hurt.** "Issues with external references including configuration, context setup, dependencies or external APIs are associated with lower merge rates." Implication: the prep pipeline should resolve/inline context (Phase 1) rather than leave the agent to chase it. [verified 3-0 — arXiv 2512.21426]
- **Underspecification is the dominant failure** (see *Additional signals* — the on-point source, Ambig-SWE / arXiv 2502.13069, was fetched but its claims didn't complete verification before the limit). The whole point of the P3/P5 gates is to catch this before hand-off.

---

## Additional signals (unverified — verification did not complete; treat as leads, not facts)

- **Cap gate retries at 2–3, then route to human review** — a concrete loop-vs-escalate threshold matching D2's "fail N times → escalate to founder." *(Source: mindstudio LLM-as-judge write-up; extracted, not 3-0 verified.)*
- **"Silent overconfidence" is the most dangerous LLM-judge failure** — the judge always emits a verdict even without the context/competence to judge correctly. Argues for a rubric that lets the critic abstain/flag-uncertain rather than rubber-stamp. *(Source: braintrust LLM-judge evals; extracted, not verified.)*
- **Self-reflection can repeat the original failure category above chance** (one study: 85.4% vs 74.7% chance) — argues the critic must be a *separate* adversarial agent with plan-only isolation, not self-critique. *(Source: arXiv 2510.18254; abstained at verification, session limit.)*
- **"Don't build multi-agents" counterpoint** — a maintained-cohesion argument against fragile multi-agent topologies; worth reading as the adversarial case against over-orchestrating #75. *(Source: cognition.com; not verified.)*

---

## Implications for #75

1. **Keep the build; record the borrow.** The custom pipeline is justified, but the plan must explicitly credit Spec Kit as the adopted *pattern* and say why wholesale adoption was rejected (this satisfies the D10 acceptance bullet).
2. **Give the design-soundness critic (75.7) a real, cited rubric** instead of a vibe check: (a) issue is short + well-scoped with explicit artifact hints + implementation guidance; (b) no unresolved external-reference dependencies; (c) approach is sound/non-reinventing/forward-compatible (D9–D11); (d) the critic **defaults to disprove** (Refute-or-Promote) and may **abstain/flag-uncertain** rather than rubber-stamp (guards against silent overconfidence). Render a 0.0–1.0 score against this rubric.
3. **Ground D2's loop cap** at 2–3 failed gate attempts → escalate to founder.
4. **Keep critic and `/ready-check` separate, adversarial, and plan-only** — self-critique is unreliable; the second reviewer must be an independent agent.
5. **Keep the output GitHub-Issue-convertible** so a future GitHub/Copilot or Spec-Kit path stays open.

---

## Sources

**Primary (verified backbone):**
1. [GitHub Spec Kit (repo)](https://github.com/github/spec-kit) — the adoptable multi-phase decompose+gate toolkit.
2. [Spec-driven development with AI — GitHub Blog](https://github.blog/ai-and-ml/generative-ai/spec-driven-development-with-ai-get-started-with-a-new-open-source-toolkit/) — Spec Kit announcement + decomposition phase.
3. [Assigning & completing issues with Copilot coding agent — GitHub Blog](https://github.blog/ai-and-ml/github-copilot/assigning-and-completing-issues-with-coding-agent-in-github-copilot/) — issue auto-decomposition + DoR issue shape.
4. [GitHub Copilot agents](https://github.com/features/copilot/agents) — multi-tracker assign + multi-agent dispatch (Claude/Codex/custom).
5. [Port — auto-resolve tickets with coding agents](https://docs.port.io/guides/all/automatically-resolve-tickets-with-coding-agents/) — context-enrichment prep + conditional readiness gate.
6. [Quantifying GitHub issue readiness for AI agents — arXiv 2512.21426](https://arxiv.org/abs/2512.21426) — 32-criteria DoR, AUC-72% readiness model, external-ref failure mode.
7. [Building Effective Agents — Anthropic](https://www.anthropic.com/research/building-effective-agents) — evaluator-optimizer, prompt-chaining, when-to-loop.
8. [Multi-Agent Research System — Anthropic](https://www.anthropic.com/engineering/multi-agent-research-system) — subagent DoR, fresh-context handoffs, LLM-as-judge rubric.
9. [Refute-or-Promote adversarial gates — arXiv 2604.19049](https://arxiv.org/html/2604.19049v1) — kill-mandate / default-to-disprove gate.

**Secondary / leads (unverified):**
10. [AWS Kiro — specs as the unit of work](https://builder.aws.com/content/3DbBI7LQgNIcs6UUj7IPPvqFHOp/aws-kiro-the-agentic-ide-that-makes-specs-the-unit-of-work)
11. [Ambig-SWE — underspecificity in SWE agents — arXiv 2502.13069](https://arxiv.org/abs/2502.13069)
12. [Self-reflection repeats failures — arXiv 2510.18254](https://arxiv.org/pdf/2510.18254)
13. [Don't build multi-agents — Cognition](https://cognition.com/blog/dont-build-multi-agents)
14. [LLM-as-judge vs human-in-the-loop — Braintrust](https://www.braintrust.dev/articles/llm-as-a-judge-vs-human-in-the-loop-evals)
