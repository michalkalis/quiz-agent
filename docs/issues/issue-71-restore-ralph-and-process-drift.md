# Issue #71 — Process: restore Ralph scheduler, push held auth commits, refresh GitHub mirror

**Triage:** chore · reduced scope — GitHub mirror refresh only

**Note (2026-07-06):** gutted to the one surviving task — run `scripts/mirror-issues.sh` to refresh the stale GitHub Issues mirror. Ralph scheduler restore is CONTRADICTED by founder decision 2026-07-05 (no autonomous loops); push audit already resolved 2026-06-22; AI-news routine disabled 2026-06-25.

**Created:** 2026-06-21 · **Founder:** Michal · **Source:** #64 full-project review (rank 22 — confirmed)

**Severity:** medium — the autonomous-velocity flywheel that makes this project sustainable solo has stalled.

## Problem

The development-process automation (the project's strongest asset, scored 8/10) has drifted:

1. **Ralph overnight scheduler NOT LOADED** on `mba` since 2026-06-17 (per
   `memory/project_agent_mac_setup.md`), so queued issues (#59, #56) aren't running overnight.
2. ~~**~20 commits unpushed** on `main` — the entire #60 auth feature held pending push.~~
   **UPDATE 2026-06-22: resolved.** `origin/main` is now current (left/right count `0 1`) — the
   auth (#60) *and* #42 generation commits (`639ed89` 42.25 structured output, `42.28`, `42.29`)
   are all on the remote; only the #64 review-docs commit is local. The "20 unpushed" figure was
   measured 2026-06-21 against a stale tracking ref and no longer holds. Re-verify before acting.
3. **GitHub Issues mirror is stale** (highest mirrored is #58; #59–#63 and now #64–#71 missing).
   The dormant one-way mirror is the founder's phone-visibility channel.
4. **Cloud AI-news routine** produced its last digest `docs/research/ai-news-2026-06-16.md` (5+
   days). Stale `.claude/scheduled_tasks.lock` (2026-06-13) present.

## Evidence (verified first-hand 2026-06-21)

- `git rev-list --count origin/main..main` → **20** at review time (2026-06-21); **`0` behind / `1` ahead as of 2026-06-22** — auth + #42 work already on `origin/main`.
- `scripts/ralph/mirror-issues.sh` present (the mirror tool exists, just not run).
- `.claude/scheduled_tasks.lock` dated 2026-06-13.
- `docs/research/ai-news-2026-06-16.md` is the most recent digest.
- `memory/project_agent_mac_setup.md` records the `launchctl … NOT LOADED` check on 2026-06-17.

## Recommendation

1. ~~**[HUMAN]** SSH `mba` → `launchctl bootstrap gui/502 ~/Library/LaunchAgents/com.quizagent.ralph-overnight.plist`; confirm `state = waiting`.~~ — CONTRADICTED by founder decision 2026-07-05 (no autonomous loops)
2. ~~Push the held auth commits~~ — **done** (on `origin/main`, resolved 2026-06-22). Still pending before prod **deploy**: set `AUTH_JWT_SECRET` Fly secret + `alembic upgrade head` + `APP_ATTEST_REQUIRED=on` + `APP_ATTEST_APP_ID` (per #60/#65).
3. **Surviving task:** run `scripts/mirror-issues.sh` to bring the GitHub board current through #71.
4. ~~Remove the stale lock and confirm the cloud routine is live~~ — routine disabled 2026-06-25, moot.

**Opportunity (from #64):** extend cloud Routines beyond AI-news to (a) nightly corpus-quality
checks that auto-file issues, (b) scheduled SK corpus pre-translation (see #69), (c) a Sentry
crash digest. And make the GitHub mirror genuinely live so the local issue files (excellent,
AI-navigable) gain phone visibility without leaving the file-based system.

## Acceptance

- ~~[ ] `launchctl print gui/502/com.quizagent.ralph-overnight` returns `state = waiting` on `mba`~~ — CONTRADICTED by founder decision 2026-07-05 (no autonomous loops)
- [x] `git rev-list --count origin/main..main` ≈ 0 (auth/#42 already pushed; only review-docs may be local) — resolved 2026-06-22
- [ ] GitHub Issues includes #59–#71 — **surviving task: run `scripts/mirror-issues.sh` to refresh the stale GitHub Issues mirror**
- ~~[ ] A new `docs/research/ai-news-YYYY-MM-DD.md` (≥ 2026-06-21) confirms the routine is live~~ — routine disabled 2026-06-25
- ~~[ ] Stale `.claude/scheduled_tasks.lock` removed~~ — moot, routine disabled 2026-06-25
