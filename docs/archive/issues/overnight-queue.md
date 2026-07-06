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
# 3. Scheduled path is LIVE again (#57 57.8, re-bootstrapped 2026-06-16 with RunAtLoad=true).
#    The 00:30 LaunchAgent fires unattended while 'agent' is logged in, and auto-resumes on
#    the next GUI login after a reboot (no manual launchctl needed). To unload it again:
#    ssh mba 'launchctl bootout gui/502/com.quizagent.ralph-overnight'.
#    NOTE: with RunAtLoad=true, re-bootstrapping also fires one run immediately — hold the
#    overnight lock (mkdir scripts/ralph/.overnight.lock) first if you want to register only.
# 4. iOS builds confirmed on mba (system Xcode 26.5 + iOS 26 SDK, license accepted — verified
#    2026-06-10). 17 screenshot-verify reference PNGs are committed under docs/design/frames/.
#    launch-issue52.sh fails loud if the SDK/license/PNGs are missing.
#
# ====================================================================================
# QUEUE (priority order)
# ====================================================================================
#
# 1 — Quiz-flow bug cluster (#59). 8 founder-reported voice-screen regressions, root-caused +
#     adversarially verified. Founder approved the FULL set in priority order 2026-06-17. Runs
#     FIRST: these are P0/P1 live-device breakages (core hands-free value broken), so they outrank
#     the #56 refactor — if the wall-clock budget runs out, #56's tail drops, not these.
#     7 atomic '- [ ]' tasks (P0: 59.3/59.1 · P1: 59.4/59.7 · P2: 59.2/59.5/59.6/59.8) + 1 '- [HUMAN]'
#     (59.1 real-device TTS confirm — OUT OF LOOP; do NOT mark 59.1 done off the green sim suite).
#     Each task lands its fix + its RS guard (RS-11..RS-18, see docs/testing/regression-scenarios.md)
#     in one commit; the guard is the thing that goes red→green (#57). Cap is higher than task-count
#     because each is a real bug fix + NEW test infra (spy/injectable-error/a11y-id/geometry), and the
#     #57 gate spends build/test/reviewer/goal-check iterations per task on iOS.
docs/issues/issue-59-quiz-flow-bug-cluster.md | 26
#
# 2 — iOS text localization (#56). String Catalog (Localizable.xcstrings) extraction + infra.
#     9 atomic '- [ ]' tasks + 1 '- [HUMAN]' (see issue file task list). English source text as
#     the key (keeps ViewInspector find(text:) assertions passing). HARD GATE at 56.2: a pilot
#     test must confirm find(text:) still passes before mass extraction — if it fails the loop
#     appends a BLOCKER and stops. 56.6 (pseudo-loc visual smoke) stays '- [HUMAN]', skipped.
#     NB: touches project.pbxproj (add catalog file + SWIFT_EMIT_LOC_STRINGS) — review the diff
#     carefully before merge.
docs/issues/issue-56-ios-localization.md | 12
#
# ====================================================================================
# DONE — landed on main; removed so the loop won't re-run them
# ====================================================================================
# #52  iOS design-refresh sweep — Ralph loop COMPLETE 2026-06-13 (merge bf4e023, final task
#      52.15 Paywall redesign). Human tail 52.16–52.18 (SK copy / fidelity eyeball / snapshot
#      baselines) stays open in the issue but is NOT Ralph-runnable. Earlier tasks via prior merges.
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
