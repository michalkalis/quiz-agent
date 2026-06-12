# Ralph queue — priority run-order
#
# Parsed by scripts/ralph/overnight.sh. Format: one focus file per line, optional
# iteration cap after '|'; '#' and blank lines are ignored; a leading '- ' bullet is OK.
# The runner honors a global wall-clock budget (OVERNIGHT_MAX_SECONDS, default ~6h) on top
# of the per-issue caps, so order = priority: if time runs out, the tail is dropped.
#
# This queue feeds BOTH run paths (they share overnight.sh + a lockfile, so they can't collide):
#   • Scheduled  → 00:30 LaunchAgent → run-scheduled.sh → overnight.sh   (re-enable: see PREREQ 3)
#   • On-demand  → ssh mba bash code/quiz-agent/scripts/ralph/launch-overnight.sh   (tmux, watchable)
# Both cut a throwaway ralph/overnight-* branch, run the queue, push the branch, leave main clean.
# Morning/after: scripts/ralph/morning.sh on the laptop → review → merge.
#
# Caps ~= (atomic '- [ ]' tasks in the issue) + ~3 slack. Repeatable loops (30.G) get a
# larger cap because one logical task runs many iterations.
#
# Re-planned 2026-06-11 after the 20260611-1453 run merged (be83537). The previous queue
# (#44/#45/#51/#30) is now DONE on main — see DONE below. Next backlog = the #52 design sweep.
#
# ====================================================================================
# PREREQUISITES before this queue can run (read first)
# ====================================================================================
# 1. #44 + #45 on main — RESOLVED 2026-06-11 (merge be83537). #52 hard-depends on the
#    screenshot-verify harness (#44) and the shared QuestionView/AnswerOption/tokens (#45
#    agent tail) being on origin/main; both landed in the 1453 merge. The #45 HUMAN tail
#    (45.7 reveal decision / 45.11 light-dark QA / 45.13 snapshot sign-off) is intentionally
#    deferred and folds into #52's human pass (52.17) — it does NOT block the loop. The loop's
#    52.10/52.11 (Question/Result) build on #45's landed agent work, not the human QA.
# 2. mba 'main' sync — overnight.sh ff-pulls before each run, but verify if days have passed:
#    ssh mba 'cd code/quiz-agent && git pull --ff-only'. mba must be GUI-logged-in (auto-login
#    OFF → after a reboot the 00:30 LaunchAgent won't fire until 'agent' logs in).
# 3. Scheduled path is OFF until re-bootstrapped (it was unloaded the night of 2026-06-11 to
#    avoid re-running the 1453 queue). Re-enable AFTER you're happy the merge is good:
#    ssh mba 'launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.quizagent.ralph-overnight.plist \
#             && launchctl enable gui/$(id -u)/com.quizagent.ralph-overnight'
#    (Skip this if you only ever launch on-demand — the queue works the same either way.)
# 4. iOS builds confirmed on mba (system Xcode 26.5 + iOS 26 SDK, license accepted — verified
#    2026-06-10). 17 screenshot-verify reference PNGs are committed under docs/design/frames/.
#    launch-issue52.sh fails loud if the SDK/license/PNGs are missing.
#
# ====================================================================================
# QUEUE (priority order)
# ====================================================================================
#
# 1 — iOS design-refresh sweep (#52). One autonomous loop: Phase 1/2 are machine-verifiable
#     (tokens 52.1, fonts 52.2, components 52.3/52.4, flow logic 52.5–52.7); Phase 3 screens
#     52.8–52.15 each carry a screenshot-verify acceptance (build → sim screenshot → compare to
#     docs/design/frames/<frameId>.png → self-correct). 15 '- [ ]' tasks + slack. Only 52.16–52.18
#     stay '- [HUMAN]' (SK copy / fidelity eyeball / snapshot baselines) and are skipped.
#     NB: do NOT report #52 "done" off a green loop alone — the human fidelity pass (52.17) remains.
docs/issues/issue-52-design-refresh-sweep.md | 18
#
# ====================================================================================
# DONE — landed on main via the 1453 merge (be83537); removed so the loop won't re-run them
# ====================================================================================
# #44  Screenshot-verify step — all subtasks shipped (regression skill wired, VISUAL verdict).
# #45  iOS MCQ voice + redesign — agent tail 45.8/45.9/45.10/45.12 done; human tail 45.7/45.11/45.13
#      deferred into #52's 52.17. No '- [ ]' left for Ralph.
# #51  Product analytics — 51.1 taxonomy written; 51.2 is a founder gate that halts 51.3/51.4, so
#      nothing unattended remains. Re-add after the founder resolves 51.2.
# #49  Daily-limit cost research — DONE 2026-06-11 (overnight dry-run, merged via 672d476).
#
# ====================================================================================
# EXCLUDED — genuine [HUMAN] or not headless-runnable (do NOT queue)
# ====================================================================================
# #42  Question quality + MCQ — Track F (MCQ batch generation 42.20–42.24) PARKED 2026-06-11
#      (founder decision: the MCQ generation flow needs redesign, not another param tweak).
#      Tracks A–D already done. Do NOT queue until Track F is unparked + re-planned.
# #30  Batch-generate categories (grow general → ~500) — PARKED 2026-06-12 (founder decision:
#      ALL question generation paused until a proper review of the whole generation process,
#      same concern as #42 Track F). Do NOT queue until the review happens + unparks it.
# #50  App Store Connect — needs Apple ID + Paid Apps agreement + IAP creation (external access).
# #48  Pre-release review gauntlet — founder-deferred; review stages are interactive/billed, not Ralph.
# #14  Hangs redesign umbrella — per-phase design judgment + .pen visual fidelity.
# Loose TODO "Logical-puzzle reference URLs" — backend-doable but has no issue file (no focus path);
#   promote it to an issue first if you want it queued.
