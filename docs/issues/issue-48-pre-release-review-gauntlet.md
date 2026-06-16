# Issue #48 — Pre-release review gauntlet (App Store)

**Triage:** interactive (review phase) → ready-for-agent (remediation phase)

**Founder decision 2026-06-09:** **Defer — not yet.** Run this gauntlet later, once the MCQ + design
blockers are closer to done. Parked for now; no stages started.

**Founder steer 2026-06-16:** this issue is the home for the "full app review" the founder wants —
"is the app ready for release?" from **two angles**: (1) **iOS UX/UI** release-readiness, and
(2) **backend security + release-readiness**. Added **Stage 0 (iOS UX/UI review)** below to make the
UX/UI angle explicit. **Deliverable of every stage is a research/analysis report + a ranked,
prioritised findings list + a go/no-go call — not code.** Remediation is spun off into follow-up
issues. Still not started this session; queue it after the #45 MCQ tail lands.

Four-stage review pass before the first App Store submission. Run **in order** — UX/UI and
architecture first (shape what the deeper passes look at), security next (gates release),
comprehensive review last (catches what the narrow passes miss).

## Stage 0 — iOS UX/UI release-readiness review

- Tools: `review-ui` skill on key-screen screenshots (drive the sim via XcodeBuildMCP), plus a
  manual heuristic pass against the iOS HIG and the `.pen` design intent.
- Scope: onboarding flow, the voice-answer + MCQ core loop, error/recovery paths, result/completion,
  settings, paywall/paywall-offline — light **and** dark mode. Hands-free-while-driving ergonomics
  (tap targets, glanceability, audio-first affordances) get special weight since that is the product.
- Output: ranked UX/UI findings (blocker vs. polish vs. defer) and an explicit **"is the app
  UX/UI-ready to release?"** verdict.

## Ralph suitability — NOT for the review stages

The three review stages are **interactive / human-gated**, not a Ralph burndown:

- They produce **reports + ranked findings**, not atomic code changes with a
  test-pass acceptance check — Ralph's anti-pattern ("tasks without clear acceptance
  criteria → Ralph drifts", see `scripts/ralph/README.md`).
- Stage 2 is a **release gate**: deciding what counts as a blocker is human judgment,
  and README warns against Ralph "when you're about to ship something time-sensitive".
- Stage 3 (`/code-review ultra`) is **user-triggered + billed** — neither I nor Ralph
  (`claude -p`) can launch it.

**What IS Ralph-able: the remediation phase.** Once Stages 1–2 finish and findings are
decomposed into atomic `- [ ]` fix tasks with acceptance checks, spin them into a
follow-up issue (e.g. `#49 pre-release remediation`) and burn it down with the existing
generic loop — no new launcher needed for backend-only work:

```bash
scripts/ralph/ralph.sh docs/issues/issue-49-*.md
```

iOS-side fixes still need the simulator → keep those `[HUMAN]`, or use a
`launch-issue49.sh` mirroring `launch-issue46.sh` only if the iOS tail is large.

## Why now

The MVP surface is feature-complete enough to ship (#36 Phase 2, #42 backend, #45/#46
landed). Before exposing the backend + iOS app to public users we need one disciplined
review pass instead of ad-hoc spot checks. App Store review also expects basic privacy /
data-handling hygiene we have not formally audited.

## Stage 1 — Architecture review

- Tool: `improve-codebase-architecture` skill (domain-aware, reads `CONTEXT.md`).
- Scope: `apps/quiz-agent`, `apps/quiz-pack-api`, `packages/shared` — seam integrity
  (QuestionStore / QuestionRetriever / PackGenerator), coupling, dead duplicate paths
  after the ChromaDB→pgvector cutover, testability gaps.
- Output: ranked deepening/refactor opportunities; defer non-blockers to their own issues.

## Stage 2 — Security review

- Tool: `security-review` skill (or `security-reviewer` agent) + `/security-review` on diff.
- Scope: secrets handling (.env discipline), API authn/authz on quiz-pack-api (JWS verify),
  SSE endpoints, input validation on generation endpoints, PII / data-at-rest, Fly.io
  exposure, dependency CVEs, rate-limiting / abuse on freemium limits.
- Output: blockers must be fixed before submission; log lower-severity as follow-up issues.

## Stage 3 — Comprehensive review (Claude skill)

- Tool: `/code-review ultra` (multi-agent cloud review of the branch) — broad correctness +
  reuse/efficiency sweep across the whole release surface, including iOS.
- Note: user-triggered + billed; I cannot launch it — flag when stages 1–2 are clean.
- Output: confirmed findings triaged into fix-now vs. defer.

## Success criteria

- [ ] Stage 0 iOS UX/UI report written, **UX/UI release-readiness verdict** given, blockers extracted
- [ ] Stage 1 architecture report written, blockers extracted as issues
- [ ] Stage 2 security report written, **zero open security blockers**
- [ ] Stage 3 comprehensive review run, findings triaged
- [ ] Remediation findings decomposed into atomic `- [ ]` tasks (Ralph handoff) per area
- [ ] Go/no-go summary for App Store submission (UX/UI **and** backend)
