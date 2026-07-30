# Issue #134 — Generation pipeline frontier fix run (2026-07-30)

**Triage:** enhancement · done
**Status:** Shipped to prod + staging 2026-07-30 (same-day execution of the
[generation deep review](../research/generation-review-2026-07-30.md) fix order,
plus the founder's new standing model policy). Live smoke runs green.

## Founder policy (standing, 2026-07-30)

The generation pipeline ALWAYS uses the best available frontier models — no
credit-saving there; AWS Bedrock (existing credit) is a first-class generation
channel alongside OpenRouter. Supersedes the #99 Phase-4 cheap-tier blind test
(glm-5.2 / kimi candidates) and issue #74's cost-driven shortlist.

## What shipped

**Model stack** (factory roles, `packages/shared/quiz_shared/llm/factory.py`):
generation `claude-fable-5` · critique/ranking/parse `gpt-5.6-sol` ·
verify/normalize `gemini-3.1-pro-preview` · second judge `gemini-3.1-pro-preview`
(SCORE_GOOGLE replaces the Anthropic judge — self-preference bias vs the Claude
generator) · translation `claude-opus-5`. EVAL (serve-time answer grader) is
deliberately unchanged — own cost model, separate founder decision. Slugs
verified against the live OpenRouter catalog 2026-07-30. Sampling params are
auto-dropped for families that reject them (Claude 5-class, gpt-5).

**Bedrock channel:** any role can be set to `bedrock:<exact-bedrock-model-id>`
— verbatim passthrough to `ChatBedrockConverse` (langchain-aws, in the
quiz-pack-api image). Fail-loud without AWS credentials; no silent fallback.
Activation needs founder AWS keys (steps in the session report; not yet set).

**Review findings fixed (A2–A6):** entertainment template now carries the
craft-guards placeholder + all fact-first templates assert their injection
placeholders at generator construction; judges see MCQ options + resolved
answer text (scorer, critique, pairwise); the structured MCQ path ships one
output contract (tool-schema note) and `why_interesting` exists on the schema
and persists to provenance; `answerability` is a real scored dimension and the
veto reads it; judge parse failures retry once then fail loud (no fabricated
5.0), `overall_score` is computed deterministically in code.

**Prompt consolidation (review B):** both active fact-first templates rewritten
to one precedence-ordered CONTRACT (grounding → answerability → portability →
clarity → fun), ~8k → ~3k assembled tokens, contradictions resolved by stated
precedence; CoT/self-critique scaffolding removed (frontier models get
goal+constraints via a model-keyed process header); static-first ordering with
a prompt-cache breakpoint (cache_control on the OpenRouter+Anthropic path).
Craft-guard RULES are now always-on in the contract; the `GEN_CRAFT_GUARDS`
flag injects the founder-calibrated worked illustrations + carve-outs.

**Example hygiene:** gold examples filtered to founder rating ≥8 (32 of 53
qualify; 4 sampled per order, stable within an order for cache hits),
anti-patterns capped at 3, OK tier + hardcoded BAD trio deleted (merged with
the same-day audit's loud-corpus-loader fix — no hardcoded example fallbacks
remain anywhere).

**Judge redesign (review C):** one dimension per call (7 dimensions × judges,
anchoring isolated, concurrent with a semaphore); best-of-N selection = absolute
critique prefilter → deterministic-ring pairwise refinement (wins decide, ties
by absolute score, A/B order alternated).

**#128 residual:** the custom-pack serving path now applies the
`language_dependent=False` filter for non-English sessions (column is NOT NULL
— safe for all existing rows).

## Config state (verified 2026-07-30)

- Fly secrets on `quiz-pack-api` + `quiz-pack-api-staging`: `V3_ESCAPE_HATCH`,
  `GEN_CRAFT_GUARDS`, `VETO_ENFORCE`, `CRAFT_GUARDS_ENFORCE` = true.
  `GENERATION_MODEL`/`CRITIQUE_MODEL` deliberately NOT set — the factory role
  defaults are the single source of truth; the env flags remain as overrides
  (e.g. for a future `bedrock:` id).
- `LLM_GATEWAY=openrouter` confirmed on quiz-pack-api prod; both quiz-agent
  envs carry `LLM_GATEWAY` + `OPENROUTER_API_KEY` (serve-time translation).
- Both envs deployed 2026-07-30; prod `/health` green.

## Verification

- quiz-pack-api: 709 unit + 8 integration green (integration mocks now route
  by structural prompt markers — critique and scorer share a model id).
- quiz-agent: 527 green. Ruff clean on touched files.
- Two live dry-run packs (4 q each, OpenRouter, ~50–70¢/pack): all stages
  fired, 4/4 survived gates; flags-on run free of the exact-year defect the
  flags exist to catch. Sample output + judge telemetry in the session report.

## Open tails

1. **Bedrock activation** — founder sets AWS keys (exact steps in session
   report), then optionally `GENERATION_MODEL=bedrock:<id>`.
2. **Fact sourcing quality** is now the binding quality lever: Tavily returns
   listicle-grade sources for generic prompts; question ceiling = fact ceiling.
   Candidate next issue.
3. **EVAL model** (serve-time grader, still gpt-4o-mini) — founder call,
   cost-sensitive (~100× per-answer impact).
4. **Generation resume** — corpus is 31 approved questions; pipeline is
   unblocked and quality-gated; founder go on batch size to regrow the corpus.
