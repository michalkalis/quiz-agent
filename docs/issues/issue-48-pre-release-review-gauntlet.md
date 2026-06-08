# Issue #48 — Pre-release review gauntlet (App Store)

**Triage:** interactive (review phase) → ready-for-agent (remediation phase)

Three-stage review pass before the first App Store submission. Run **in order** —
architecture first (shapes what security/quality looks at), security second (gates
release), comprehensive review last (catches what the narrow passes miss).

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

- [ ] Stage 1 report written, blockers extracted as issues
- [ ] Stage 2 report written, **zero open security blockers**
- [ ] Stage 3 run, findings triaged
- [ ] Backend remediation findings decomposed into `#49` atomic `- [ ]` tasks (Ralph handoff)
- [ ] Go/no-go summary for App Store submission
