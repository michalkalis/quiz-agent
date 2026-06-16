# Issue #57 — Autonomous loop hardening (enforced verification backbone)

**Triage:** infra · ready-for-human
**Status:** Plan written 2026-06-15 from the agent-loops readiness re-audit (`docs/artifacts/agent-loops-readiness-v2-2026-06-15.html`). **Founder decisions resolved 2026-06-15** (see "Resolved decisions"): D → keep local LaunchAgent, FileVault stays ON; E → defer behind A–D; + verification altitude steer (gate on flow/state/elements, not pixel/`.pen` fidelity — see "Verification altitude"). Tracks A–B are the core (the missing "something that can say no"); C–E are cheap independent follow-ups. This issue changes how *all* future autonomous work is verified, so Tracks A/B land human-reviewed, not blind-overnight. Ready to start Track A on request.

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
3. The gate asserts **flow correctness, state-machine correctness, and presence of expected UI elements** — NOT pixel/design fidelity (see "Verification altitude" below).
4. `overnight.sh` halts the chain (non-zero exit, logged) when `ralph.sh` returns a gate-red exit code.
5. `main` is branch-protected: no merge from `ralph/**` without green CI.
6. An independent reviewer pass (fresh context, sees only diff + acceptance, prompted for correctness-only) runs before a task is accepted, and a CONCERNS verdict blocks acceptance.
7. The nightly scheduler is running again and resumes unattended (no manual re-bootstrap) after the next GUI login following a reboot — with FileVault left ON.

## Verification altitude (what the gate checks — founder steer 2026-06-15)

At this stage of development the loop must verify **the right flow and correct states, not design fidelity.** First-hand audit of the current iOS suite confirms this is mostly already true and only needs to be locked in:

