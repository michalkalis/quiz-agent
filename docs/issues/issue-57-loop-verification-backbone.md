# Issue #57 — Autonomous loop hardening (enforced verification backbone)

**Triage:** infra · ready-for-human
**Status:** Plan written 2026-06-15 from the agent-loops readiness re-audit (`docs/artifacts/agent-loops-readiness-v2-2026-06-15.html`). Tracks A–B are the core (the missing "something that can say no"); C–E are cheap independent follow-ups. Needs two founder decisions before an autonomous run (see "Open decisions"). This issue changes how *all* future autonomous work is verified, so Tracks A/B land human-reviewed, not blind-overnight.

## Why this exists

The readiness re-audit (first-hand, against `scripts/ralph/`) found the execution plumbing is solid but the **verification backbone is not enforced** — and verification is the single most-cited prerequisite for reliable autonomous loops across every credible source (Anthropic best-practices, Sourcegraph, Huntley, the TDAD arXiv paper). Verified gaps:

- **Test gate before commit is prompt-only.** `prompts/work-next.md` *tells* the agent "tests must pass before you commit", but nothing in the harness enforces it. Backend changes have **zero** shell/CI gate inside the loop.
- **iOS gate is weak.** `ralph.sh` runs `xcodebuild test -only-testing:HangsTests` once at end of run (lines 240–263), and `overnight.sh` captures `ralph.sh`'s exit code but **does not act on it** (line ~154, `set +e`) — a red gate does not stop the overnight chain.
- **No independent checker** (maker = checker). "Verification" is the agent grading its own work.
- **Scheduler is OFF** since 2026-06-11 (`overnight-queue.md` line 32) — a loop that silently stops running is not a loop.
- **Done-state is inconsistent** — some issues have `## Acceptance`, most don't; nothing machine-evaluable for a stop-condition.

Steinberger's framing: *"Designing the loop is half of it. The other half is putting something in the loop that can say no."* Tracks A + B build that "no".

## Goal

Turn the loop from "I hope it ran the tests" into "it cannot mark work done — and cannot reach `main` — unless the relevant tests pass **and** an independent reviewer confirms the change against its acceptance criteria."

### Verifiable success criteria (the falsifiable proof — Rule #2)

1. **Red-test trip test:** on a throwaway `ralph/*` branch, introduce a change with a deliberately failing test in the changed scope → the loop must (a) NOT mark the task done, (b) NOT merge to `main`, (c) surface a `## BLOCKER`. Re-run after fixing → it proceeds. This is the headline acceptance test for Track A+B.
2. The scoped test gate runs only tests relevant to the changed files (diff-level), not the whole suite (TDAD: targeted > whole-repo; CodeScene: diff-level coverage).
3. `overnight.sh` halts the chain (non-zero exit, logged) when `ralph.sh` returns a gate-red exit code.
4. `main` is branch-protected: no merge from `ralph/**` without green CI.
5. An independent reviewer pass (fresh context, sees only diff + acceptance, prompted for correctness-only) runs before a task is accepted, and a CONCERNS verdict blocks acceptance.
6. The nightly scheduler is running again (or replaced) and survives a reboot without a manual GUI login.

## Out of scope / won't-do (from the re-audit)

