---
name: generate-questions-session
description: TEMPORARY — replicate the prod direct-generation pipeline inside Claude Code sessions (subscription tokens, no paid API for LLM steps). Generation → dedup → web fact-check → deterministic guards → import as pending_review.
allowed-tools: Read, Bash, Agent, AskUserQuestion
argument-hint: "[count] [--category science-nature|history|geography-world|movies-music|sports|food-everyday] [--difficulty easy|medium|hard|mixed] [--no-import]"
---

# Generate Questions — Session Mode (subscription tokens)

Temporary alternative to `/generate-questions`. The prod pipeline (`generate_pack.py` → paid APIs) stays untouched and remains the default; this skill mirrors its **current** shape (#166 D21b: direct generation, no sourcing, judge gate OFF) but runs every LLM step inside Claude Code subagents, so the cost lands on the Claude subscription instead of API keys. Delete this skill when the experiment ends.

**Parity contract (do not drift):**
- Direct generation on a frontier Claude model (prod default is Fable 5 + `direct_v1` prompt) — no sourcing step, no judge panel.
- Fact-check is web-grounded (prod swapped to web-search fact-check in #166); ambiguous or unverifiable → question is dropped, never imported.
- Deterministic guards run the **actual prod code** (`app/scoring/craft_guards.py`, `compute_distractor_quality`) via `run_guards.py` in this skill dir — free, no LLM.
- Import uses the unchanged `scripts/import_questions_json.py`, always `--review-status pending_review`. (Embeddings during import are a cents-level OpenAI call — the only non-subscription cost.)

**Context discipline (mandatory):** every bulk step runs in a subagent with an explicit `model`; all intermediate data lives in files under the run dir; the driver session only ever sees counts, drop reasons, and file paths. Never paste question batches into the driver context.

## Arguments

| Arg | Default | Notes |
|-----|---------|-------|
| positional count | 30 | target question count |
| `--category` | mixed across all 6 | canonical taxonomy: `science-nature, history, geography-world, movies-music, sports, food-everyday` (source: `apps/quiz-pack-api/scripts/recategorize_corpus.py`; do NOT use the stale 8-value list in `app/generation/classification.py`) |
| `--difficulty` | mixed | |
| `--no-import` | off | stop after guards, leave final JSON on disk |

Questions are **English only** (standing founder rule).

## Pipeline

Run dir: `apps/quiz-pack-api/data/session_runs/<YYYY-MM-DD-HHMM>/` (never commit its contents).

### 0. Preflight

- Confirm DB reachability for dedup + import: `PROD_DATABASE_URL` set, or user runs `fly proxy` first (importer docstring documents the pattern). If unreachable and the user still wants to proceed: continue with `--no-import`, skip corpus dedup, and **say loudly** that dedup vs prod corpus was skipped.
- Confirm `OPENAI_API_KEY` is available if importing (embeddings).

### 1. Corpus dump (Bash, no LLM)

`psql "$PROD_DATABASE_URL" -c "\copy (SELECT id, question, correct_answer, topic, category FROM questions WHERE review_status = 'approved') TO '<run_dir>/corpus.csv' CSV HEADER"`

### 2. Generation — subagent, `model: fable` (parity with prod gen model; no swaps without founder approval)

One subagent per batch of ≤10 questions, max 3 concurrent. Each subagent:
- Reads `apps/quiz-pack-api/prompts/question_generation.md` and the JSON response contract in `app/generation/prompt_builder.py` (`prose_response_format`), plus gold-standard examples via the path used by `load_gold_standard`. Builds the direct_v1-style prompt itself — do not invent a new rubric.
- Gets an avoid-list: ~10 sampled question texts from `corpus.csv` (passed by file path, subagent reads it itself).
- Writes `<run_dir>/generated_<batch>.json`: a JSON array of full `Question` dicts (`packages/shared/quiz_shared/models/question.py`): required `id` (generate `uuid4` hex — the importer does NOT auto-generate ids), `question`, `correct_answer`, `topic`, `category`, `difficulty`; plus `type` (`text` or `text_multichoice`), `possible_answers` for MCQ, `alternative_answers`, `explanation`, `language_dependent`, `age_appropriate`, `source: "generated"`, `review_status: "pending_review"`. Leave `generation_metadata` empty — fact-check fills it.
- Returns ONLY: batch file path + count.

### 3. Dedup — subagent, `model: sonnet`

Reads `corpus.csv` + all `generated_*.json`. Drops near-duplicates vs corpus and within the batch (semantic judgment; prod thresholds for reference: cosine 0.85 vs corpus, token-overlap 0.60 in-batch). Writes `<run_dir>/deduped.json` + `<run_dir>/dropped_dedup.json` (with one-line reasons). Returns counts only.

### 4. Fact-check — subagents, `model: opus`, batches of ≤10, max 3 concurrent

Each subagent verifies its batch with WebSearch/WebFetch under the founder source-trust hierarchy: Wikipedia first (with citations), then authoritative primary sources; never aggregators; if even Wikipedia is ambiguous → drop the question. Per question it writes into the dict:
- `generation_metadata: {"extra": {"verified": true, "verification_score": <0.9 high | 0.7 medium>, "verification_notes": "<one-line reasoning + source>"}}` — only for questions it could positively verify. Score < 0.9 requires a note why.
- `source_url` + `source_excerpt` from the confirming source.
- Anything unverified, wrong, stale, or ambiguous goes to `dropped_factcheck.json` with a reason — never `verified: false` rows into the import file (the importer's fail-closed guard #158 would block them anyway; we drop earlier and loudly).

Output: `<run_dir>/verified_<batch>.json`. Returns counts + drop reasons only.

### 5. Deterministic guards (Bash, no LLM, prod code)

```bash
cd apps/quiz-pack-api && python ../../.claude/skills/generate-questions-session/run_guards.py \
  <run_dir>/verified_merged.json --out <run_dir>/final.json --rejects <run_dir>/dropped_guards.json
```
(Merge the `verified_*.json` files first with `jq -s 'add'`.) Guards = stem leak, long answers, imperial-only units, T/F balance, distractor quality ≥ 4 — same thresholds as `app/orchestrator/stages/scoring.py`.

### 6. Import (unless `--no-import`)

From `apps/quiz-pack-api/` cwd (standing rule): dry-run first, then
```bash
python scripts/import_questions_json.py --json-path <run_dir>/final.json \
  --review-status pending_review --database-url "$PROD_DATABASE_URL" --execute
```

### 7. Report

Funnel summary (generated → after dedup → after fact-check → after guards → imported), top drop reasons, run dir path. Remind: everything landed as `pending_review` — nothing enters the game before founder review.

## Important

- This is a **temporary, occasional** mode: it consumes the Claude subscription quota shared with development work. Not for bulk production runs.
- Do not run concurrently with another heavy Claude session on the same plan.
- Never change env vars, Claude Code settings, or prod config as part of a run — if something is missing, stop and tell the user exactly what to set up.
