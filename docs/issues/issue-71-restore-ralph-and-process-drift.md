# Issue #71 — Process: restore Ralph scheduler, push held auth commits, refresh GitHub mirror

**Triage:** chore · ready-for-human

**Created:** 2026-06-21 · **Founder:** Michal · **Source:** #64 full-project review (rank 22 — confirmed)

**Severity:** medium — the autonomous-velocity flywheel that makes this project sustainable solo has stalled.

## Problem

The development-process automation (the project's strongest asset, scored 8/10) has drifted:

1. **Ralph overnight scheduler NOT LOADED** on `mba` since 2026-06-17 (per
   `memory/project_agent_mac_setup.md`), so queued issues (#59, #56) aren't running overnight.
2. **~20 commits unpushed** on `main` — the entire #60 auth feature (JWT + rotating refresh +
   App Attest backend + iOS client) is committed locally and held pending founder push approval.
3. **GitHub Issues mirror is stale** (highest mirrored is #58; #59–#63 and now #64–#71 missing).
   The dormant one-way mirror is the founder's phone-visibility channel.
4. **Cloud AI-news routine** produced its last digest `docs/research/ai-news-2026-06-16.md` (5+
   days). Stale `.claude/scheduled_tasks.lock` (2026-06-13) present.

## Evidence (verified first-hand 2026-06-21)

- `git rev-list --count origin/main..main` → **20**.
- `scripts/ralph/mirror-issues.sh` present (the mirror tool exists, just not run).
- `.claude/scheduled_tasks.lock` dated 2026-06-13.
- `docs/research/ai-news-2026-06-16.md` is the most recent digest.
- `memory/project_agent_mac_setup.md` records the `launchctl … NOT LOADED` check on 2026-06-17.

## Recommendation

1. **[HUMAN]** SSH `mba` → `launchctl bootstrap gui/502 ~/Library/LaunchAgents/com.quizagent.ralph-overnight.plist`; confirm `state = waiting`.
2. **[HUMAN]** Review + push the held auth commits (security feature → explicit sign-off; pre-prod gate: set `AUTH_JWT_SECRET` Fly secret + `alembic upgrade head` + `APP_ATTEST_REQUIRED=on` + `APP_ATTEST_APP_ID` per #60/#65).
3. Run `scripts/ralph/mirror-issues.sh` to bring the GitHub board current through #71.
4. Remove the stale lock and confirm the cloud routine is live (`claude.ai/code/routines`).

**Opportunity (from #64):** extend cloud Routines beyond AI-news to (a) nightly corpus-quality
checks that auto-file issues, (b) scheduled SK corpus pre-translation (see #69), (c) a Sentry
crash digest. And make the GitHub mirror genuinely live so the local issue files (excellent,
AI-navigable) gain phone visibility without leaving the file-based system.

## Acceptance

- [ ] `launchctl print gui/502/com.quizagent.ralph-overnight` returns `state = waiting` on `mba`
- [ ] `git rev-list --count origin/main..main` returns 0 (after founder approval)
- [ ] GitHub Issues includes #59–#71
- [ ] A new `docs/research/ai-news-YYYY-MM-DD.md` (≥ 2026-06-21) confirms the routine is live
- [ ] Stale `.claude/scheduled_tasks.lock` removed