- **No `VISION.md` / `ARCHITECTURE.md`.** Not supported by credible sources (ETH/LogicStar: architectural overviews give no benefit, raise cost); our `CLAUDE.md` + `.claude/rules/*` is already the recommended pattern.
- **No DeepSeek / cheap-model swap** (marketing angle of the source article) — model-routing + budget cap + OpenRouter (#53) already cover cost.
- **No git worktrees for parallelism yet** — Steinberger rejects them; our sequential closed-loop is correct for our budget. Revisit only if we genuinely need parallel loops.
- **No open-loop / unsandboxed `--dangerously-skip-permissions`** beyond the current bounded setup.

## Open decisions (founder)

1. **Scheduler (Track D):** keep the macOS `LaunchAgent` on `mba` (needs auto-login fixed so it survives reboot) **or** migrate the nightly run to native `/schedule` cloud Routines (survives reboot/session-close, needs GitHub connection; this is what the Claude Code team itself uses). Recommendation: evaluate `/schedule` — removes the GUI-login dependency entirely.
2. **Visibility (Track E):** add the GitHub Issues mirror + done/blocked ping now, or defer? It's convenience, not correctness — safe to defer behind A–D.

## Tasks

All loop scripts are under `scripts/ralph/`. Tracks A and B are human-reviewed (they redefine verification). Run from repo root unless noted.

### Track A — Enforced verification gate (the backbone)

- [ ] **57.1** — Confirm CI triggers on `ralph/**` pushes (`.github/workflows/*` — backend-ci, ios-ci, web-ui-ci are path-filtered). If the `ralph/**` branch glob is missing from any workflow's `on.push.branches`, add it. Acceptance: a test push to a `ralph/test` branch triggers the relevant path-filtered workflow.
- [ ] **57.2** — Add a **scoped post-iteration test gate** in `ralph.sh`: after each iteration's commit, detect changed top-level scope (backend → `cd apps/quiz-agent && pytest` on affected paths; quiz-pack-api → its pytest; iOS → `xcodebuild test` HangsTests). On red: revert the iteration's commit (or hard-flag it), count it toward `CONSECUTIVE_FAILS`, and do NOT report success. Diff-level test selection, not whole-suite. Acceptance: the red-test trip test (criterion 1) reverts/flags and does not advance.
- [ ] **57.3** — Make `overnight.sh` **act on** `ralph.sh`'s exit code: on a gate-red exit (the iOS gate exit 4 + the new 57.2 exit), stop the chain, do NOT push the branch, write the failure to the run log + a `## BLOCKER`. Acceptance: a forced red exit halts the chain and leaves the branch unpushed.
- [ ] **57.4** — Branch-protect `main`: require the relevant CI checks green before any merge from `ralph/**`. Acceptance: a merge attempt with red CI is blocked. (Repo setting via `gh` — may need a `[HUMAN]` confirm if it touches GitHub repo admin.)

### Track B — Independent checker (maker ≠ checker)

- [ ] **57.5** — Add a **fresh-context reviewer pass** before a task is accepted: a separate `claude -p` invocation (the `code-reviewer` agent / `/code-review`) that sees ONLY the diff + the issue's `## Acceptance`, prompted to flag *only* gaps affecting correctness or stated requirements (Anthropic: reviewers over-report; constrain them). Returns `PASS` / `CONCERNS`. `CONCERNS` blocks acceptance → `## BLOCKER`. Wire it into `ralph.sh` after 57.2's gate is green. Acceptance: a diff that violates its acceptance criteria gets a `CONCERNS` verdict and is not accepted.

### Track C — Machine-evaluable done-state + native `/goal`

- [ ] **57.6** — Standardize a machine-evaluable `## Acceptance` block (the exact shape used in this issue's success criteria) as a required section in every issue plan. Update the issue template + the `/triage` skill so `ready-for-agent` requires it. Backfill the open `ready-for-agent` issues (#30 parked, #42, #44, #49, #51, #56) with an explicit done-state line. Acceptance: every `ready-for-agent` issue has a checkable `## Acceptance`.
- [ ] **57.7** — Adopt the native `/goal` stop-condition pattern for single-issue runs (Haiku re-checks the done-condition each turn). Document it in `scripts/ralph/README.md` as the canonical stop-condition; replace fragile prose-parsing of "done" where it can. Acceptance: a single-issue run uses `/goal` and stops on the stated condition, not on a guessed cue.

### Track D — Reliable run (founder decision 1)

- [ ] **57.8** — Per the founder's choice: either fix `mba` auto-login so the `00:30` LaunchAgent survives a reboot, or migrate the nightly run to `/schedule` cloud Routines. Re-enable whichever is chosen. Acceptance: the scheduled run fires unattended after a reboot with no manual GUI login.

### Track E — Visibility (founder decision 2; lower priority)

- [ ] **57.9** — Notify on **state change only** (`done` / `BLOCKER`), not per iteration — matches the goal-level working style (push/email/Slack, one line). Acceptance: a run that finishes or blocks pings once; a run mid-iteration does not.
- [ ] **57.10** — One-way GitHub Issues **mirror**: after a run, sync one GitHub issue per `issue-NN` with a state label (todo/wip/blocked/done) via `gh`. Source of truth stays the local plan files. Acceptance: the board reflects the post-run state and is regenerable.

## Notes

- This issue is itself a closed-loop change: it is *about* the loop, so it gets the human-review treatment the research recommends for judgment-heavy infra. Land Track A, prove criterion 1, then layer B–E.
- Sources + full audit: `docs/artifacts/agent-loops-readiness-v2-2026-06-15.html`.
