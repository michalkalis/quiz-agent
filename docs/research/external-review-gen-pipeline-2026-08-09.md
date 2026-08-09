# External independent review — generation pipeline (2026-08-09)

**Provenance:** Independent external reviewer, code-only (no access to our issue docs, locked decisions, or rationale — by design). Reviewed `apps/quiz-pack-api` orchestrator/stages/generation/sourcing/verification/scoring, prompts, `packages/shared` LLM factory, tests.

**Status:** Findings recorded verbatim (condensed), NOT yet assessed. A follow-up session will triage each finding (valid / already-known / by-design / wrong), map overlaps against #153 — generation pipeline mega review and #135 locked decisions D1–D10, and plan fixes.

Paths converted to repo-relative.

## Findings (reviewer's severity ranking)

### Critical

1. **Source attribution is non-binding and can be fabricated.** `app/generation/advanced_generator.py:795`, `app/orchestrator/stages/generation.py:469`. Any non-empty model-emitted `source_url` skips validation; `source_excerpt` also model-controlled. F8 proves only that a citation-shaped field exists, not grounding. *Rec:* immutable server-side `fact_id`; resolve URLs/excerpts server-side; reject model-supplied citations that aren't exact source references.

2. **Fact verification is confirmation-biased.** `app/sourcing/web_search_source.py:192`, `app/verification/fact_verifier.py:75`. Search query includes the claimed answer; fast path treats substring presence (or any number within ±10%) as agreement. Three snippets containing the answer ⇒ "verified" without entailment, authority, or entity match. *Rec:* search question WITHOUT the claimed answer, retrieve independent candidate answers, require structured entailment against item-level authoritative evidence.

3. **Verification failures / held-for-review questions remain eligible to ship.** `app/orchestrator/stages/verification.py:116,141`, `app/orchestrator/stages/scoring.py:168`. Missing verdicts kept, held items kept; scoring payload carries no verification evidence. Verifier outage ⇒ question can still pass scorer and persist. *Rec:* fail closed on missing verdicts for paid packs; held items exit the customer-delivery path unless real human review exists.

### High

4. **Generator controls its own verification bypass.** `app/orchestrator/stages/generation.py:437`, `app/verification/logical_verifier.py:159`. Model-emitted `pattern_used` routes lateral/logical questions away from factual verification + source requirement; no independent check of the label. *Rec:* classify question shape independently post-generation; never route on a model-controlled field.

5. **"DIRECT GENERATION MODE" is an input-string quality bypass.** `app/orchestrator/pack_generator.py:131`, `stages/sourcing.py:85`, `stages/generation.py:535`. Marker in order text skips sourcing + F8 grounding; code doesn't establish it's restricted to an internal path. *Rec:* server-side authorized feature flag, not user-controllable text; keep independent verification for all customer-visible questions.

6. **Scoring panel not statistically meaningful; fails open on partial results.** `app/scoring/multi_model_scorer.py:827`, `stages/scoring.py:304`. Missing dimensions only warned; stage averages whatever judge scores exist — one surviving judge can clear the gate. Averaging uncalibrated ordinal scores gives no uncertainty/quorum signal. *Rec:* minimum judge+dimension coverage, quarantine partial panels, track inter-judge variance, calibrate thresholds vs human labels.

7. **Model usage expensive without independence/marginal-quality justification.** `app/feature_flags.py:215`, `multi_model_scorer.py:792`, `advanced_generator.py:516`. With gate v2 off: 7 dimension calls × judge, on top of best-of-N critique, pairwise selection, answerability, verification; same model doubles as critique + one scoring role. *Rec:* deterministic checks → one structured judge call on shortlist → independent second judge only for borderline; measure quality lift per dollar.

8. **Hardened prompt versions (v4–v6) appear inactive in production.** `advanced_generator.py:314`, `app/worker/tasks.py:76`, `prompts/question_generation_v6_free.md:25`. Worker doesn't override the default template ⇒ v3 runs in prod while v4–v6 (winnability, defensible-answer, no self-answering-comparison rules) sit unwired. *Rec:* one canonical version via explicit config, assert active version in integration tests, archive dead variants. *(Note for assessor: v5/v6 are deliberately in Phase A blind testing per #153 — but the "prod still runs v3" observation needs verification.)*

