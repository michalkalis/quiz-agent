# Issue Index

Dashboard of all `issue-NN-*.md` files. Updated by `/triage` whenever a `**Triage:**` line changes. The active queue (what's next) lives in `docs/todo/TODO.md` — this index is the full state.

## How to read this

- **Triage** — `<category> · <state>`. Categories: `bug` | `enhancement`. States: `needs-triage` | `needs-info` | `ready-for-agent` | `ready-for-human` | `blocked-on-#NN` | `done` | `wontfix`.
- **TODO** — whether the issue currently sits in `docs/todo/TODO.md`. Empty cell = not on active queue.
- **Notes** — one-line context; detail lives in the plan file. For `done` items, the commit or date that landed it.

> Full clean-up pass **2026-07-06**: closed shipped/superseded issues, reconciled headers with the 2026-07-05 founder decisions (UI proposals approved → #86 gate; autonomous Ralph loops disabled), archived `overnight-queue.md` + `question-pipeline-remaining.md` to `docs/archive/issues/`, moved `issue-31-handoff.md` to `docs/handoffs/archive/`. Notes trimmed — history is in the plan files.

## Open

| # | Title | Triage | TODO | Notes |
|---|---|---|---|---|
| 92 | [Rename app: Hangs → Trubbo](issue-92-rename-trubbo.md) | enhancement · ready-for-agent | `[ ]` #92 | Display/brand rename only, identifiers stay (judged). 3 Opus sessions + 2 small `[HUMAN]` steps; ASC name save = availability gate, run first |
| 91 | [Auth low-severity hardening bundle](issue-91-auth-low-severity-bundle.md) | bug · ready-for-agent | `[ ]` #91 | 6 small items from 2026-07-07 auth review: nonce RNG guard, `/usage` IDOR, constant-time admin key, 500 leak, `/auth/apple` 409 recovery, row pruning. One-sweep |
| 90 | [Freemium quota TOCTOU](issue-90-quota-toctou.md) | bug · ready-for-agent | `[ ]` #90 | Concurrent starts exceed monthly cap; enforce cap atomically in `record_question`. From 2026-07-07 auth review |
| 89 | [Grace null-subject quota bypass](issue-89-grace-null-subject-quota-bypass.md) | bug · ready-for-agent | `[ ]` #89 | **Latent** (grace already OFF in prod per #65) — hardening vs re-enablement. Fix = reject 401 + null-subject session guard. Reframed 2026-07-07 |
| 88 | [Lost refresh response → silent sign-out](issue-88-refresh-lost-response-signout.md) | bug · ready-for-agent | `[ ]` #88 | HIGH. Dropped response mid-refresh → family revoked → SIWA user dropped to anon. Add immediate-successor reuse-grace (RFC 9700). From 2026-07-07 auth review |
| 87 | [Home: free-plan counter + reset countdown](issue-87-home-freeplan-counter.md) | enhancement · done | `[x]` #87 | Shipped 2026-07-07. Founder decisions: monthly reset (calendar month), 100 q/month, paid = Unlimited row. Backend monthly window + Home card |
| 85 | [Replay button + on-screen mute control](issue-85-replay-button-and-mute-control.md) | enhancement · **done 2026-07-06** (`a52eba6`) | | Variant B shipped: minimalistic replay + mute in the bottom audio strip, both modes; absorbs regressed #13 |
| 84 | [Drop streak/best-score from UI (keep logic)](issue-84-drop-streak-bestscore-ui.md) | enhancement · **done 2026-07-06** | | Variant B shipped: result = score box only, Home stats row removed; `QuizStats` keeps computing; Result nav stays `HangsQuizNav` per #86 frames |
| 83 | [Unify quiz top bar](issue-83-unify-quiz-top-bar.md) | enhancement · **done 2026-07-06** (`9dab862`) | | G1 layout shipped: close+settings top bar, muted meta row, timer at bottom, both modes. Settings chip → full Settings sheet until #68's session menu; ResultView nav → #84 |
| 82 | [UX paper-cuts bundle (2026-07-03 review)](issue-82-ux-papercuts-uiux-review.md) | bug · **done 2026-07-06** (`f44976f`..`64af340`) | | All 6 items shipped, one commit each; categories multi-select fixed a latent retriever no-op; backend Fly v60 |
| 81 | [Quiz dialogs & timing fairness](issue-81-quiz-dialogs-timing-fairness.md) | bug · **done 2026-07-06** | | Approved alert (Continue/End Quiz), countdown freeze behind dialog+sheet, 44pt Stay here; NO typing pause per founder decision 2a |
| 80 | [Settings navigation HIG](issue-80-settings-navigation-hig.md) | bug · **done 2026-07-06** | | Pinned bar + `HangsBackChip` + edge-swipe pop shipped; iOS 26 pop-gesture workaround documented in plan |
| 79 | [Bug: typed-answer × voice race → double submission](issue-79-typed-answer-voice-race.md) | bug · ready-for-agent | | Approved 2026-07-05 (preserve tap-to-edit). NOT gated by #86 (no new UI). Re-verify line anchors (77.2 refactored teardown) |
| 78 | [Bug: Sign in with Apple name lost after re-sign-in](issue-78-apple-signin-name-lost.md) | bug · ready-for-agent (root cause verified 2026-07-07) | | Verified: response model omits `full_name`/`email` + iOS overwrites stored name with nil. Fix = additive response fields + nil-safe merge. Cross-refs #61 |
| 77 | [Voice commands for hands-free driving](issue-77-voice-commands-handsfree.md) | enhancement · agent work done — remaining `[HUMAN]` | `[ ]` #77 | All 7 agent sessions done 2026-07-03. Remaining: `[HUMAN]` 77.15 on-device gate + `.pen` ⌘S save for 77.12. Absorbed #66 (77.1), #67-A (77.2), #68 earcon (77.10) |
| 76 | [`entertainment` category](issue-76-entertainment-category.md) | enhancement · F-3a done · F-3b built dormant | `[x]` #76 | F-3a shipped 2026-06-30; F-3b shipped dormant 2026-07-02 behind flags. Remaining: first manual generation run at un-park (`[HUMAN]`, PAYG) |
| 75 | [Automated issue-prep orchestrator](issue-75-prep-orchestrator.md) | infra · in progress | `[~]` #75 | Skills authored (/split-issue, /design-soundness, /prepare-issue). Remaining: 75.6 end-to-end dry-run |
| 74 | [Best OpenRouter models for creative gen](../research/openrouter-creative-question-models-2026-06-26.md) | research · delivered — validate at un-park | `[ ]` #74 | Feeds #72 Phase 6 Lever-A (`GENERATION_MODEL` swap). Validate live before the paid flip |
| 72 | [Question fun/engagement redesign](issue-72-question-fun-engagement-redesign.md) | enhancement · parked (awaiting founder un-park) | `[~]` #72 | Phases 0–5 done; Phase 6b quality PASSED 2026-06-27. Everything dormant behind toggles. Un-park = founder go (scale + categories) |
| 71 | [Process: GitHub mirror refresh](issue-71-restore-ralph-and-process-drift.md) | chore · reduced scope | `[ ]` #71 | Ralph-restore struck (founder 2026-07-05: no autonomous loops); push audit + AI-news moot. Survives: run `mirror-issues.sh` |
| 70 | [Backend: ARQ worker Docker-path crash](issue-70-content-pipeline-residual-bugs.md) | bug · **done 2026-07-07** | `[x]` #70 | Closed on verification: worker crash already fixed by `649b1b9` (#60.P3, cites #70 — `find_in_ancestors`); dedup half superseded by #41 |
| 68 | [UX: driving defaults + image render](issue-68-driving-ux-defaults-and-earcon.md) | enhancement · **done 2026-07-06** | `[x]` #68 | thinkingTime 10s default, Settings session group, recording-sounds toggle, image-questions opt-in, `ImageQuestionView` de-orphaned. ⚠ image rows in prod pgvector unverified |
| 67 | [Audio interruption + barge-in](issue-67-audio-interruption-and-barge-in.md) | bug · A done via #77 · B deferred | `[ ]` #67 | Part A shipped (77.2). Part B barge-in deferred by founder. Open: `[HUMAN]` on-device interruption-recovery check |
| 64 | [Full-project review — findings ledger](issue-64-full-project-review.md) | review · umbrella | `[ ]` #64 | Spin-offs #65–#71 carry the work (#65/#69 done). Report `docs/artifacts/full-project-review-2026-06-21.html` |
| 63 | [Question-quality review: gen audit + corpus verification](issue-63-question-quality-review.md) | enhancement · ready-for-human | `[~]` #63 | The parked "whole generation process review"; owns MCQ yield validation (ex-#42). Founder-in-the-loop |
| 62 | [Auth Phase 3 — cross-device + purchase binding](issue-62-auth-phase3-cross-device-purchase-binding.md) | enhancement · ready-for-human (post-MVP) | `[ ]` #62 | Depends #61 + #50 |
| 61 | [Auth Phase 2 — Sign in with Apple](issue-61-auth-phase2-sign-in-with-apple.md) | enhancement · code done — remaining `[HUMAN]` | `[~]` #61 | Sessions A–D shipped + deployed (Fly v53/v54); security remediation done 2026-07-03. Remaining: on-device SK sign-in verify, privacy nutrition label, human security review |
| 59 | [Quiz-flow bug cluster](issue-59-quiz-flow-bug-cluster.md) | bug · mostly done | `[~]` #59 | All 8 bugs fixed 2026-06-17. Remaining: RS sim legs (RS-11..17 subset) via `/regression` + `[HUMAN]` 59.1 device TTS confirm |
| 56 | [iOS text localization — String Catalog](issue-56-ios-localization.md) | enhancement · in progress | `[~]` #56 | 56.1–56.4 done. Remaining: 56.5 full-suite confirm + 56.6 `[HUMAN]` Xcode catalog populate. NB: #86 UI work will add new strings after |
| 55 | [Repo file-structure cleanup](issue-55-repo-structure-cleanup.md) | chore · in progress | `[~]` #55 | A/B/C/E/F/G done. Deferred: D artifacts mass-move + `.pen` relocation. New drift: ~30 uncommitted handoff/testing files need a commit pass |
| 51 | [Product analytics (Sentry)](issue-51-product-analytics.md) | enhancement · **blocked on founder gate 51.2** | `[ ]` #51 | 51.1 taxonomy DONE 2026-06-11 (`docs/product/analytics-events.md`); needs ~5-min founder skim (51.2) before 51.3/51.4 instrumentation can run |
| 50 | [App Store Connect listing + ASC API](issue-50-app-store-connect-setup.md) | enhancement · ready-for-human | `[ ]` #50 | Founder does the `[HUMAN]` steps (instructions in artifacts); agent part unblocks once ASC API key lands in `.env` |
| 48 | [Pre-release review gauntlet](issue-48-pre-release-review-gauntlet.md) | product · ready-for-human (deferred) | `[ ]` #48 | 4-stage release review; stage 2 partly covered by #65 (done). Deferred until #45 tail lands |
| 45 | [iOS MCQ voice + design-port redesign](issue-45-ios-mcq-voice-and-redesign.md) | enhancement · tail remaining | `[~]` #45 | 45.1–45.6, 45.8–45.10, 45.12 done. Remaining: 45.7 wire+signoff, 45.11 light/dark vs `.pen`, 45.13 snapshot re-record |
| 41 | [ChromaDB decommission](issue-41-chromadb-decommission.md) | chore · done 2026-07-07 | `[x]` #41 | Phase A (Sessions A–C) + Phase B (B1–B4, founder-approved) complete: chromadb deleted repo-wide, prod /data/chroma wiped, CHROMA_PATH unset, quiz-pack-api back on 256MB. Owns dedup/ChromaDB cleanup scope (ex-#70) |
| 30 | [Batch-generate questions (grow `general` → ~500)](issue-30-batch-generate-categories.md) | enhancement · deferred (blocked on #72 un-park) | `[ ]` #30 | Generation paused; runs after un-park |

## Done / closed

| # | Title | Notes |
|---|---|---|
| 86 | [Pencil sync of approved UI proposals (2026-07)](issue-86-pencil-sync-approved-ui.md) | Done 2026-07-06 — all 8 items (`54c8f44`), founder frame review confirmed; design gate lifted for #80–#85/#68/#58 |
| 73 | [mba Postgres + Redis dev env](issue-73-mba-postgres-redis-dev-env.md) | Resolved 2026-06-23 (`e3e378a`); gate green ×2 |
| 69 | [Translation cache → durable store](issue-69-translation-cache-serving-cost.md) | Shipped 2026-07-06 — SQLite on `/data`, 271 tests green |
| 66 | [Voice submit ghost-question](issue-66-voice-submit-ghost-question.md) | Shipped via #77 77.1 (`5cabfd8`) |
| 65 | [Security: authenticate prod endpoints](issue-65-security-harden-production-endpoints.md) | Fully closed 2026-07-06 — grace-mode silence fixed (`aa5e43c`), `LEGACY_USER_ID_GRACE=off` flipped in prod + verified, `ENVIRONMENT=production` set |
| 60 | [Auth Phase 1 — anonymous identity](issue-60-auth-phase1-anonymous-identity.md) | Closed 2026-06-26 — prod-activated, device E2E pass, founder sign-off |
| 58 | [Authentication — research + design](issue-58-authentication.md) | Closed 2026-07-06 — impl spun off to #60/#61/#62; §9 screens → #61 (done) + #86 |
| 57 | [Loop verification backbone](issue-57-loop-verification-backbone.md) | All tracks A–F shipped; loops disabled 2026-07-05, DoR tooling lives on via #75 |
| 54 | [Design-refresh regressions (#52 fallout)](issue-54-design-refresh-regressions.md) | Done 2026-06-13 — all 21 sub-tasks + 7 child plans complete, merged |
| 53 | [OpenRouter LLM gateway](issue-53-openrouter-llm-gateway.md) | Shipped 2026-06-11; `LLM_GATEWAY` toggle |
| 52 | [iOS design-refresh sweep](issue-52-design-refresh-sweep.md) | Done — founder confirmed 2026-06-16; 52.18 snapshots folded into #56 follow-up |
| 49 | [Daily free-limit cost research](issue-49-daily-limit-cost-research.md) | Done — verdict "20/day sustainable"; feeds #87 |
| 47 | [GitHub Actions Node 24 upgrade](issue-47-github-actions-node24-upgrade.md) | Done 2026-06-08 |
| 46 | [Canonical-answer enforcement + logical branch](issue-46-answer-shape-and-logical-branch.md) | Done 2026-06-07/08 (`16161de`) |
| 44 | [Screenshot-verify step](issue-44-screenshot-verify-step.md) | Shipped 2026-06-11 — wired into `/regression` + `ios.md` |
| 43 | [Maestro MCP UI flows](issue-43-maestro-mcp-ui-flows.md) | Wontfix 2026-06-09 |
| 42 | [Question quality sweep + MCQ activation](issue-42-question-quality-and-mcq.md) | Closed 2026-07-06 — superseded: Track F → #72, yield validation → #63, Track E → #45; mba commits reconciled |
| 36 | [quiz-pack-api Phase 2](issue-36-quiz-pack-api-phase-2.md) | Shipped 2026-05-28 |
| 35 | [Parallel backlog burn-down](issue-35-parallel-backlog-burndown.md) | Done 2026-05-15 |
| 34 | [Claude context/token optimization](issue-34-claude-context-optimization.md) | Done |
| 33 | [quiz-pack-api Phase 1](issue-33-quiz-pack-api-phase-1.md) | Done 2026-05-15 |
| 32 | [On-demand generation service (umbrella)](issue-32-on-demand-generation-service.md) | Done — phases carried by #33/#36; later phases decompose on demand |
| 31 | [iOS test hardening](issue-31-ios-test-hardening.md) | Done (Phase 5 partial — XCUITest scheme wiring open) |
| 30↑ | — | see Open (#30 deferred) |
| 29 | [Backfill source_url/excerpt](issue-29-backfill-existing-questions.md) | Done 2026-05-04 |
| 28 | [iOS category picker expansion](issue-28-ios-category-picker-expansion.md) | Shipped `544eeb3` |
| 22–27 | Seam/refactor series (`issue-22`…`issue-27`) | Done 2026-04-30 – 2026-05-02 |
| 21 | Generate question Groups B–E | Superseded 2026-05-02 → #28/#29/#30 |
| 18/19/20 | RS-01 e2e · resubmit bug · timer bug | Done 2026-04 |
| 14 | [Hangs Redesign](issue-14-hangs-redesign.md) | Closed — superseded by #52/#45/#86 (design direction obsolete) |
| 13 | [Repeat + mute toggle](issue-13-repeat-mute.md) | Superseded by #85 — mute affordance regressed in #52; #77 owns voice "repeat" |
| 2–12, 15–17 | Early-era issues | Done (see files) |

## Conventions

- New issue: created by `/triage` (free text → file) or by hand. Numbering continues the sequence — find next via `ls issue-*-*.md \| sort -V \| tail -1`.
- File header must carry `**Triage:** <category> · <state>` and a `**Status:**` line (free-text human commentary).
- Backfill old files with the `**Triage:**` line opportunistically — when you touch an old issue for any reason, add the line.
- The index is regenerable. If it drifts, run `/triage "regenerate INDEX.md"`.
