# Issue 112: Error-path dedup — one quota/429 handler + generic NetworkService request

**Triage:** refactor · needs-triage
**Reversibility:** a
**Status:** Created by /prepare-issue 2026-07-20 from the iOS architecture review 2026-07-18 — Top 10 item 9. Prep pipeline running on branch `arch-review-ios`.
**Created:** 2026-07-20

**Source:** [iOS architecture review 2026-07-18](../research/ios-architecture-review-2026-07-18.md) — Top 10 item 9 + dimension 7. Link, don't restate.

## Why (stub — Phase 2 expands)

The quota/429 + resync/paywall logic exists in **three diverged copies** (user-facing copy already drifted): `startNewQuiz`'s inline catch (`QuizViewModel.swift:549/646`), `submitVoiceAnswer`'s quota branch (`QuizViewModel+Recording.swift:344/410`), and the canonical `handleError`. NetworkService's 12 endpoint methods hand-duplicate the authorized-request → guard → error-decode pipeline (12 copies of the HTTPURLResponse guard; the 429/quota branch copied verbatim at `NetworkService.swift:225/395/458`).

Fix direction per review: route every quota/429 catch through the existing `handleError` path; extract one generic `performRequest<T: Decodable>` (auth, breadcrumb, 429 parsing, decode) in NetworkService.

**Sequencing note:** deduping first shrinks the surface for #113 — Decompose the QuizViewModel god object; run this before it.

## Prep progress

> *Maintained by `/prepare-issue` — durable record of where prep is; safe to resume from a fresh session.*

| Phase | State | Latest gate verdict |
|-------|-------|---------------------|
| 1 · Research          | ⬜ pending | — |
| 2 · Plan              | ⬜ pending | — |
| 3 · Plan review       | ⬜ pending | ready-check — · design-soundness — |
| 4 · Impl-plan         | ⬜ pending | — |
| 5 · Impl-plan review  | ⬜ pending | ready-check — · design-soundness — |
| 6 · Split             | ⬜ pending | — |

**Last updated:** 2026-07-20 11:19 · **Next:** Phase 1 · **Gate attempts:** P3 0/3 · P5 0/3
