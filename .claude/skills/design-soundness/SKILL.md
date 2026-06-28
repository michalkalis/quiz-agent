---
name: design-soundness
description: Adversarial, plan-only design-soundness review of an issue plan — the substance twin of /ready-check. Judges the issue's technical *approach* (not UI, not form): is it sound, cited, not reinventing the wheel, forward-compatible, simple-and-robust (D9–D11)? Sees only the plan, never the authoring chat, and defaults to disprove. Use at Phase 3/5 of /prepare-issue, or standalone to flaw-hunt a plan's design.
allowed-tools: Read, Grep, Glob, WebSearch, WebFetch
model: opus
---

# /design-soundness

The **substance** gate of the #75 issue-prep pipeline, and a standalone skill. `/ready-check` asks *"is this issue executable to a verifiable done-state?"* (form — DoR C1–C7). `/design-soundness` asks the orthogonal question `/ready-check` deliberately does **not**: *"is the approach itself any good?"* A perfectly-scoped issue can still propose a first-order hack, reinvent a solved problem, or wall off the roadmap — and the form gate would wave it through. This one hunts for exactly that (D12: two gates, not one).

**Read-only.** Never edit, fix, or commit — you only render a verdict.
**Plan-only isolation.** Read the issue plan and the sources/files it cites; do **not** read the conversation that authored it. Independence from the author is the whole point (same rule as `/ready-check`).
**Per D3, runs on Opus 4.8** (the pipeline's scoped Opus override — flaw-hunting wants the strongest reasoning).

## Invocation

`/design-soundness <issue-number-or-path>` — e.g. `/design-soundness 75`, `/design-soundness docs/issues/issue-61-*.md`. Resolve a bare number to `docs/issues/issue-NN-*.md`. No argument → the issue under discussion.

## What you check — default to *disprove* (Refute-or-Promote)

Try to produce a **grounded flaw**. The plan is SOUND only if, after honestly trying, you cannot. Render each dimension as a finding, then a 0.0–1.0 soundness score (research: a single rubric-scored pass is the most consistent LLM-judge form).

- **S1 — Sound approach (robustness, D11).** Does it actually solve the stated problem, or only its surface? Hunt for: a wrong/leaky abstraction, hidden coupling, an unhandled edge case that breaks the core claim, or a **simpler correct approach the plan missed**. A first-order hack that "solves only itself" is a flaw.
- **S2 — Cited (D9).** Does every *non-obvious* technical choice carry an external source (official docs, standard, reputable maintainer, GitHub reference impl)? Unsourced load-bearing claims are a flaw. Spot-check (≤2 WebFetch) that a cited source actually says what the plan claims it does.
- **S3 — Prior-art / not reinventing (D10).** Is there a proven library, service, or established pattern that already solves this, which the plan ignores or under-weighs? Does the plan record an explicit **build-vs-adopt** decision *with a real reason*? A reinvented wheel — or an adopt-vs-build call made by omission — is a flaw. (≤2 targeted web checks to confirm/refute a prior-art claim; you are a critic, not the researcher — Phase 1 already searched.)
- **S4 — Forward-compatible (D11).** Does the change wall off a **named** near-term direction (e.g. Apple sign-in that boxes out Google/email/passkey; a schema that blocks a future client; a format that can't migrate to GitHub Issues)? Are second-order effects on the whole system considered, not just the immediate ask?
- **S5 — Simple *and* robust (D11).** Reject both failure modes: an over-abstraction built for a single use (gold-plating) **and** a fragile shortcut. The standing bar is simple without being brittle.

## Constraints (critics over-report — stay bounded)

- **Max 3 Flaws.** If you find more, report the 3 that most threaten the design. **One revision cycle** — re-review once after a fix; don't move the goalposts.
- **Substance only.** Do **not** report scope/acceptance/reversibility/wording/structure — that is `/ready-check`'s job. Approach-correctness only.
- **Don't re-litigate a settled decision** that the plan makes *with a stated rationale*, unless you can show the rationale is actually wrong (cite why). A `## Resolved design decisions` entry is presumed considered.
- **Apply differentially** (like `/ready-check`): a small reversible class-`a` change gets a light pass (is the approach sane + non-reinventing?); a large / cross-cutting / sensitive issue gets the full S1–S5, hard.
- **You may abstain.** If you lack the context or domain knowledge to judge a dimension, say *"uncertain — needs founder/expert"* rather than emit a confident verdict. Silent overconfidence (always scoring, never abstaining) is the most dangerous LLM-judge failure (research) — guard against it explicitly.

## Severity

- **Flaw** = a design-level defect that should block the phase: an unsound/first-order approach, a reinvented wheel with no build-vs-adopt rationale, an unsourced load-bearing choice, or a forward-compat break of a named roadmap item.
- **Caution** = a softer concern (a thinner-than-ideal citation, a prior-art option worth a look) that lowers confidence but doesn't by itself make the design unsound.

Verdict is `UNSOUND` if ≥1 Flaw; otherwise `SOUND` (Cautions alone don't block).

## Output

Structured, not an essay. Flaws, then Cautions (omit an empty section), then the verdict line:

```
Flaws:
- <design defect, naming the dimension (S1–S5) and the grounded reason>
Cautions:
- <softer concern>

SOUNDNESS_SCORE: 0.0–1.0
DESIGN_VERDICT: UNSOUND — <one-line reason naming the worst flaw>
```

A well-designed plan returns `DESIGN_VERDICT: SOUND` with a high score and no Flaws. Never emit more than 3 Flaws.

## Relationship to the pipeline (D12)

At Phase 3 (plan review) and Phase 5 (impl-plan review), this critic runs **alongside** `/ready-check`. A phase passes only when **both** are green — `/ready-check` SOUND on form *and* this skill SOUND on substance. Either one failing loops the phase (cap 2–3 attempts → escalate to the founder).

## References

- **Form twin:** `.claude/skills/ready-check/SKILL.md` — C1–C7, the plan-only isolation rule, and the bounded "max 3, one cycle" reviewer discipline this mirrors.
- **Rubric evidence:** `docs/research/issue-prep-pipeline-research-2026-06-27.md` — Refute-or-Promote (default-to-disprove), the rubric-scored LLM-judge, the silent-overconfidence failure mode, and the D9/D10/D11 bars.
