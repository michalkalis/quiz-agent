# Launch Decisions — 2026-06-08

Founder decisions on the 10 open questions from the comprehensive project review
(`docs/artifacts/project-review-comprehensive-2026-06-08.html`), plus one addition.
These are durable product/launch calls. Strategy: **free-first launch, monetization as fast-follow.**

| # | Question | Decision |
|---|----------|----------|
| 1 | Reveal-on-result MCQ (D4) | Highlight the correct option **in place**, hold briefly (~1s, tune for ideal), then transition to ResultView. Source/explanation shown on the result screen. → spec into **#45** (45.9). |
| 2 | Prod content sync scope | Sync **all ~308 approved** questions now. User will test the app continuously against live content. |
| 3 | MCQ in launch batch? | **Yes** — include MCQ in the first launch. |
| 4 | Free daily limit | **20/day OK for now.** Paywall is **not** in the launch (decided in a prior session) but will be needed. Open a research issue to size the limit against **backend + LLM cost**. |
| 5 | App Store market | **SK + CZ + EN** for launch. English = rest-of-world for now. In-app language is user-selectable. |
| 6 | Onboarding + dark-mode = hard req for v1? | **Yes** — consistent design across the whole app is required; these screens must be updated. **Another session is doing this now**; work must be verified — keep the task open. |
| 7 | Price + monetization model | For launch keep **only pack purchasing**. App Store Connect is **not set up yet**. Set up via API if possible. |
| 8 | `min_machines_running` | Keep **0 (free)** for now; switch to **1** once prod is live on the App Store. |
| 9 | External TestFlight testers | Founder manages this himself — not a blocker. |
| 10a | Maestro MCP (#43) | **Not needed** — close/won't-do. |
| 10b | XcodeBuildMCP scope | **Opt-in per session** (not always project-scoped). |
| 10c | mba on macOS 26 Tahoe? | **Should be** (for RenderPreview). Verify. |
| 10d | Routines (cloud) vs ssh-mba for "prompt→TestFlight" | **Not needed yet** — stay with ssh-mba. |
| 11 | Analytics | **Will be needed** — product analytics for the PRD success metrics. |

## Direct consequences for the backlog

- **Prod content sync** (top P0): import all 308 approved → prod pgvector, verify count (R15). See TODO #30. ⚠ A content-safety bug in the sync script was found and fixed (2026-06-08): it stamped *every* ChromaDB row as `approved` with no filter, which would have leaked 272 `pending_review` rows to prod. Now filters to source `review_status='approved'`.
- **MCQ in launch** (#3) requires: add `text_multichoice` to `QuestionRetriever` `allowed_types` (currently hardcoded `[text, image]` at `apps/quiz-agent/app/retrieval/question_retriever.py:212`), approve the converted MCQ questions, and finish iOS MCQ UI (#45.7–45.13).
- **Daily-limit cost research** (#4) — new issue.
- **App Store Connect listing + ASC API setup** (#5, #7) — new issue; markets SK/CZ/EN.
- **Product analytics** (#11) — new issue.
- **Already done (review was stale):** #47 Node.js 24 CI (`8a62d0d`), #61 CLAUDE.md rules (`f928db7`).
- **In another session:** onboarding/dark-mode design consistency (#6) and #45 redesign — leave for verification.
- **Won't-do:** #43 Maestro MCP.
