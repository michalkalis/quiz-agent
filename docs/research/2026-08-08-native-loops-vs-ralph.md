# Native Claude Code loops vs Ralph (2026-08-08)

Research: can native loop features replace the hand-rolled overnight agent loop ("Ralph") on `mba`?
Verified against official docs (code.claude.com/docs) and the claude-code changelog, 2026-08-08.

## Current Ralph architecture

- `overnight.sh` + `ralph.sh` on `mba`: per-iteration `claude -p` calls with `gtimeout` caps, checkbox-driven task pick from a focus file, model router, HTML report, pushes `ralph/*` branch only.
- Scheduling: launchd LaunchAgents (`com.quizagent.ralph72` etc., currently disabled) with a hand-rolled window guard, wall-clock cutoff, and lock files.
- Launch: ssh + tmux send-keys into the gui-domain (Keychain gotcha), `--permission-mode auto` (founder rule: never bypass), one-shot laptop supervision.
- Known failure modes: orphaned xcodebuild wedges, guard false-trips, 0-commit iterations, shared-checkout phantom commits.

## What native features could replace which piece

| Ralph piece | Native replacement | Status |
|---|---|---|
| `ralph.sh` iteration loop + "is it done?" checkbox logic | `/goal <condition>` (v2.1.139+): Haiku evaluator checks the condition after every turn, keeps working until met; works headless (`claude -p "/goal ..."`), pairs with auto mode for unattended turns; condition can embed a turn/time bound ("or stop by 05:30") | Adopt |
| `gtimeout` per-iteration caps | No direct equivalent; bound via the /goal condition clause + session limits. Orphan-proc risk unchanged (goal turns still spawn xcodebuild) | Partial |
| launchd scheduler + window guard | Desktop scheduled tasks (Desktop app, local machine, per-task permission mode + always-allow list, catch-up on wake, 1-min granularity, optional per-run worktree) — mba is GUI-logged-in so this fits. Or `/loop` inside a live tmux session (session-scoped, 7-day expiry, fires only while session open) | Pilot |
| Overnight cadence for non-iOS work (backend, docs, triage, question gen review) | Cloud routines `/schedule` (research preview, **available on Pro/Max**, min 1 h, runs autonomously with no permission prompts, fresh GitHub clone, `claude/` branches, daily run cap) | Adopt for backend-only jobs |
| "sequential or worktrees" manual rule | Native worktree isolation: `--worktree`, `EnterWorktree`, subagent `isolation: worktree`; Claude Code now **enforces** it — blocks edits/Bash cwd/git redirects into the main checkout, incl. subagents (hardened 2.1.214/2.1.216/2.1.222); auto-cleanup sweep, `.worktreeinclude` for `.env` | Adopt (file safety); iOS caveats below |
| "auto mode, never bypass" founder rule | Now the sanctioned path: auto mode becomes the **default** permission mode on Pro/Max/Team from 2026-08-14; classifier blocks irreversible/destructive/exfil actions; docs explicitly recommend `/goal` + auto mode for unattended runs; tunable via `autoMode.environment` / `soft_deny` / `permissions.ask` (e.g. keep an ask-gate on `git push` if desired) | Already aligned |
| Laptop-side supervision (one-shot capture-pane) | Unchanged; classifier still blocks unattended laptop polling loops (observed 2026-07-21). Monitor tool / Channels are the token-efficient alternatives inside the run itself | Keep |

`/loop` details: `/loop 5m <prompt>` = fixed cron (1-min min); no interval = self-paced (Claude picks 1 min–1 h delay per iteration, can stop itself via `ScheduleWakeup stop:true`); bare `/loop` runs a built-in maintenance prompt or your `.claude/loop.md`. Tasks are session-scoped, expire after 7 days, and only fire while the session is open and idle.

**"Proactive loops": no such named feature exists** in official docs or changelog. Closest real things: bare `/loop` maintenance prompt, self-paced intervals, and the Monitor tool. Treat third-party posts using the phrase as marketing.

## What CANNOT be replaced yet

