# #143 — Custom-pack COGS reduction (pack_30 ≈ $4.23 → sustainable margin)

**Triage:** enhancement · in-progress (interrupted)
**Status:** started 2026-08-04 on mba; that session was cut off mid-step-1, right before the analytical cost model was filled in. mba cannot push (GitHub creds invalid there), so the file sat stranded locally until it was recovered onto main 2026-08-06. Pipeline call structure below is verified; the per-phase $ split is still missing.
**Founder prompt:** 2026-08-04 — reduce pack generation COGS without visible quality loss. Retail €4.99, current COGS ≈ $4.23 → ~zero margin.

## Working hypothesis (verify with data first)

Quality is born in GENERATION, not evaluation (July pilot: the writing model decided quality). If true, the ~90/10 spend split (QA vs generation) is inverted — evaluation should shrink radically in favor of top-tier generation.

## Hard constraints (founder)

- Generation stays frontier-only — savings come from evaluation, never from writing.
- Bedrock Claude locked on the account — out of scope.
- GATE_V2 FAILED validation 2026-08-03/04 (bad decisions, not architecture) and is OFF — do not enable. Any gate change must pass the 2-cluster test before deploy.
- Recent optimizations were reverted for quality regressions → quality > speed of savings.
- No prod model swaps without founder-approved blind eval.
- Before any paid eval: price estimate to founder + check OpenRouter balance (LOW: $0.71 of $40 as of 2026-08-04).

## Plan (decision point after each step)

1. **[~] Real spend breakdown** of last successful pack_30 run (order `7dbef479-…`, 2026-08-04, $4.23) by phase/model.
   - Finding: NO per-call cost capture exists — `cost_tracking.py` only snapshots account-level `total_usage` before/after (`worker/tasks.py:175,183`). No generation IDs, no `response.usage` capture anywhere.
   - OpenRouter activity API requires a **management key** (we have inference-only) and serves only *completed* UTC days → 2026-08-04 available after UTC midnight.
   - Interim: analytical split from exact call-count formulas × measured prompt sizes × live OpenRouter prices (see Cost model below).
   - Follow-up (durable): capture `response.usage` + generation id per call → per-phase cost column per order.
2. **[ ] Measure real judge/critique benefit**: from step_log + questions.provenance of recent runs, how many questions did the panel actually drop/reorder vs what would have passed anyway; correlate with the 27 founder pilot ratings. If benefit is small → radical cut proposal (1 judge / 1 call / contested-only), not cosmetics.
   - Blockers: prod DB via Fly proxy (fly auth dead on mba); calibration set `apps/quiz-pack-api/data/pilot-2026-07-11/` is gitignored and absent on mba.
3. **[ ] Blind eval prep**: (a) generation fable-5 vs kimi-k3 vs glm-5.1; (b) critique+duels gpt-5.6-sol vs deepseek-v4-pro. Output = blind_review file, founder rates. No prod swap without approval.

## Pipeline call structure (verified from code 2026-08-04)

Clean pack_30 run ≈ 700–720 LLM calls:

| Phase | Model | Calls | Source |
|---|---|---|---|
| Generation open-slice | claude-fable-5 | 1 | `generation.py:217-219` |
| Generation best-of-N (58 q in 1 call) | claude-fable-5 | 1 | `advanced_generator.py:501-521` |
| Critique per candidate | gpt-5.6-sol | ~58 | `advanced_generator.py:524-536` |
| Pairwise duels (ring-3) | gpt-5.6-sol | ~174 | `advanced_generator.py:1593-1673` |
| Answerability gate | deepseek-v4-flash | ~30 | `answerability.py:141-198` |
| Fact verify arbiter | deepseek-v4-pro | 0–30 | `fact_verifier.py:149-217` |
| Judge panel 7 dims × 2 judges × 30 q | gpt-5.6-sol + gemini-3.1-pro | 420 | `multi_model_scorer.py:769-802` |
| Top-up rounds (0–2) | all above, scaled to shortfall | ×shortfall | `topup.py:44-127` |

## Cost model (provisional — analytical)

_To be filled from token measurement + live prices._

## Blockers / founder actions

- Fly token on mba expired (secrets/DB/logs unreachable); gh token invalid + SSH key unregistered (push blocked — commits stay local).
- OpenRouter management (provisioning) key needed for activity API.
- Calibration set copy to mba (gitignored `data/pilot-2026-07-11/`).
- OpenRouter credit top-up before eval (balance $0.71).

## Related

- #135 — gen pipeline founder feedback round 2 (gate call diet ~168→~36 idea; D6/D7 shipped 2026-08-03: overgen 2×, ring-3)
- #139 — hang observability (shipped; order `7dbef479` retry blocked on credit)
- #142 — non-JSON provider response bug
- [Gemini quiz teardown 2026-08-04](../research/gemini-quiz-teardown-2026-08-04.md) — parallel mba session the same evening; two-speed pack model (cheap unverified instant pack vs verified sellable corpus) is the biggest cost lever found there, plus built-in Google-search grounding as a possible replacement for our separate sourcing phase. Open founder product decision.
