# Issue #63 — Question-quality review: generation audit + corpus verification

**Triage:** enhancement · ready-for-human (founder-in-the-loop review; not blind-overnight)

**Created:** 2026-06-18 · **Founder:** Michal

## Why

Founder wants to (a) see what the quiz-pack-api generator *actually* produces across all
question types (classic/open, MCQ, lateral, image), and (b) verify the quality + factual
accuracy of the questions we already have — automated first, then a human pass over only the
flagged subset.

This issue **is the parked "whole generation process review"** that froze all generation on
2026-06-12 (see [[issue-42-question-quality-and-mcq]] Track F lines 358–359 and
`docs/todo/TODO.md` #30 PARK note). Generation stays parked for *corpus writes*; this review
runs **dry-run only** (no persistence) until the founder un-parks.

> **🎯 Refocus (founder, 2026-06-22):** the quality effort is now about **generation-flow quality**, not
> corpus evaluation. **Track A (generation audit) stays** — it is the diagnostic record that drove
> [[issue-42-question-quality-and-mcq]] Track F-R and [[issue-72-question-fun-engagement-redesign|#72]].
> **Track B (full corpus verification — 580 live + 587 archive + prod Postgres) is DE-SCOPED:** the founder
> may discard much of the existing corpus, and "evaluating already-generated questions" is explicitly not the
> goal. **One exception — still a must-fix:** the 6 factual problems Track B1 already surfaced in the
> **live-served** corpus (line 145, esp. `gen033_q01` — an APPROVED question with a backwards answer) are a
> trust bug and should be corrected regardless of the corpus decision. **Un-park** is still owned here, but its
> evidence comes from #42 task 42.30 (≥8/10 MCQ yield) + #72 Phase 6 (founder ear-test), **not** from
> completing Track B.

## Current state (verified 2026-06-18)

**Generator (quiz-pack-api):** code fully operational. 6-stage `PackGenerator`
(sourcing → best-of-N generation → fact-verify → multi-model scoring → pgvector dedup → persist).
Types: `text` (open/classic), `text_multichoice` (MCQ — 4 patterns: true_false, odd_one_out,
comparison_bet_older_larger, year_guess), open-shape (causal / lateral puzzle → stays `text`),
plus image subtypes (blind map, silhouette, hint image). Known defect: MCQ survival is poor
(last live batch 003 → 2/13 MCQ survivors) — that defect is *why* generation was parked.

**Keys (`.env`):** OPENAI ✓, TAVILY ✓, OPENROUTER ✓; GOOGLE ✗, ANTHROPIC ✗.
→ Decision: run with `LLM_GATEWAY=openrouter` so Gemini fact-verify + Claude second-scorer
route through the OpenRouter key at full quality (no direct-mode heuristic degrade).

**Existing corpus (local):**
- Live serving store = root `chroma_data/chroma.sqlite3`: **580** (278 approved + 272 pending `text`,
  25 image approved, 5 true_false). `source_url` ~94%; human `quality_ratings` only **62/580**.
- Unimported batch archive `data/generated/`: **587** (556 text, 25 MCQ, 6 TF; 533 pending / 54 approved).
  Each carries an AI self-critique score; none human-scored.
- Local Postgres `quiz_pack`: 1 dev row (empty). Production = Fly `PROD_DATABASE_URL` (not yet queried).

**Tooling (ready):** `/generate-questions` (wrapper over `scripts/generate_pack.py`),
`/score-questions` (5-dim quality → approve/revise/reject), `/verify-questions`
(fact-check + source backfill). Pipeline also has in-built `MultiModelScorer` + `FactVerifier`.

## Founder decisions (2026-06-18)

- Verify **everything, in the right order**: (1) live chroma 580, (2) unimported archive 587,
  (3) production Fly Postgres.
- Generation audit depth: **quick sample ~10/type**.
- Enable `LLM_GATEWAY=openrouter` for full-quality auto verify/score.
- Generation audit is **dry-run only** — no corpus writes during the review.

## Plan

### Track A — Generation audit ("what does it really generate")

- **63.A1** Set `LLM_GATEWAY=openrouter` in `.env` for the session; confirm the gateway resolves
  Gemini + Claude legs (no direct-mode warning).
- **63.A2** Dry-run sample, ~10 each, `--out` JSON, no DB:
  - classic/open: `generate_pack.py --prompt "<broad general theme>" --target-count 10 --dry-run --out a-open.json`
  - MCQ: same `--target-count 10 --mcq-bias --dry-run --out a-mcq.json`
  - lateral/open-shape: a prompt that routes through `question_generation_open.md` → `--out a-lateral.json`
  - (optional, if cheap) one image-subtype sample.
- **63.A3** Auto-score each sample (`/score-questions <file>`) and auto-verify accuracy
  (`/verify-questions <file>`). Capture: per-type **survival/yield rate** (esp. MCQ — does the
  2/13 defect reproduce?), score distribution, factual verdicts, source coverage.
- **63.A4** Compile a side-by-side **HTML report** (`docs/artifacts/gen-audit-2026-06-18.html`):
  live examples per type + scores + verdicts + the MCQ yield finding. → founder reviews, decides
  whether to un-park generation and/or trigger the #42 Track F structural fixes.

### Track B — Corpus verification (automated-first, then human)

Run in the founder-chosen order; each sub-corpus is one pass of the same loop.

- **63.B1 (live chroma 580 — first):**
  1. Export chroma → JSON (read-only; reuse existing export path / `questions_export.json`).
  2. Auto fact-verify (`/verify-questions`) → verdict per Q (correct / needs_review / needs_fix /
     incorrect); backfill the ~6% missing `source_url`.
  3. Auto quality-score (`/score-questions`) → 5-dim score; flag low scorers.
  4. Emit a **triage list** (HTML/MD) grouped by verdict severity; only flagged items go to human.
- **63.B2 (unimported archive 587 — second):** same loop over `data/generated/`; goal is to gate
  what may later be imported. Output feeds the import decision.
- **63.B3 (production Fly Postgres — third):** connect via `PROD_DATABASE_URL` (read-only),
  pull the authoritative corpus, run the same loop. Confirms what live users actually get.
- **63.B4 Human pass:** founder reviews only the flagged subsets from B1–B3; approve/fix/reject.

## Track A results — 2026-06-18 (DONE)

Ran 3 dry-run samples via `generate_pack.py` + `LLM_GATEWAY=openrouter` (28 questions, ~3¢ total,
no corpus writes). Full report: `docs/artifacts/gen-audit-2026-06-18.html`. Raw JSON+logs:
`apps/quiz-pack-api/data/audit-2026-06-18/{a-open,b-mcq,c-lateral}.{json,log}`.

**Verdict: the 2026-06-12 park was correct — every defect that triggered it reproduced, some worse.**

- **MCQ contract broken (CRITICAL):** `--mcq-bias` → **1/10** real `text_multichoice` (worse than the
  2/13 that caused the park). 9/10 degraded to open `text` tagged with open-shape patterns. Sub-batches
  fan out correctly but the prompt never *hard-requires* the MCQ output contract. → #42 Track F layer (a).
- **Dedup is a no-op (CRITICAL):** one pack had the same bridge question **3× verbatim**; dedup dropped 0
  (pgvector 42.19c deferred). → layer (c).
- **Sourcing ignores the prompt (CRITICAL):** "lateral puzzles" prompt → same generic opentdb/livescience
  facts as the other runs (heart-beats, stomach acid, Mount Elbrus recur across packs); Wikipedia returned
  0 facts in all 3 runs. → layer (b), broader than MCQ.
- **Lateral/puzzle + image unreachable via CLI (GAP):** explicit puzzle prompt → 0 puzzles, all factual
  `text`. The only shape the CLI reliably emits is factual open `text`.
- **7.0 quality gate is non-blocking (DESIGN):** runs logged "N/N below 7.0" then kept all; critique score
  (5.4–6.4) and MultiModelScorer (8–9) disagree by 2–3 pts on the same questions — neither trustworthy as
  a ship signal. Sub-batch path skips critique entirely.
- **Mixed sources** (Reddit/listicles) + **recurring answer/explanation drift** warnings.
- **Healthy:** pipeline runs clean ~3 min/~1¢ per pack; OpenRouter routes verify+score+embeddings with no
  degrade; surviving questions are mostly factually correct; `--dry-run` is side-effect-free.

**Recommendation: keep generation PARKED for corpus writes.** Un-park only after #42 Track F redesign:
(1) hard-require MCQ contract [biggest lever] → (2) land pgvector dedup → (3) prompt-honest sourcing +
distinct fact slices → (4) reconcile the two quality scorers → then re-run this audit (target MCQ ≥8/10,
0 dupes) before any live batch.

### How to re-run Track A (gotchas)
```
cd apps/quiz-pack-api && source ../../.venv/bin/activate
set -a && source ../../.env && set +a            # script does NOT auto-load .env
LLM_GATEWAY=openrouter PYTHONPATH="$(pwd)" python scripts/generate_pack.py \
  --prompt "..." --target-count 10 [--mcq-bias] --dry-run --out data/audit-XX.json
```
- **PYTHONPATH="$(pwd)" is mandatory:** both `apps/quiz-agent` and `apps/quiz-pack-api` ship a top-level
  `app` package via editable `.pth`; `quiz-agent` sorts first so `app` resolves to the wrong one. The
  script's `if _APP_DIR not in sys.path` guard fails to fix it (dir already present, just later). PYTHONPATH
  jumps the queue. (Worth a real fix later — see finding.)
- Use the `.venv` (py3.11), not `~/.local/bin/python` (3.14, no deps).

## Track B results — corpus (1) live chroma 580 — 2026-06-19 (CLOSED — de-scoped 2026-06-22)

> **Disposition (founder, 2026-06-23):** Track B is **closed**. Corpus 2 (archive 587) and 3 (prod
> Postgres) were **not** run — "let's not verify or score anything at the moment; we're improving
> generation flow, not evaluating the existing corpus." The 6 factual problems below are **deferred
> into the generation redesign** as test-cases/evidence for [[issue-42-question-quality-and-mcq]]
> Track F-R + [[issue-72-question-fun-engagement-redesign|#72]] — **no corpus writes**, including
> `gen033_q01`. Fact-verification was also abandoned (Tavily plan quota exhausted, HTTP 432, mid-run).
>
> **Read-path conflict to remember:** the handoff calls local chroma "what the app serves," but
> `backend.md` says ChromaDB is **frozen read-only legacy** since 2026-05-28 and the voice quiz reads
> from **Fly Postgres (pgvector)**. So `gen033_q01` being `approved` in local chroma does *not* prove
> real users get it — that lives in the un-queried prod store. Resolve before ever "fixing served copies."

Export (read-only, raw — bypasses the Pydantic validator that chokes on 5 `true_false`):
580 questions (308 approved / 272 pending; 550 text, 25 image, 5 true_false). **139/580 missing
`source_url`** (the handoff's "~6% missing" was wrong; real coverage 441/580). Report:
`docs/artifacts/corpus-verify-chroma580-2026-06-19.html`. Working data: `apps/quiz-pack-api/data/issue63/`.

- **Quality scoring: COMPLETE for all 580** (8 sonnet agents, multi_model_scorer rubric):
  106 approve (18%) · 347 revise (60%) · 127 reject (22%); avg 6.67. The generic seed questions
  (`q_geo_*`, `q_hist_*`, `q_sci_*`) dominate the reject tier.
- **Fact-verification: INCOMPLETE — Tavily plan quota exhausted (HTTP 432) mid-run.** Reliable for
  279/580: 255 correct, 18 genuine needs_review, **6 confirmed factual problems** (3 incorrect +
  3 needs_fix). **301 unverified** (176 hit a rate-limit degradation window returning instant
  conf-0 uncertains; 125 timed out). Cannot finish until Tavily quota resets or plan upgrades.
- **Triage tiers:** T1 incorrect=3 · T1 needs_fix=3 · T2 fact-uncertain=18 · T3 quality-reject=95
  (30 are approved & served) · T4 fact-check-pending=245 · T5 image-mode=25 (driving-friendliness
  N/A by design) · T6 clean=191. **Human worklist = T1–T3 = 119.**
- **6 factual problems:** `gen033_q01` (Methuselah vs pyramids — answer backwards, APPROVED),
  `q_b106c85e8c46` (Apollo LOC ratio — "5×" vs sources), `q_c70d98045eb6` (Titanic mirror-set —
  premise is an urban legend), + needs_fix: boxers riddle, conductor/bee analogy, Greenland shark age.
- **No corpus writes.** 86 source-URL backfills staged in `verify_enriched.json` (not applied —
  holding until verification completes). Backfill bottleneck: FactVerifier is single-sourced on Tavily.

## Acceptance

- Track A: an HTML report exists with ≥3 type samples, each with auto-score + fact verdict, and a
  stated MCQ yield number; founder has a clear un-park / fix decision in front of them.
- Track B: each targeted corpus has a per-question verdict + score and a flagged-subset triage list;
  the human pass has a concrete, bounded worklist (not "review all 580").
- No corpus writes occur during the review except explicit source-URL backfill on already-stored Qs.

## Links

- Parks/feeds: [[issue-42-question-quality-and-mcq]] (Track F MCQ fixes), [[issue-30-batch-generate-categories]] (general growth, also parked).
- Infra delivered by: [[issue-33-quiz-pack-api-phase-1]] (PackGenerator).
- Skills: `/generate-questions`, `/score-questions`, `/verify-questions`.

<!-- obsidian-links:start -->
## Súvisiace issues
[[issue-30-batch-generate-categories|#30 Batch-generate questions for new categories]] · [[issue-42-question-quality-and-mcq|#42 Question quality sweep + multichoice activation]]
<!-- obsidian-links:end -->