- **HangsTests is already flow/state-based.** All 7 "snapshot" references are textual **state dumps** (`.stableDump`/`.dump`), zero pixel/`.png` images. Plus 192 ViewInspector structure assertions (`find(text:)`/`find(button:)`) across 15 files and the `HangsUITests` RS "click-through" scenarios. This is exactly the "click through the app, assert the expected buttons/elements are present" altitude we want — **keep it as the Track A gate.**
- **Pixel/`.pen` design-fidelity stays OUT of the autonomous merge gate.** The screenshot-verify-against-`docs/design/frames/` step (#44/#52) is a *separate* visual check, not part of `xcodebuild test`. The design is still moving (#14/#52), so gating the loop on 1:1-with-`.pen` would trip constantly on cosmetic drift. It remains a **non-gating, on-demand / human** check until the design stabilizes.
- **State-dump snapshot diffs are a re-record signal, not a hard block.** When an intentional UI change makes a `.stableDump` snapshot fail (the "model drift" we've already seen), that needs human re-record sign-off — the loop should surface it, not silently "fix" or hard-fail the whole run on it.

## Out of scope / won't-do (from the re-audit)

- **No `VISION.md` / `ARCHITECTURE.md`.** Not supported by credible sources (ETH/LogicStar: architectural overviews give no benefit, raise cost); our `CLAUDE.md` + `.claude/rules/*` is already the recommended pattern.
- **No DeepSeek / cheap-model swap** (marketing angle of the source article) — model-routing + budget cap + OpenRouter (#53) already cover cost.
- **No git worktrees for parallelism yet** — Steinberger rejects them; our sequential closed-loop is correct for our budget. Revisit only if we genuinely need parallel loops.
- **No open-loop / unsandboxed `--dangerously-skip-permissions`** beyond the current bounded setup.
- **No pixel-exact `.pen` design conformance as a merge gate** — see "Verification altitude". Demoted to on-demand/human.
- **No FileVault-off auto-login** — see resolved decision 1.

## Out of scope / won't-do (from the re-audit)

- **No `VISION.md` / `ARCHITECTURE.md`.** Not supported by credible sources (ETH/LogicStar: architectural overviews give no benefit, raise cost); our `CLAUDE.md` + `.claude/rules/*` is already the recommended pattern.
- **No DeepSeek / cheap-model swap** (marketing angle of the source article) — model-routing + budget cap + OpenRouter (#53) already cover cost.
- **No git worktrees for parallelism yet** — Steinberger rejects them; our sequential closed-loop is correct for our budget. Revisit only if we genuinely need parallel loops.
- **No open-loop / unsandboxed `--dangerously-skip-permissions`** beyond the current bounded setup.

## Resolved decisions (founder, 2026-06-15)

1. **Scheduler (Track D): keep the `LaunchAgent` on `mba`, FileVault stays ON.** Founder confirmed the premise — true zero-touch auto-login requires **FileVault disabled** (Apple disables automatic login when FileVault is on; after a reboot the Mac sits at the pre-boot unlock screen). Founder would rather not disable it. We do NOT disable FileVault. **`/schedule` cloud Routines cannot replace this loop** — the overnight run builds + tests iOS on the local Xcode/simulator and signs via the GUI-session Keychain; Anthropic's cloud Routines have no Xcode/simulator/Keychain, so they can only run Mac-independent work (backend, research, docs). Decision: keep the local LaunchAgent (it is the only thing that can drive iOS), make it resume cleanly, and accept that the *one* gap — a reboot — is closed by the next normal GUI login (which also unlocks FileVault + Keychain). Reboots are rare (the Mac is at home, not power-cycled routinely). Optionally use `/schedule` later *only* for Mac-independent jobs. (Security note: FileVault-on protects against physical theft; given the home setting the residual risk after this choice is low, and we are not lowering it further.)
2. **Visibility (Track E): defer behind A–D.** Confirmed convenience, not correctness — Track E starts only after A–D land.

## Tasks

All loop scripts are under `scripts/ralph/`. Tracks A and B are human-reviewed (they redefine verification). Run from repo root unless noted.

### Track A — Enforced verification gate (the backbone)

**Progress 2026-06-15 (commit `45ead41`):** 57.1–57.3 shipped + proven. The headline trip-test (criterion 1) was run offline with a fake-claude shim on a throwaway `ralph/test-trip57` branch (no model spend): a "done" iteration that commits a deliberately failing backend test → `ralph.sh` exits **5**, appends a `## BLOCKER (… automated test gate (backend))` to the focus file, and **halts without advancing**; re-run with a passing test → gate **GREEN**, exit 0, iteration counts. Implementation choices made under Rule #1/#4: (a) iOS gate per-iteration runs **HangsTests unit/ViewInspector only** — the slow/flaky RS click-through UI tests stay on push-CI + the end-of-run gate (per the existing #54 precedent), not per-iteration; flagged as a tradeoff for review. (b) A gate-red commit is **kept (flagged), not reverted** — preserves work for review on the throwaway branch and avoids an infinite redo loop. (c) Gate uses a **robust pytest runner** (repo `.venv` → PATH → `uv run`) because the headless overnight shell does not auto-activate a venv. **57.4 (branch-protect `main`) is NOT done — needs a founder decision** (see below): it conflicts with the solo "commit directly to main" rule. Live `overnight.sh` gate-red halt verified by code-review only (a real run pushes to origin); recommend a real overnight dry-run as part of human acceptance.

- [x] **57.1** — Confirm CI triggers on `ralph/**` pushes (`.github/workflows/*` — backend-ci, ios-ci, web-ui-ci are path-filtered). If the `ralph/**` branch glob is missing from any workflow's `on.push.branches`, add it. Acceptance: a test push to a `ralph/test` branch triggers the relevant path-filtered workflow.
- [x] **57.2** — Add a **scoped post-iteration test gate** in `ralph.sh`: after each iteration's commit, detect changed top-level scope (backend → `cd apps/quiz-agent && pytest` on affected paths; quiz-pack-api → its pytest; iOS → `xcodebuild test` HangsTests + relevant `HangsUITests` RS scenarios). The iOS gate runs the **flow/state/structure** suite (ViewInspector + RS click-through); it does **not** run pixel/`.pen` design-fidelity checks (see "Verification altitude"). On red: revert the iteration's commit (or hard-flag it), count it toward `CONSECUTIVE_FAILS`, do NOT report success. A failure that is *only* a `.stableDump` snapshot drift is surfaced as a re-record signal, not a silent auto-fix. Diff-level test selection, not whole-suite. Acceptance: the red-test trip test (criterion 1) reverts/flags and does not advance.
- [x] **57.3** — Make `overnight.sh` **act on** `ralph.sh`'s exit code: on a gate-red exit (the iOS gate exit 4 + the new 57.2 exit), stop the chain, do NOT push the branch, write the failure to the run log + a `## BLOCKER`. Acceptance: a forced red exit halts the chain and leaves the branch unpushed.
- [~] **57.4 — WON'T-DO (founder decision 2026-06-16).** Branch-protecting `main` with required status checks would block *every* update to `main` whose commit lacks green CI — including the founder's own direct commits — which conflicts head-on with this repo's "commit directly to main, no feature branches" rule (`shared.md`). Enforcement for the loop→main path is already covered: **57.3 withholds the push of any gate-red `ralph/**` branch**, so a red branch never reaches the remote, and the human reviews before merging via `morning.sh`. Decision: leave `main` unprotected; rely on 57.3 + human review. Revisit only if non-admin contributors are ever added. (Success criterion 5 is intentionally satisfied by the 57.3 no-push mechanism rather than GitHub branch protection.)

### Track B — Independent checker (maker ≠ checker)

**Progress 2026-06-16 (commit `7ca305e`):** 57.5 shipped + proven offline. After the 57.2 scoped gate is GREEN, `ralph.sh` now runs a **separate `claude -p`** (fresh context, fixed model `RALPH_REVIEWER_MODEL`=sonnet — independent of the worker's router-chosen model) that sees ONLY the iteration's diff (written to `logs/review-*.diff`) + the focus file's acceptance, via `prompts/review-task.md`. It is constrained to flag *only* correctness / stated-requirement gaps (no style, no design fidelity) and ends with `REVIEW_VERDICT: PASS|CONCERNS`. **CONCERNS — or any unparseable verdict** ("could not confirm" ≠ "confirmed", same fail-loud stance as the gate's missing-pytest) — blocks acceptance: `ralph.sh` exits **6**, appends a reviewer `## BLOCKER`, and does not advance. `overnight.sh` now treats exit 6 as gate-red (halt chain, withhold push), alongside 4/5. Toggle `RALPH_REVIEWER=0`; budget `RALPH_REVIEWER_BUDGET_USD` (default $1.00). Verified with an offline fake-`claude` shim on a throwaway `ralph/test-trip57b` branch (no model spend): a gate-green "done" iteration → reviewer **CONCERNS** → exit 6 + `## BLOCKER (independent reviewer (CONCERNS))` appended + halt; swap the shim to **PASS** → exit 0, iteration counted, no BLOCKER. Live overnight-chain halt verified by code-review of the `overnight.sh` exit-6 branch (a real run pushes to origin); recommend confirming in the next real overnight dry-run as part of human acceptance.

- [x] **57.5** — Add a **fresh-context reviewer pass** before a task is accepted: a separate `claude -p` invocation (the `code-reviewer` agent / `/code-review`) that sees ONLY the diff + the issue's `## Acceptance`, prompted to flag *only* gaps affecting correctness or stated requirements (Anthropic: reviewers over-report; constrain them). Returns `PASS` / `CONCERNS`. `CONCERNS` blocks acceptance → `## BLOCKER`. Wire it into `ralph.sh` after 57.2's gate is green. Acceptance: a diff that violates its acceptance criteria gets a `CONCERNS` verdict and is not accepted.

### Track C — Machine-evaluable done-state + native `/goal`

- [ ] **57.6** — Standardize a machine-evaluable `## Acceptance` block (the exact shape used in this issue's success criteria) as a required section in every issue plan. Update the issue template + the `/triage` skill so `ready-for-agent` requires it. Add the **verification-altitude rule** to `.claude/rules/ios.md` (test flow/state/element-presence, not pixel/design fidelity; `.pen` screenshot-verify is non-gating until design stabilizes) so future tests are written at the right altitude. Backfill the open `ready-for-agent` issues (#30 parked, #42, #44, #49, #51, #56) with an explicit done-state line. Acceptance: every `ready-for-agent` issue has a checkable `## Acceptance`; the ios rules file states the altitude rule.
- [ ] **57.7** — Adopt the native `/goal` stop-condition pattern for single-issue runs (Haiku re-checks the done-condition each turn). Document it in `scripts/ralph/README.md` as the canonical stop-condition; replace fragile prose-parsing of "done" where it can. Acceptance: a single-issue run uses `/goal` and stops on the stated condition, not on a guessed cue.

### Track D — Reliable run (LaunchAgent, FileVault ON)

- [ ] **57.8** — Re-enable the `00:30` `LaunchAgent` on `mba` (it was unloaded 2026-06-11). Add `RunAtLoad` so it resumes immediately on the next GUI login after a reboot (the login also unlocks FileVault + the signing Keychain), and document the one rare gap — a reboot pauses the loop until the next login — plus a one-line re-bootstrap in `scripts/ralph/README.md`. Do NOT disable FileVault or enable auto-login. Acceptance: with FileVault ON, the run fires unattended on schedule while logged in, and resumes automatically on the next login after a reboot (no manual `launchctl` re-bootstrap needed).

### Track E — Visibility (deferred behind A–D; lower priority)

- [ ] **57.9** — Notify on **state change only** (`done` / `BLOCKER`), not per iteration — matches the goal-level working style (push/email/Slack, one line). Acceptance: a run that finishes or blocks pings once; a run mid-iteration does not.
- [ ] **57.10** — One-way GitHub Issues **mirror**: after a run, sync one GitHub issue per `issue-NN` with a state label (todo/wip/blocked/done) via `gh`. Source of truth stays the local plan files. Acceptance: the board reflects the post-run state and is regenerable.

## Notes

- This issue is itself a closed-loop change: it is *about* the loop, so it gets the human-review treatment the research recommends for judgment-heavy infra. Land Track A, prove criterion 1, then layer B–E.
- Sources + full audit: `docs/artifacts/agent-loops-readiness-v2-2026-06-15.html`.
