# Overnight Ralph queue — priority run-order
#
# Parsed by scripts/ralph/overnight.sh. Format: one focus file per line, optional
# iteration cap after '|'; '#' and blank lines are ignored; a leading '- ' bullet is OK.
# The runner honors a global ~6h wall-clock budget (OVERNIGHT_MAX_SECONDS) on top of the
# per-issue caps, so order = priority: if time runs out, the tail is dropped.
#
# Caps ~= (atomic '- [ ]' tasks in the issue) + ~3 slack. Repeatable loops (42.20, 30.G)
# get a larger cap because one logical task runs many iterations.
#
# Prepared by the 2026-06-10 overnight-prep triage. Reclassification rationale lives in each
# issue file; the candidate principle is in ~/.claude/plans/jolly-humming-quill.md.
#
# ====================================================================================
# PREREQUISITES before this queue can run (read first)
# ====================================================================================
# 1. mba 'main' is DIVERGED from origin — overnight.sh will ABORT on 'git pull --ff-only'.
#    Shared base 946b378; origin/main = +3 (CI fix, overnight infra, autonomy grant);
#    mba/main = +7 Track F commits 25ca427..4847011 (incl. fix E), none pushed.
#    A ff-only pull fails. Reconcile first (review mba's Track F commits, then merge/rebase
#    onto a single main and land it on mba), and sync this prep commit to mba too.
#    Until then the unattended run cannot start. Ask before pushing mba's commits.
# 2. Auto-login OFF on mba (memory project_agent_mac_setup): after a full reboot the 00:30
#    LaunchAgent won't fire until 'agent' logs into the GUI. Verify mba is logged in before
#    relying on the scheduled path.
# 3. iOS builds confirmed working on mba (system Xcode 26.5 + iOS 26 SDK, license accepted —
#    verified 2026-06-10). Bare ralph.sh needs no DEVELOPER_DIR, so the iOS issue below is safe.
#
# ====================================================================================
# QUEUE (priority order)
# ====================================================================================
#
# 1 — keystone: screenshot-verify unlocks the agent's own visual self-check, so every
#     iOS task after it can self-verify. Mostly doc/skill edits + one sim smoke (44.5).
docs/issues/issue-44-screenshot-verify-step.md | 8
#
# 2 — active MCQ content loop. fix E landed (4847011); 42.20 generation is unblocked and
#     repeatable toward ~40 candidates, then 42.23 importer (code+tests). Backend-only.
#     Headless skips 42.21 (Workflow), 42.22 (founder), 42.24 (prod) automatically.
docs/issues/issue-42-question-quality-and-mcq.md | 10
#
# 3 — iOS MCQ voice + redesign. Reclassified agent tasks 45.8/45.9/45.10/45.12 (Xcode 26.5
#     on mba). Placed after #44 so it can screenshot-verify. Human tail 45.7/45.11/45.13 skipped.
docs/issues/issue-45-ios-mcq-voice-and-redesign.md | 7
#
# 4 — paywall-prep cost research (8 atomic tasks, research-only, no iOS). Reads call sites +
#     live Fly/claude-api pricing → HTML cost model. fast-follow, not a launch blocker.
docs/issues/issue-49-daily-limit-cost-research.md | 11
#
# 5 — analytics taxonomy. Only 51.1 runs unattended; 51.2 is a founder gate that halts
#     51.3/51.4 (Ralph exits no-tasks at the gate). Low cap on purpose.
docs/issues/issue-51-product-analytics.md | 4
#
# 6 — post-launch content growth (general -> ~500). Repeatable 30.G/30.M loop, lowest priority.
docs/issues/issue-30-batch-generate-categories.md | 6
#
# ====================================================================================
# EXCLUDED — genuine [HUMAN] or not headless-runnable (do NOT queue)
# ====================================================================================
# #50  App Store Connect — needs Apple ID + Paid Apps agreement + IAP creation (external access).
# #48  Pre-release review gauntlet — founder-deferred; review stages are interactive/billed, not Ralph.
# #14  Hangs redesign umbrella — per-phase design judgment + .pen visual fidelity.
# Loose TODO "Logical-puzzle reference URLs" — backend-doable but has no issue file (no focus path);
#   promote it to an issue first if you want it queued.
