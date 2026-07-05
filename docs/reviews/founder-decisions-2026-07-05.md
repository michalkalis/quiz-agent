# Founder decisions — project review 2026-07-05

Source: `docs/artifacts/project-review-2026-07.html` (§ Rozhodnutia pre zakladateľa). Points 1–3 handled separately. Recorded verbatim-intent from the interactive session.

| # | Topic | Decision |
|---|-------|----------|
| 4 | Un-park question generation | **Stays PARKED.** No pilot run yet. |
| 5 | Grace-mode auth silently passing unauthenticated requests | **Fix with top priority inside #65** (security hardening) — not accepted as standing risk. |
| 6 | Re-scope #65 + fresh ready-checks for #66 / #67-A / #68 / #70 | **Approved.** Execution mode (autonomous agent vs. in-session) left to agent's judgment — note: no autonomous loops for now (see #9). |
| 7 | Barge-in (#67-B) | **MVP: question plays to the end** (no barge-in). Barge-in is the desired end-state — revisit post-MVP with real in-car experience. #67 can complete without it. |
| 8 | UI review direction defaults (quiz = driving-first, settings = standard screen, HTML output w/o mockups) | **All 3 confirmed.** UI issues #78–#85 stand; triage in a dedicated UI review session. |
| 9 | Ralph nightly loop | **No autonomous loops for now.** Laptop/origin = source of truth; mba work reconciled (see actions below). |
| 10 | Debt bundle (typed question contract + /verify-api, Dockerfile deps from pyproject, CHROMA_PATH deploy check) | **Agent's judgment.** Constraint: before fixing anything, verify it is actually used (and used correctly) — don't fix dead surface. |
| 11 | Doc refresh + web-ui | **Approved: refresh PRD/READMEs/rules; remove web-ui** from layout and CI (re-add when a web client actually starts). |
| 12 | [HUMAN] steps (77.15 in-car test, #61 device verification + privacy label + sign-off, #50 ASC) | **Coming days.** Agent prepares exact step-by-step guides for each. |

## Actions already taken this session (point 9)

- mba reachable again (Tailscale was off). Both nightly schedulers (`com.quizagent.ralph72`, `com.quizagent.ralph-overnight`) **unloaded and plists moved to `~/LaunchAgents-disabled/`** on mba — they will not fire again, even after GUI login.
- Scheduler config backed up into repo: `infra/ralph-mba/` (ralph72-window.sh + both plists). Loop scripts were already versioned under `scripts/ralph/`.
- mba's 254 unpushed main commits = pure loop noise (half-hourly NOT-READY stamps + reports); backed up as `backup/mba-main-20260705` on origin, **not** merged.
- Real mba-only work found and pushed to origin:
  - `ralph/overnight-20260613-1034` — **8 commits of #56 iOS localization** (Localizable.xcstrings, String(localized:) conversions, tasks 56.1–56.5). Likely explains the "Slovak didn't activate" discrepancy from the UI review — needs review + merge.
  - `ralph/overnight-20260622-2142` — 2 commits of #72 P0 (dormant generation-quality flags + baseline doc); verify against already-reconciled #72 state before merging.
