# Issue 32: On-demand question generation service — review + strategy

**Triage:** enhancement · done (umbrella role)
**Status:** Direction approved 2026-05-07 — 7 open questions resolved (§4 Decisions). Phase 1 decomposed into [#33](issue-33-quiz-pack-api-phase-1.md), which added three revisions (C1/C2/C3) that **supersede portions of §4** — see "Revisions superseding §4" subsection. **Review pass 2026-05-11** corrected 4 critical errors (cost envelope, refund flow, Phase 4 sizing, dual-store lifecycle) — fixes applied in §2.3, §2.4, §2.6, §3, §5. Phases 2–6 still pending decomposition (decompose only after the predecessor phase ships, since each feeds the next's data model).
**Created:** 2026-05-07
**Surfaced by:** User wants to host the gen → verify → score → import pipeline as a standalone backend so that iOS users can purchase a question pack from a free-form prompt (e.g. "techno music", "famous movie quotes", "Gen-Z slang"). This document is a **review of the current pipeline** and a **strategy/roadmap** — not yet a build plan.

---

## TL;DR

Today the question pipeline is a **bench-grade research kit**: powerful prompts, multiple sourcing channels, multi-model critique, and FactVerifier are all in place — but the orchestration layer is split across Claude Code skills, FastAPI endpoints, ad-hoc scripts, and JSON-on-disk queues. It is not addressable by a phone, has no jobs/orders concept, and the `Question` model has nowhere to put `requested_by_user`, `order_id`, `pack_id`, or `prompt`.

To go on-demand we need three concrete moves:

1. **Promote `question-generator` to a first-class deployed service** alongside `quiz-agent` (single FastAPI app on Fly.io, Postgres replacing the SQLite + JSON-file mess, Redis for jobs).
2. **Introduce three new domain entities** — `GenerationOrder`, `GenerationJob`, `QuestionPack` — and a thin `iOS → /orders → job → pack` flow gated by StoreKit receipt validation.
3. **Lock the generation pipeline behind one canonical orchestrator** (`PackGenerator`) that wraps the existing stages: source → generate → critique → verify → score → dedup → persist. Skills, scripts, and the admin web UI all become thin clients of that orchestrator instead of reimplementing it.

Everything else (prompts, FactVerifier, scoring rubric, ChromaDB dedup) is a **keep** — those are the parts that work.

---

## 1. Review: what we have today

### 1.1 Pipeline stages (as they exist)

| Stage | Where it lives | Entrypoints | Notes |
|---|---|---|---|
| **Source** | `apps/question-generator/app/sourcing/` | `FactSourcer` (Wikipedia EN/SK/CS, OpenTriviaDB, Tavily, RSS news, CZ/SK Wiki) | Used only via `/generate-questions --fact-first`. Solid foundation. |
| **Generate** | `app/generation/` | `QuestionGenerator` (basic), `AdvancedQuestionGenerator` (best-of-N + CoT critique), `scripts/generate_questions_claude.py` (Anthropic direct), `/generate-questions` skill | Three parallel implementations of the same idea. |
| **Critique** | `AdvancedQuestionGenerator._critique_question` | LLM judge with 6-dim rubric (`question_critique_v2.md`) | Calibrated anchors (5%/25%/45%/20%/5% distribution). |
| **Verify** | `app/verification/fact_verifier.py` | `FactVerifier` (Tavily search → Gemini Flash analysis), `/verify-questions` skill | Two-stage cost-aware design. Good. |
| **Score** | `app/scoring/multi_model_scorer.py` | `MultiModelScorer` (gpt-4.1-mini + claude-sonnet, A/B), `/score-questions` skill | 5 driving-quiz dimensions. Stored to `model_scores` SQLite table. |
| **Dedup** | `quiz_shared/database/chroma_client.py` | `find_duplicates` (cosine ≥ 0.85), `_dedup_against_gold_standard` (Jaccard ≥ 0.80 vs `gold_standard.json`) | RAG-based, works. |
| **Pending → Approved** | `quiz_shared/database/pending_store.py` + `chroma_client.py` | `QuestionStorage.approve_question` | Two-store split (SQLite pending, ChromaDB approved). Recently consolidated (#22, #27). |
| **Review UI** | `apps/question-generator/app/web/` | Jinja2 web pages on port 8003 | Admin-only. |
| **Image ext.** | `scripts/generate_blind_maps.py`, `_silhouettes.py`, `_hint_images.py` | One-shot scripts | Working but isolated. |

### 1.2 What is good — keep these

- **Prompt library** (`prompts/`): v2_cot, kids, themed, v3_fact_first, critique v1+v2. The Constitutional Principles + Boring Detector + Pattern Library + calibration anchors are the asset that took the longest to build and is hardest to replicate. Don't rewrite.
- **`gold_standard.json` + `anti_patterns.json`** as a dynamic example library, sampled per request — this is the right pattern for prompt few-shot rotation.
- **FactVerifier two-stage design** (cheap Tavily heuristic → expensive Gemini analysis only when ambiguous) — cost-aware, well-shaped.
- **Best-of-N + LLM-judge critique loop** — well documented, score normalization for inflation, batch diversity warning ("too many `Which…`"), answer/explanation consistency check.
- **Calibrated rubric v2** — score anchors with worked examples is a textbook-correct way to combat LLM-as-judge inflation.
- **`PendingStore` ↔ `ChromaDB` split** with explicit promotion semantics — issue #22/#27 already cleaned this up; the model is sound.
- **Multi-source sourcing** with async-gather + dedup — good shape, just under-used.

### 1.3 What is broken / smells — fix these

| # | Problem | Why it hurts |
|---|---|---|
| F1 | **Three generators** (`QuestionGenerator`, `AdvancedQuestionGenerator`, `scripts/generate_questions_claude.py`) implement overlapping pipelines. The skill `/generate-questions` is a fourth (Claude Code-driven, never calls the API). | Drift: any prompt or rubric change has to be made in 4 places. The user-facing path will be a 5th if we add iOS. |
| F2 | **In-process service init** at module import (`generator = QuestionGenerator()`, `fact_verifier = FactVerifier()`). | Blocks any horizontal scaling, CORS+API key checks happen at request time, can't swap impls per request, no DI. |
| F3 | **No async job queue** — every endpoint is synchronous. A best-of-N pack of 30 questions takes 60–180s of LLM calls. | A phone client will time out; mobile networks drop long-lived HTTP. Today this is OK because it's an admin tool. |
| F4 | **Job state lives in JSON files** (`data/generation_queue/pending.json`, `data/generated/claude_batch_NNN.json`, `data/scored/`, `data/verification/`). | Not multi-instance safe, not durable, not queryable. Every existing skill writes to local disk. |
| F5 | **CORS `allow_origins=["*"]`, no auth, no rate limit** on the question-generator FastAPI. | If we expose this on the public internet, the OpenAI/Anthropic/Tavily bills will go to 0 the wrong way. |
| F6 | **No order/job/pack entity in the data model** — `Question.created_by` is a free-form admin string. | We can't bill, we can't refund, we can't tell user "your pack is ready". |
| F7 | **No content moderation on user input.** | When a user types "Nazi propaganda" or self-harm content as the prompt, we'll happily ingest it into the generation prompt today. |
| F8 | **`source_url` / `source_excerpt` quality is variable** — fact-first mode populates them; non-fact-first mode often has them null or LLM-hallucinated. iOS already shows a SourceCard on the result screen; broken sources hurt trust. |
| F9 | **`Dockerfile` for `question-generator` is undocumented** (only `quiz-agent` is deployed). Per `.claude/rules/backend.md` (Production Deployment Pitfalls), the existing Dockerfile drifts from `pyproject.toml`. |
| F10 | **No regression eval / dataset.** When we change a prompt, we have no automated way to detect score drift on a held-out set. |
| F11 | **Generation metadata is a free-form `Dict[str, Any]`** — `prompt_version`, `pipeline`, `reasoning`, `self_critique`, `ai_score`, `temperature`, `model` all live there. | Can't migrate, can't query, can't tell what produced a question without parsing JSON. |
| F12 | **CORS / auth / observability**: no Sentry, no Langfuse, no structured logs in `question-generator`. The main backend (`quiz-agent`) has Sentry — the generator does not. |

### 1.4 What is unused / over-built — remove or shelve

| # | Component | Recommendation |
|---|---|---|
| U1 | `QuestionGenerator` (`generator.py`, basic) — superseded by `AdvancedQuestionGenerator` since v2_cot landed. | Delete after migrating any callers; one generator only. |
| U2 | `/api/v1/export/chatgpt` endpoint + `build_for_chatgpt` — manual ChatGPT-copy-paste workflow. Nobody uses this anymore (everything is API-driven). | Delete. |
| U3 | `import_rated_questions.py`, `apply_corrections_production.py`, `apply_fixes.py`, `apply_question_corrections.py`, `update_corrected_questions.py` — five overlapping correction scripts. | Audit and consolidate into one CLI in `apps/question-generator/scripts/`. |
| U4 | `news_source.py` (BBC/Reuters RSS) — `Reuters` URL is via a 3rd-party RSS bridge, brittle. Also questions on news facts go stale fast. | Either invest properly (paid news API + freshness tagging) or delete. Not on the critical path for paid packs. |
| U5 | `czech_slovak_source.py` — thin wrapper over `WikipediaSource(languages=["sk","cs"])`. Only adds a cultural tag. | Inline it into `WikipediaSource` config, drop the file. |
| U6 | Image generation scripts (`generate_blind_maps.py`, `_silhouettes.py`, `_hint_images.py`) — separate one-off pipelines, no integration with the main flow. | Out of scope for paid packs MVP. Park them. |
| U7 | The Jinja2 `web/` review UI — useful for admin but not for end users. | Keep for admin, but stop coupling it to the same FastAPI app. Move it to `/admin` behind basic auth. |

### 1.5 Data-model audit (`Question`, `Fact`, `FactBatch`)

`Question` (35+ fields) is **rich enough for content** but **missing for commerce**:

**Has** — `id`, `question`, `type`, `correct_answer`, `alternative_answers`, `topic`, `category`, `difficulty`, `tags`, `language_dependent`, `age_appropriate`, `source`, `source_url`, `source_excerpt`, `usage_count`, `user_ratings`, `review_status`, `quality_ratings`, `generation_metadata`, `media_url`, `explanation`, `embedding`, `expires_at`, `freshness_tag`.

**Missing for on-demand:**

- `pack_id` — which pack this question belongs to (NULL = global / curated)
- `requested_by_user_id` — for "my library" filtering and refunds
- `prompt_seed` — the original user-prompt (so we can regenerate, audit, or refuse near-duplicate prompts)
- `language` field at top level (currently only in `Fact.language` and prompts know about it implicitly)
- `cost_cents` — accounting per question (sum across LLM calls)
- `embedding_model` / `embedding_dim` — currently `embedding` is a raw list; we have no field saying which model produced it. We'll need this if we ever swap from `text-embedding-3-small`.

**Generation metadata (`Dict[str, Any]`) — should be a typed sub-model:**
```
GenerationProvenance:
  model, provider, prompt_version, pipeline ("fact_first"|"v2_cot"|"themed"|"kids"),
  generation_temperature, critique_model, critique_score (calibrated 0–10),
  reasoning_pattern, fact_ids: list[str], created_at
```
This unlocks queries like "show me all questions generated by claude-opus-4-7 with fact-first pipeline that scored < 8 — they're regen candidates."

**New entities to add:**

```
GenerationOrder:
  id, user_id, transaction_id (Apple), product_id, prompt, category, theme,
  target_count, status (pending|in_progress|delivered|failed|refunded),
  job_id, pack_id, created_at, delivered_at, refund_eligible

GenerationJob:
  id, order_id, status (queued|sourcing|generating|critiquing|verifying|scoring|persisting|done|failed),
  progress (0–100), step_log (list of {step, started_at, finished_at, info}),
  total_cost_cents, retry_count, error

QuestionPack:
  id, order_id, user_id, name, description, prompt, category, theme,
  question_ids (FK to Question.pack_id), generated_at, language
```

### 1.6 Pipeline coverage matrix (which entrypoint does what)

|   | source | generate | critique | verify | score | dedup | persist | progress |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `/generate-questions` skill | ✓ (opt) | ✓ | ✓ self | ✗ (warns) | ✗ | ✗ | local file | ✗ |
| `POST /api/v1/generate` | ✗ | ✓ | ✗ | ✗ | ✗ | ✓ on approve | pending+chroma | ✗ |
| `POST /api/v1/generate/advanced` | ✗ | ✓ | ✓ | ✗ | ✗ | ✓ on approve | pending+chroma | ✗ |
| `scripts/generate_questions_claude.py` | ✓ (opt) | ✓ | ✓ | ✗ (warns) | ✗ | ✓ | optional chroma | stdout |
| `scripts/generation_worker.py` | ✗ | ✓ | ✓ | ✗ | ✗ | ✓ bulk | chroma | stdout |
| `/verify-questions` skill | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ | report file | ✗ |
| `/score-questions` skill | ✗ | ✗ | ✗ | ✗ | ✓ | ✗ | scored file | ✗ |

No path runs **all** stages end-to-end. The skill chain (`/generate-questions` → `/verify-questions` → `/score-questions`) is the closest, but each step writes JSON files to disk that the next must re-read.

---

## 2. Strategy: hosted on-demand generation service

### 2.1 Target architecture

```
┌──────────────────┐      POST /orders                  ┌──────────────────────────┐
│  iOS app (Hangs) │ ─────(StoreKit JWS, prompt)──────▶ │ quiz-pack-api (Fly.io)   │
│                  │ ◀───── 202 + order_id ──────────── │  FastAPI                 │
│                  │      GET /orders/{id}/stream (SSE) │  Postgres + pgvector     │
└──────────────────┘ ◀──── progress events ──────────── │  Redis (Upstash)         │
        │                                                └──────┬───────────────────┘
        │                                                       │
        │                                              enqueue  │
        │                                                       ▼
        │                                                ┌─────────────────┐
        │                                                │  ARQ worker     │
        │                                                │  - PackGenerator│
        │                                                │  - source       │
        │                                                │  - gen          │
        │                                                │  - critique     │
        │                                                │  - verify       │
        │                                                │  - score        │
        │                                                │  - dedup        │
        │                                                │  - persist      │
        │                                                └─────────────────┘
        │                                                       │
        ▼                                                       ▼
   Library tab                                          OpenAI / Anthropic
   (GET /library/packs)                                 Tavily / Gemini
```

### 2.2 Service decision: extend or fork?

**Recommendation: extend `apps/question-generator/` into `apps/quiz-pack-api/` (rename + harden) and deploy it as a second Fly app.**

- Don't bundle into `quiz-agent`: different scaling profile (LLM-bound, long-running) vs voice-quiz session (latency-bound, short-running).
- Don't fork into a third app: 80% of the code is already there, just needs the order/job/pack layer on top.
- Fly app naming: `quiz-pack-api.fly.dev`. Keep `quiz-agent-api.fly.dev` for the voice quiz.

### 2.3 Domain entities and the canonical flow

```
[iOS user buys pack]
    │
    ├─▶ StoreKit purchase → JWS in client
    │
    ▼
POST /v1/orders                                     (idempotent on transaction_id)
    body: { transaction_id, prompt, category, theme?, target_count, language }
    ↓
1) verify JWS offline (ECDSA P-256 against bundled Apple root cert chain — no network call to App Store Server API)
2) moderate prompt (OpenAI Moderation API)            ◀── reject 422 if flagged
3) insert orders row, enqueue job, return 202 + order_id

Worker picks up job:
    sourcing  → FactSourcer (if fact-first enabled for category)
    generating → AdvancedQuestionGenerator (best-of-N, CoT, structured-output)
    critiquing → in-line LLM judge (calibrated v2 rubric)
    verifying  → FactVerifier (Tavily + Gemini, batch)
    scoring    → MultiModelScorer (multi-model, A/B)
    dedup      → ChromaDB cosine + Jaccard vs gold_standard
    persisting → write QuestionPack + Question rows (pack_id set)
    publish    → orders.status=delivered, job.progress=100

Client streams progress:
GET /v1/orders/{order_id}/stream  (SSE, heartbeat 15s, Last-Event-ID resume — #33 task 1.11)
    event: progress  data: { step: "verifying", progress: 60 }
    event: done      data: { pack_id }
    event: failed    data: { error, retry_available: bool }
    # reconnect: client replays from Last-Event-ID against job.step_log (durable),
    # then forwards live Redis pubsub. Fallback: 1Hz polling GET /v1/orders/{id}.

Client fetches library:
GET /v1/library/packs              → list of QuestionPack summaries
GET /v1/library/packs/{pack_id}    → full pack with questions
```

### 2.4 Storage migration

| Today | Target |
|---|---|
| SQLite `pending.db` (PendingStore) | Postgres `pending_questions` table |
| SQLite `ratings.db` (ratings + model_scores) | Postgres `ratings`, `model_scores` |
| SQLite + JSON file `generation_queue/pending.json` | Postgres `orders`, `jobs` + Redis ARQ queue |
| ChromaDB on Fly volume (single-attach) | **pgvector on Postgres** (per #33 C1; ChromaDB's volume cannot be shared between `web` and `worker` process groups). ChromaDB volume drop ships in Phase 6; voice quiz keeps reading from ChromaDB through Phase 1 — read-path cutover later. |
| `data/generated/*.json`, `data/scored/*.json`, `data/verification/*.json` | Postgres `generation_jobs.step_log` JSONB column + S3/Tigris for full artifact dumps if needed |

Postgres because: relational orders, ACID for billing, JSONB for `generation_metadata`, easy filtering for "show me all questions in pack X with score > 8". Fly Postgres is fine.

#### 2.4.1 Dual-store lifecycle (ChromaDB → pgvector)

C1 says ChromaDB drop ships in Phase 6 and voice quiz reads from ChromaDB through Phase 1. That leaves a multi-phase window where two vector stores coexist. The plan resolves it as follows (decided 2026-05-11 review pass):

- **Phase 1 (#33 task 1.7):** one-shot copy ~1000 global questions Chroma → pgvector with `pack_id=NULL`. ChromaDB stays canonical for voice-quiz reads.
- **Phase 2:** `PackGenerator` writes **only** to Postgres + pgvector (no dual-write). At the end of Phase 2 the voice quiz read-path is **cut over to pgvector** as a Phase 2 sub-task (one repo, one PR — voice quiz is `apps/quiz-agent`, pgvector connection is reusable). ChromaDB volume becomes read-only.
- **Phase 6:** decommission ChromaDB volume + remove ChromaDB client from `quiz-agent`. By then it has been read-only for 3 phases with zero writes — risk is minimal.

**Not chosen:** dual-write through Phase 5. Reason: every new endpoint would have to keep two clients in sync, and any drift becomes an invisible data-quality bug. One-shot copy + cutover is simpler and bounded.

### 2.5 Pipeline consolidation

Wrap the existing stages behind a single orchestrator class:

```python
class PackGenerator:
    def __init__(self, sourcer, generator, critic, verifier, scorer, dedup, store, progress_sink):
        ...

    async def run(self, order: GenerationOrder) -> QuestionPack:
        # publishes progress events to Redis pubsub for SSE
        # writes step_log entries to job row
        # short-circuits on moderation/dedup violations
```

All of these become **thin clients** of `PackGenerator`:
- `POST /v1/orders` (iOS user-facing)
- `/generate-questions` skill (admin shell)
- `scripts/generate_pack.py` (CLI replacement for `generate_questions_claude.py` + `generation_worker.py`)
- Web admin "Generate batch" form

Skills don't reimplement the pipeline anymore — they just call the same orchestrator with different auth context.

### 2.6 Cost & safety controls

| Control | Mechanism |
|---|---|
| Input moderation | OpenAI Moderation API on `order.prompt` before enqueue (free, ~50ms) |
| Topic safety | Server-side whitelist of allowed top-level topics; user prompt narrows but cannot override (e.g. "techno music" ✓, "weapons of war" ✗) |
| Output moderation | Re-moderate generated questions before write to DB |
| Cost cap per order | `target_count ≤ 50` (D4). **Per-tier cap revised 2026-05-11 review.** Call count = `target_count × (1 + N) [gen+critique] + target_count [verify] + target_count × 2 [scoring A/B]`. With Haiku/4o-mini for gen+critique, Gemini Flash for verify, Haiku+4o-mini for scoring: **pack_10** (N=3) ≈ 70 calls ≈ $0.30 cap · **pack_20** (N=3) ≈ 140 calls ≈ $0.60 · **pack_30** (N=3) ≈ 210 calls ≈ $0.90 · **pack_50** (N=5) ≈ 450 calls ≈ $2.50. Detailed per-model cost table deferred to Phase 3 issue. **Mid-flight overrun policy:** mark `status=failed` after current question completes (no partial pack delivered); client surfaces in-app retry (see open-gap M-2) before any refund affordance. |
| Idempotency | `transaction_id` is unique; reposts return existing order |
| Cache | Anthropic prompt caching for system prompt + few-shot block (5-min TTL, 0.1× input cost) |
| Cheap critique | gpt-4o-mini / claude-haiku for critique loop; reserve gpt-4o / claude-sonnet for final fact verification |
| Batch | Anthropic Messages Batches API for offline scoring backfill (50% discount) |
| Refund flow | **Rewritten 2026-05-11 review.** Refunds are **user-initiated through Apple**, not server-issued — App Store Server API has no "issue refund" endpoint. Correct flow: iOS calls `Transaction.beginRefundRequest(in:)` (StoreKit 2, iOS 15+) which opens Apple's refund sheet. Apple processes the request and emits an **App Store Server Notifications V2 `REFUND` / `REFUND_DECLINED`** webhook to our server (Phase 4b — per C2 + the Phase 4 split below). Server then marks order `refunded` and revokes pack access. For `job.status=failed` + `retry_count ≥ 3`: surface in-app retry first; if user still wants refund, expose `beginRefundRequest` affordance — never auto-trigger. **Phase 1 → 4b window risk:** refunded transactions retain pack access until ASSN V2 ships (see open gap "Refund detection gap"). |

### 2.7 Observability

- **Langfuse** (self-hosted on Fly or cloud) — trace every LLM call with token cost, attach critique/verify scores. Closes the prompt-iteration feedback loop.
- **Sentry** — already wired for `quiz-agent`; add the pack API to the same project (`carquiz` slug per memory).
- **Postgres `generation_jobs.step_log`** — durable per-job timeline for debugging.

### 2.8 Quality gates / regression

- **DeepEval `G-Eval`** in CI: run prompt + 50-question sample dataset, compute factuality + answer-uniqueness + ambiguity scores; fail CI if any drops > 10% from baseline.
- **Promote `gold_standard.json`** into a versioned dataset (`data/eval/gold_v3.json`) used as the regression set.
- **TriviaQA / MMLU-Pro spot check** — periodically (weekly cron) ask the generation model to *answer* 100 TriviaQA questions; if accuracy drops below threshold, alert (signals model drift / API change).

---

## 3. Roadmap (proposed phases)

Each phase is a separate issue once approved. Sizing is rough.

### Phase 0 — Foundations (folded into Phase 1 / #33)
- ~~Decide: keep ChromaDB or move to pgvector?~~ Decided in #33 C1: **pgvector**. Reason: Fly volumes are single-attach and block sharing between `web` and `worker` process groups.
- Provision Fly Postgres (with pgvector) + Upstash Redis — #33 task 1.1
- Rename `apps/question-generator/` → `apps/quiz-pack-api/` — #33 task 1.2
- `Dockerfile` parity with `pyproject.toml` (per `.claude/rules/backend.md` Production Deployment Pitfalls) — #33 task 1.2
- Cleanup of duplicate generators (F1, U1, U2, U5) deferred to Phase 2 (was originally bundled here; #33 keeps Phase 1 additive only)

### Phase 1 — Domain entities + ordered flow (3–5 days)
- Add `GenerationOrder`, `GenerationJob`, `QuestionPack` Pydantic + SQLAlchemy models
- `Question.pack_id`, `prompt_seed`, `language`, typed `GenerationProvenance` sub-model (F11)
- Postgres migration from SQLite `pending.db`
- `POST /v1/orders` (StoreKit JWS verify) + `GET /v1/orders/{id}` + `GET /v1/orders/{id}/stream` (SSE)
- ARQ worker scaffold + Fly process group

### Phase 2 — Pipeline consolidation (3–5 days)
**Status:** decomposed into [#36](issue-36-quiz-pack-api-phase-2.md); shipped 2026-05-28.
- Build `PackGenerator` orchestrator (F1)
- Migrate `AdvancedQuestionGenerator`, `FactVerifier`, `MultiModelScorer` into stages with progress events
- Delete duplicate generator paths (basic generator, manual ChatGPT export, fact-first vs non-fact-first split)
- Skills + scripts rewritten as thin clients of the orchestrator
- **Voice-quiz read-path cutover to pgvector** (per §2.4.1 Dual-store lifecycle) — `apps/quiz-agent` swaps ChromaDB client for pgvector reads; ChromaDB volume becomes read-only until Phase 6 retirement

### Phase 3 — Safety + cost (2–3 days)
- OpenAI Moderation on input + output
- Topic whitelist enforcement
- Per-order cost cap + accounting (`total_cost_cents`)
- Anthropic prompt caching wired into generation prompt
- Rate limit + auth (FastAPI dependency, Apple JWS as auth on user routes, admin token on admin routes) (F5)

### Phase 4a — iOS integration + non-consumable packs (5–8 days)
**Split from original "Phase 4" 2026-05-11 review** — subscription scope moved to 4b for realism.
- iOS StoreKit non-consumable purchase flow (D4 tiers `pack_10/20/30/50`); server-side JWS verify already shipped in #33 task 1.8
- Order screen + SSE progress UI (mandatory: pack_50 generation runs ~8–12 min real time)
- Library tab (uses existing `Question` rendering — packs are just filtered queries)
- `Transaction.beginRefundRequest(in:)` integration for the failed-job affordance (replaces the original "Refund-on-failure flow")
- D3 in-flow language confirmation modal (copy + UX position)

### Phase 4b — Subscription + ASSN V2 + entitlement state machine (10–15 days)
**New phase 2026-05-11 review** — subscription was lumped into 4 at 5–8 days, which underestimated the work by ~3×. Splitting it out makes the cost visible.
- StoreKit auto-renewable subscription (per D1, deferred from Phase 1 by #33 C2) — product setup, purchase + restore flow
- **App Store Server Notifications V2 webhook** — idempotent ACK, retry-safe, signature verification on incoming JWS
- **Entitlement state machine**: `active` / `expired` / `in_grace` / `in_billing_retry` / `lapsed` / `refunded` / `revoked`; with transitions driven by ASSN events: `SUBSCRIBED`, `DID_RENEW`, `EXPIRED`, `GRACE_PERIOD_EXPIRED`, `REFUND`, `REFUND_DECLINED`, `REVOKE` (family-sharing revocation)
- **Refund-driven entitlement revocation:** on `REFUND` event, mark order `refunded`, revoke pack access (closes Phase 1→4b refund-detection gap)
- **Server-side stable `user_id`** issued from first-seen JWS `original_transaction_id` → durable identity; **migration** of existing Phase 1 orders/packs (which use raw `original_transaction_id` as `user_id`) to the new stable id (see open gap M-4)
- Promotional offers + upgrade/downgrade/crossgrade flow (basic — full SKUs scoping is a Phase 4b sub-decision)

### Phase 5 — Observability + evals (2–3 days)
- Langfuse traces wired in PackGenerator
- DeepEval CI gate with `gold_v3.json` dataset
- TriviaQA spot-check cron
- Sentry on the pack API

### Phase 6 — Cleanup (1–2 days)
- **Decommission ChromaDB volume** (per §2.4.1 — voice quiz read-path was cut over to pgvector in Phase 2, so ChromaDB has been read-only since then)
- Remove ChromaDB client from `quiz-agent`; retire memory note `project_prod_chroma_mount`
- Delete F4 JSON-on-disk artifacts (migrated to Postgres step_log)
- Delete U2/U3/U4/U5/U6 components
- Move admin web UI behind `/admin` + basic auth (U7)

**Total rough estimate: 25–40 working days for a complete v1** (revised 2026-05-11 from initial 15–25 — Phase 4 split into 4a/4b after Phase 4b subscription/ASSN/entitlement work was reality-checked at 10–15 days alone).

---

## 4. Decisions (locked 2026-05-07)

The seven open questions are answered. These are load-bearing for everything downstream — Phase issues should reference this section instead of re-deriving.

| # | Decision | Implication |
|---|---|---|
| D1 | **Hybrid: subscription + à la carte** — base subscription delivers N packs/month, user can also buy individual non-consumable packs on top. | Two StoreKit product families: auto-renewable subscription + non-consumable packs. `entitlement_state` on user (active/expired/grace/lapsed) + per-pack ownership. Library shows both sources. Higher StoreKit complexity; phase 4 work. |
| D2 | **Free-form prompt + OpenAI Moderation API only.** No topic whitelist. | Accept any prompt, run OpenAI Moderation pre-enqueue + on generated questions. Hard reject on flagged categories. Long-tail risk (politics, propaganda) accepted at MVP — observe and iterate. No server-side topic classifier in v1. **2026-05-11 review note:** OpenAI Moderation has weaker non-English coverage; SK/CS/HU prompts (primary user language is Slovak per `user_language` memory) may slip through. Phase 3 mitigation: use `omni-moderation-latest` (multilingual) and/or translate→EN before moderation, with an LLM-judge as belt-and-braces. |
| D3 | **Generate in the user's currently selected app language**, with an in-flow confirmation modal ("Generate questions in {language}?"). | iOS sends `language` (BCP-47) on `POST /v1/orders`. Confirmation modal before purchase. `Question.language` set on every generated question. **Cross-language reuse:** questions generated in language A are still searchable/usable in language B for `language_dependent=false` content (LLM-side translation/aliases at consumption time, not generation time). Not all questions cross over — language-dependent ones stay in their generation language. |
| D4 | **Four pack tiers: 10 / 20 / 30 / 50** with premium tier 50 using best-of-N=5 (vs N=3 for smaller). | StoreKit non-consumables: `pack_10`, `pack_20`, `pack_30`, `pack_50`. Cost cap scales per tier. `target_count` validated server-side against tier-from-product. Generation time for 50-pack ~5+ min — SSE progress UI is mandatory. |
| D5 | **Yes — embedding-based prompt cache** (cosine ≥ 0.92 against existing pack `prompt_seed` embeddings, age < 7 days). | On `POST /v1/orders`: embed prompt, query `question_packs.prompt_embedding` (pgvector or stored vector). On hit, clone pack into requesting user's library at $0 LLM cost, mark as cache-hit in order metadata. Misses go through full generation. |
| D6 | **Single Fly app, two process groups** (`web` + `worker`). | One Dockerfile, one deploy lifecycle, shared secrets. **No Fly volumes — both processes stateless per C1.** `fly.toml` declares both groups. Scaled independently via `fly scale count`. |
| D7 | **Existing curated content stays as `pack_id=NULL` (global library).** | Existing ~1000 questions migrate from ChromaDB → Postgres+pgvector (per #33 task 1.7) with `pack_id=NULL` preserved. Free-tier users + paid-tier session play both pull from `pack_id=NULL` for semantic search. Paid packs are additive: `pack_id != NULL` AND owned by user. Future curation into showcase packs is deferred. |

### Revisions superseding §4 (locked 2026-05-07 in #33)

Three revisions emerged from Phase 1 decomposition. They supersede the matching cells above; **#33 is the source of truth on any conflict**.

- **C1 (storage, supersedes the ChromaDB premise behind D6/D7):** **pgvector replaces ChromaDB** for question + pack-prompt embeddings. Reason: Fly volumes are single-attach, so ChromaDB's volume cannot be shared between the `web` and `worker` process groups. pgvector also unblocks D5 vector lookup with one DB system. ChromaDB volume drop + voice-quiz read-path cutover deferred to Phase 6; voice quiz keeps reading from ChromaDB through Phase 1.
- **C2 (D1 split):** **Phase 1 covers non-consumable packs only.** Subscription StoreKit flow + ASSN V2 webhook + entitlement state machine deferred to Phase 4b (split from Phase 4 in 2026-05-11 review). `transaction_id` idempotency in Phase 1 = per-purchase only.
- **C3 (D5 revision):** **Cache caches the fact pool, not the question set.** When prompt cosine ≥ 0.92 hits an existing pack, `FactSourcer` reuses cached `fact_ids` but generation runs fresh with reduced `N=2`. Two users with similar prompts get *different* question sets at reduced LLM cost. **Savings per tier (2026-05-11 review refinement):** verify/score are per-question and independent of N, so cache hits save only on generation+critique. Approximate savings: pack_10 ~35 %, pack_20 ~35 %, pack_30 ~35 %, pack_50 (N=5→N=2) ~50 %. Implementation deferred to Phase 3.

### What stays open (deliberately deferred to later phases)

- **Subscription tier sizing** (how many packs/month? included in tiers? tier names?) — Phase 4b product call, not blocking Phase 1 data model.
- **pgvector vs storing embeddings as JSONB array** for prompt cache lookup — Phase 1 detail; pick when migration is written.
- **Refund automation vs human-in-loop** for failed jobs — Phase 3 safety detail.
- **Language confirmation UX copy + position in flow** — Phase 4a iOS work (non-consumable purchase flow owns the modal).

---

## 5. Handoff

### Where we are
- **Strategy + review of current pipeline:** done (§1–§3 above).
- **7 open questions:** resolved 2026-05-07 (§4 Decisions); three revisions (C1/C2/C3) added in #33 — see "Revisions superseding §4" callout above.
- **Phase 1 decomposition:** done — see [issue-33-quiz-pack-api-phase-1.md](issue-33-quiz-pack-api-phase-1.md). Triage `enhancement · ready-for-agent`.
- **Phases 2–6:** **not yet decomposed.** Each phase's atomic-task list depends on the predecessor's actual implementation; freezing them now would bake in assumptions that will shift.

### Resume
1. **Read #33 first** before any code change in this area. Its C1/C2/C3 revisions supersede portions of §4 (see the "Revisions superseding §4" callout).
2. Execute #33 atomic tasks 1.1 through 1.12.
3. Once #33 is `done`: decompose Phase 2 into `docs/issues/issue-36-quiz-pack-api-phase-2.md` (`PackGenerator` orchestrator + delete duplicate generators per F1/U1/U2 + voice-quiz pgvector cutover per §2.4.1). Reference §3 Phase 2 above and #33's out-of-scope traceability table. **Note (updated 2026-05-28):** #35 was claimed by parallel-backlog-burndown on 2026-05-15, so Phase 2 landed at #36 (next free) and shipped 2026-05-28. Downstream phases shift one number: Phase 3 → #37, **Phase 4a → #38, Phase 4b → #39**, Phase 5 → #40, Phase 6 → #41. Issue numbers are forecast only — anything autonomous-claimed before decomposition shifts the count again.

### Do NOT do
- **Do not pre-decompose Phases 3–6.** Their atomic tasks depend on each predecessor's actual implementation.
- **Do not start subscription work in Phase 1 or Phase 4a** (per C2 + 2026-05-11 review split). Subscription + ASSN V2 + entitlement state machine are **Phase 4b** exclusively.
- **Do not assume App Store Server API can issue refunds.** It cannot. Refunds are user-initiated via `Transaction.beginRefundRequest(in:)`; we detect them via ASSN V2 (Phase 4b). See §2.6 refund row.
- **Do not dual-write to ChromaDB and pgvector.** Per §2.4.1: Phase 1 is one-shot copy; Phase 2 cuts voice-quiz read-path to pgvector; Phase 6 retires ChromaDB volume.
- **Do not change `Question` model or any prod infra** outside the phase issue that owns the change.

### Decisions cheat-sheet (for quick recall)
- D1 Pricing: hybrid (subscription + à la carte). **C2 split: Phase 1 = non-consumable only; non-consumable iOS flow = Phase 4a; subscription + ASSN V2 + entitlement state machine = Phase 4b (2026-05-11 review split).**
- D2 Prompt: free-form + OpenAI Moderation only (no whitelist)
- D3 Language: per-user-locale generation, in-flow confirmation modal, cross-lingual reuse where `language_dependent=false` (consumption-time mechanism not yet phased — open gap)
- D4 Pack tiers: 10 / 20 / 30 / 50 (premium 50 uses best-of-N=5)
- D5 Cache: prompt-embedding cosine ≥ 0.92, age < 7 days. **C3 revision: cache the fact pool, not the question set; users get fresh questions at ~50% LLM cost.**
- D6 Worker: single Fly app, two process groups (`web` + `worker`). **C1 follow-on: storage is Postgres+pgvector + Redis only; no Fly volumes (both processes stateless).**
- D7 Existing curated content: stays `pack_id=NULL` global library. **C1: ChromaDB → Postgres+pgvector migration in #33 task 1.7; voice quiz keeps reading from ChromaDB through Phase 1.**

### Open substantive gaps (not yet phased)

Existing (pre-2026-05-11):
- **`User` entity / `user_id` source.** Phase 1 stores `user_id` on orders/jobs/packs but #32 never defines its origin. Phase 4b introduces a server-side stable token from first-seen JWS — until then, treat `user_id` as `original_transaction_id` from the JWS payload (Phase 1 expedient, not a long-term identity).
- **D3 cross-lingual reuse mechanism.** Consumption-time translation/aliases for `language_dependent=false` questions has no phase home. **Candidate: Phase 2** (it's a query-side concern of the orchestrator/retrieval seam, not the generation pipeline). Decide when decomposing Phase 2 — otherwise accept as deferred indefinitely.
- **D2 long-tail moderation drift.** Free-form prompts + OpenAI Moderation only — no observability hook defined to trigger the "observe and iterate" loop. **Candidate: Phase 5** (Langfuse trace tag `moderation.flagged_category` + a dashboard query; cheap to add once Langfuse is wired).
- **F8 source quality** (variable `source_url` / `source_excerpt` outside fact-first mode). **Candidate: Phase 2** — when consolidating into `PackGenerator`, force every path through `FactSourcer` so source fields are populated from real retrieval, not LLM hallucination.

Added 2026-05-11 review pass:
- **H-1 cost-cap mid-flight behavior.** Default policy in §2.6 is "fail order, no partial delivery, surface retry first then `beginRefundRequest`". Phase 3 issue (cost cap implementation) must confirm or revise — alternatives are partial-pack delivery with proportional refund, or auto-regenerate a smaller tier. **Phase home: Phase 3.**
- **H-2 multilingual moderation coverage.** Slovak/Czech prompts may bypass OpenAI Moderation. Mitigation owns Phase 3 work; see §4 D2 note. **Phase home: Phase 3.**
- **H-4 refund detection gap Phase 1 → Phase 4b.** Without ASSN V2 webhook, refunded transactions retain pack access. Accepted MVP risk — ship Phase 4b before any non-trivial paid rollout (closed beta is OK; public launch is not). **Phase home: Phase 4b.**
- **M-2 idempotency vs retry on `transaction_id`.** Phase 1 returns existing `failed` order on re-post — blocks retry. **Candidate: Phase 2** — add `POST /v1/orders/{id}/retry` endpoint or auto-requeue when existing order is `failed` and `retry_count < 3`.
- **M-3 embedding model versioning vs prompt cache.** D5/C3 cache lookup must read `embedding_model` field and skip cache rows with a mismatched model. Re-embed migration runbook required before any model swap. **Phase home: Phase 3** (cache implementation).
- **M-4 `user_id` migration burden.** Existing Phase 1 orders/packs use raw `original_transaction_id` as `user_id`. Phase 4b promotes to a stable id and must migrate. If production users exist between Phase 1 deploy and Phase 4b ship (closed beta?), plan a migration script. **Phase home: Phase 4b.**

### Useful pointers
- `Question` model — `packages/shared/quiz_shared/models/question.py`
- Storage layer (split already done in #22/#27) — `packages/shared/quiz_shared/database/{question_store,pending_store,chroma_client,sql_client}.py`
- Generator + verifier + scorer — `apps/question-generator/app/{generation,verification,scoring,sourcing}/` (renamed to `apps/quiz-pack-api/` by #33 task 1.2)
- Existing skill pipeline (today's admin path) — `/generate-questions` → `/verify-questions` → `/score-questions`
- Prod ChromaDB volume mount — context now in `.claude/rules/backend.md` (Production Deployment Pitfalls); volume itself drops in Phase 6 per C1
- Dockerfile drift — see `.claude/rules/backend.md` (Production Deployment Pitfalls); keep `pyproject.toml` and Dockerfile in sync