### Medium

9. **Open-question branch disconnected from source grounding.** `advanced_generator.py:461`, `prompts/question_generation_open.md:34`. Open questions generated without `source_facts`, yet gate requires citation for factual open questions ⇒ model self-supplies or question dies. *Rec:* feed fact IDs to open branch, or restrict branch to independently-classified logical questions.

10. **Answerability is a weak single-model fuzzy gate.** `app/verification/answerability.py:36,67,151`. Substring/token-overlap matching, no negation handling, parse failures kept; open questions only checked for "committed to some answer". Discards valid hard questions, accepts confidently-wrong ones. *Rec:* semantic answer evaluation with confidence + accepted alternatives; model uncertainty as quality signal, not binary.

11. **Effective quality threshold far below stated objective.** `advanced_generator.py:583`, `stages/scoring.py:84`, `prompts/question_critique_v2.md:289`. `min_quality_score` accepted but unused; best-of-N picks top-of-pool even if all weak; final gate rejects only very low scores; critique rubric calls 5.5–6.5 "acceptable". Mediocre ships by design. *Rec:* calibrated real minimum vs human ratings; hard passes for clarity/answerability/factuality; regenerate or fail when pool has nothing above threshold.

12. **Source material raw, weakly validated; failures silently tolerated.** `app/sourcing/fact_sourcer.py:42`, `opentriviadb_source.py:122`, `web_search_source.py:165`. Facts marked unverified, Tavily snippets used directly as facts, OpenTDB wrapped without its dormant rewriter, per-source failures logged-and-continue. *Rec:* source-specific reliability policies, item-level provenance, validate claims pre-generation, fail/downgrade visibly when source mix unavailable.

13. **Paid orders can deliver materially short.** `stages/topup.py:148`, `worker/tasks.py:227`. Top-up accepts ≥80% of target; worker marks delivered with surviving count. *Rec:* require full count or explicit partial-pack/refund policy — never silently short.

14. **Correctness properties not adversarially tested.** `tests/integration/test_verify_score_http_mocks.py:9`, `tests/generation/test_advanced_generator.py:679`. Tests are wiring/happy-path; mocks intentionally contain the answer; no tests for arbitrary citations, wrong-answer contamination, verifier outage → scoring, generator-controlled bypass, worker stage order. *Rec:* adversarial e2e tests that fail the pack, not just record telemetry.

## Reviewer's redesign proposals

1. **Provenance as typed, server-owned contract** — stable fact IDs + claim-level evidence; generation references fact IDs, never authors URLs/excerpts; verification+persistence operate on immutable mapping.
2. **Fail-closed delivery contract** — independent shape classification, mandatory factual verification for factual questions, judge quorum + evidence-aware scoring, held/unverified never in paid delivery, enforced pack size.
3. **Staged evaluation** — deterministic checks → one structured judge panel on shortlist → independent second judge for borderline only; thresholds calibrated against human review data.

## Reviewer's open questions

- Is DIRECT GENERATION MODE unreachable for ordinary users (upstream auth layer)?
- Does any moderation system actually review `held_for_review` questions?
- Are source URLs meant as item-level citations or is domain-level provenance enough?
- Contractual behavior for underfilled paid packs?
- Are the model aliases genuinely independent deployments (no shared routing/fallback)?
- What human-rated calibration set backs current scoring thresholds?

## Assessment session TODO (for the follow-up session)

- [ ] Triage each finding: confirmed / known (map to #153 / #135 decisions) / by-design / refuted — verify each `file:line` claim in code before accepting.
- [ ] Cross-check against #153 mega-review scope — several findings (sourcing quality, ungrounded drops, prompt versions) overlap Phase 0/A work already done; decide what's genuinely new.
- [ ] Answer reviewer's open questions from code/infra facts (esp. DIRECT GENERATION MODE reachability — potential security issue).
- [ ] Produce prioritized fix plan (likely amend #153 or file new issue).
