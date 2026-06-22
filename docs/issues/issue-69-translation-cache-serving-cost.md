# Issue #69 — Cost: translation cache + corpus pre-translation (3.5× SK serving cost)

**Triage:** enhancement · ready-for-agent

**Created:** 2026-06-21 · **Founder:** Michal · **Source:** #64 full-project review (rank 19 — verified first-hand)

**Severity:** medium — the founder's device always runs Slovak, so every test session pays the penalty.

## Problem

Translation makes fresh `gpt-4o-mini` calls per question with **no caching**, and the same path is
hit 2–3× per question cycle. Issue #49 measured SK sessions at `$0.00231` vs `$0.000657` for EN —
a ~3.5× multiplier — entirely from translation. The 580-question corpus is finite, so questions
recur across sessions; a cache (or one-time offline pre-translation) removes almost all of it.

## Evidence (verified first-hand 2026-06-21)

- `apps/quiz-agent/app/translation/translator.py` — no `@lru_cache`, no instance cache.
- `apps/quiz-agent/app/quiz/flow.py:146,178,280-283` — translate calls per question cycle (feedback ×2 + next-question text ×1).
- Cross-ref: `docs/artifacts/daily-limit-cost-model.html` / #49 ($0.00231 SK vs $0.000657 EN).
- (The `fly_client_ip` rate-limiter default fix that the review bundled here is owned by **#65** to avoid a split fix — not duplicated.)

## Recommendation

- Add an instance LRU cache to `TranslationService` keyed on `(text, target_language)`, capped
  ~2000 entries (≈ 580 questions × ~3 text variants).
- Bigger win: **pre-translate the whole approved corpus to SK/CS offline once** (~$0.07 total) and
  store as a JSON sidecar or a translated pgvector column → zero runtime translation cost + no
  translation latency on the hot path. (Strategic opportunity from #64.)

## Acceptance

- [ ] Translating the same `(text, language)` twice calls the LLM only once (second is a cache hit)
- [ ] The cache persists across a session (instance-level, not per-request)
- [ ] Backend test suite stays green (no regression from the cache)
- [ ] (Optional, recommended) a one-shot script pre-translates the approved corpus to SK and the serving path prefers the cached translation