- **Self-hosted runners (2.1.224, public beta) are Team/Enterprise only.** Confirmed in docs: "public beta on Team and Enterprise plans", enabled by an org admin in claude.ai admin settings; ZDR excluded; inference cannot route via Bedrock. A solo Pro/Max user **cannot** point cloud-triggered sessions at their own Mac. Docs' stated Pro/Max alternative for "your own always-on machine": Remote Control (already running on mba).
- **Cloud routines can't do iOS.** Anthropic-hosted runners are Linux; no Xcode/simulators. Routines also start from a fresh clone (no local state) and route only to GitHub. So the mba iOS leg stays local regardless.
- **iOS builds in worktrees — gotchas (reasoning, not doc-verified):** DerivedData is keyed by project path, so each worktree cold-builds (~minutes/worktree, disk growth); signing is Keychain-level and unaffected; gitignored xcconfig/`.env` need `.worktreeinclude`. **Simulators are a machine-global resource** — worktrees isolate files, not sims; parallel sim test runs still conflict (matches our two-booted-sims wedge history). Keep iOS sim work sequential; worktrees only remove the *file/git* collision class (the 2026-07-03 phantom-commit incident).
- **No native wall-clock kill or orphan reaper.** `/goal` has no hard timeout; a wedged xcodebuild grandchild still needs `gtimeout -k`/guard-style defenses. The 05:30 cutoff must live in the goal condition + an external kill.
- **Session usage limits still cap overnight throughput.** `/goal` runs within one session; the ~5 h window cap that motivated the multi-window launchd hack is unchanged. A goal survives `--resume`, but something must issue the resume (Desktop scheduled task or a thin cron/launchd remnant). Unverified: exact /goal behavior when the usage limit hits mid-run.
- **Routines caveats:** research preview (API/limits may change), daily run cap per account, min interval 1 h, runs act as your GitHub identity, connectors default-included (prune them).

## Recommendation: pilot now, in two tracks

Native features replace Ralph's *engine* (iteration loop, done-check, permission stance, worktree safety) but not its *host-side plumbing* (wall-clock kill, orphan reaper, session-limit bridging) or the iOS/simulator constraints.

1. **Adopt immediately (no risk):** auto mode stays the stance (now sanctioned + default from 08-14; consider `permissions.ask` on `git push` for overnight runs). Use `isolation: worktree` for any parallel subagent work; keep iOS sim runs sequential.
2. **Pilot A — /goal as the Ralph engine (1 overnight run):** same tmux gui-domain launch on mba, but replace `ralph.sh` iterations with one process: `claude --permission-mode auto -p "/goal <issue done-state incl. tests green> or stop after N turns or by 05:30" --output-format stream-json --verbose > run.log`. Keep a thin `gtimeout -k` wrapper as orphan insurance. Success = commits land, no wedge, cost comparable; then retire ralph.sh's loop/router/report for single-issue runs.
3. **Pilot B — cloud routine for one backend-only job** (e.g. nightly backend-test + triage summary, or question-batch verify): create via `/schedule`, Default trusted-network env, prune connectors. Zero mba involvement; validates the daily-cap and autonomy model.
4. **Wait:** self-hosted runners (plan-gated), routines for anything iOS, Desktop-scheduled-tasks-as-scheduler on mba (needs Desktop app installed there; evaluate after Pilot A shows /goal viability).

## Sources

- /goal: https://code.claude.com/docs/en/goal
- /loop + scheduling comparison: https://code.claude.com/docs/en/scheduled-tasks
- Routines (/schedule): https://code.claude.com/docs/en/routines
- Desktop scheduled tasks: https://code.claude.com/docs/en/desktop-scheduled-tasks
- Worktrees + isolation enforcement: https://code.claude.com/docs/en/worktrees
- Auto mode config + classifier: https://code.claude.com/docs/en/auto-mode-config
- Self-hosted environments (plan gating): https://code.claude.com/docs/en/self-hosted-environments
- Changelog (2.1.210–2.1.224 hardening, self-hosted-runner intro): https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md
