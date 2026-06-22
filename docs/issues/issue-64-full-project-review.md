# Issue #64 — Full-project review: findings ledger (code · arch · security · cost · UX · competitive · process)

**Triage:** review · umbrella (spin-offs #65–#71 carry the actionable work)

**Created:** 2026-06-21 · **Founder:** Michal

## Why

Founder requested a complete review of the project: iOS + backend code/architecture/tech/services,
UX/UI/product (incl. competitive), security + cost, opportunities (esp. Claude Code leverage),
and the issues/TODO/GitHub process. Ran as a 12-reviewer multi-agent workflow with adversarial
verification of load-bearing findings (`wf_d97f64e0-0ac`, 25 agents, 126 raw findings). The
top-level model then **spot-checked every load-bearing claim first-hand** before filing — see
"Verification & corrections" below.

**Full visual report:** `docs/artifacts/full-project-review-2026-06-21.html` (scorecard, all
findings by severity, competitive matrix, strategic opportunities). This issue is the durable
ledger; the HTML is the readable artifact.

## Scorecard (per area, /10)

| Area | Score | One-line |
|---|---|---|
| iOS Architecture | 8 | Clean state machine, correct concurrency (TaskBag, AuthService actor); two small fixes |
| Process / Claude Code | 8 | Exceptional solo-dev automation (Ralph + 28 skills + verification backbone); scheduler drift |
| Backend (quiz-agent) | 7 | Solid auth + state machine; one ghost-question bug + unprotected high-cost endpoints |
| Shared / LLM gateway | 6 | Clean gateway abstraction; ChromaDB frozen-but-still-wired; SQLAlchemy 1.x import paths |
| iOS Views / UX | 6 | Polished primary flow; dual theme system mismatch during recording; **0 SK translations** |
| Security | 6 | Auth layer architecturally sound; **unauthenticated prod admin UI + AI cost endpoints** |
| Cost / Services | 6 | Serving cost minimized; ElevenLabs possibly redundant w/ iOS 26 STT; no translation cache |
| Backend (quiz-pack-api) | 5 | Good architecture; dedup inert in prod; ARQ worker would crash on deploy (path bug) |
| iOS Voice / Audio | 5 | Stabilized but 3 confirmed bugs (interruption, barge-in dead, tail buffer dropped) |
| UX / Product | 5 | Core loop solid; 60s default thinking time, no recording earcon, image questions orphaned |
| Competitive | 5 | Real voice-first + SK/CS moat; no social/retention loop; CarPlay entitlement unexplored |
| Content pipeline | 5 | **Re-scored up from 3** after correction (MCQ structured-output already shipped) |

## Top findings → spin-off issues

| # | Spin-off | Severity | Verified |
|---|---|---|---|
| #65 | Security: authenticate prod endpoints (quiz-pack-api admin UI + AI cost routes + rate-limit IP) | **critical** | first-hand ✓ |
| #66 | Bug: voice submit advances session on non-answer intent (ghost question) | high | first-hand ✓ |
| #67 | Bug: audio interruption misses streaming path; barge-in structurally dead | high | first-hand ✓ |
| #68 | UX: driving-critical defaults (60s→10s) + recording earcon + expose settings + image render | high | first-hand ✓ |
| #69 | Cost: translation cache + corpus pre-translation (3.5× SK serving cost) | medium | first-hand ✓ |
| #70 | Backend: ARQ worker Docker-path crash + dedup store wiring (content-pipeline residuals) | medium | first-hand ✓ |
| #71 | Process: restore Ralph scheduler + push held auth commits + refresh GitHub mirror | medium | confirmed |

Cross-refs to existing issues (not duplicated): **#56** owns the SK localization (0 SK strings is
its blocking work) · **#63** owns the question-quality un-park decision · **#42** owns MCQ
generation · **#60** owns the App Attest pre-prod checklist · **#48** is the pre-release gauntlet.

## Verification & corrections (top-level model, first-hand)

The reviewers were largely accurate, but two load-bearing claims were **corrected** on first-hand
read — captured here so they don't propagate:

1. **MCQ "no structured output / implement task 42.25" — REFUTED.** `with_structured_output(MCQBatchOutput, method="function_calling")` is **already shipped** (`apps/quiz-pack-api/app/generation/advanced_generator.py:634`, commit `7805002`) and wired into the live path (`_generate_mcq_sub_batches:247 → _generate_mcq_batch_structured:381/588`). The reviewer read stale `issue-42` docs and cited non-existent line numbers; the "2/13 yield" batches predate the fix. The real open item is to **validate the yield** via the #63 Track A dry-run gate — not to implement anything. See #70 + #63.
2. **`generate_pack.py:212 _NoopQuestionStore` — stale citation** (symbol not present). The substantive "dedup is inert in prod" claim still holds via a different path: `worker.py:52` wires the frozen/empty ChromaDB as the dedup store and `PgvectorQuestionStore` has no `find_duplicates`. Captured accurately in #70.
3. **`set_premium` is correctly admin-key-guarded** (`misc.py:67` checks `X-Admin-Key`) — the security reviewer did *not* overstate this. Good.

## Strategic opportunities (full list in the HTML)

- **CarPlay voice entitlement** — iOS 26.4 opened a "voice-based conversational apps" CarPlay category; Hangs's eyes-free architecture is the strongest argument for it of any researched competitor. No code change to *apply*.
- **Replace ElevenLabs with iOS 26 `SpeechTranscriber`** — already instantiated on-device in `SilenceDetectionService`; for a 100% iOS-26 audience this could remove the ElevenLabs serving cost. Gate on Slovak parity.
- **Pre-translate the 580-question corpus to SK/CS offline** (~$0.07 one-time) → removes per-session translation cost + latency (see #69).
- **Server-synced streak + shareable completion card** — trivial given the `daily_usage` Postgres table + #60 identity; the minimum viral/retention hook before launch.
- **Surface `source_url`/`source_excerpt` as a trust differentiator** — the pipeline already attaches verified citations; showing them turns a backend investment into a user-visible trust signal no AI-quiz competitor offers.
- **Slovak/Czech App Store first-mover** — no dedicated SK-language voice trivia app exists; 16M-person market that is also the founder's test base.
- **Claude Code leverage** — restore the Ralph loop (#71); extend cloud Routines to nightly corpus-quality checks that auto-file issues + scheduled SK pre-translation + Sentry crash digests; make the dormant GitHub mirror live for phone visibility.

## Acceptance

- [ ] HTML report saved to `docs/artifacts/full-project-review-2026-06-21.html`
- [ ] Spin-off issues #65–#71 created and listed in `docs/issues/INDEX.md`
- [ ] Founder has triaged #65 (critical) and decided sequencing vs. the launch path
