---
name: deploy
description: Deploy backend to Fly.io with pre-flight checks and post-deploy verification
model: haiku
allowed-tools: Bash, Read
argument-hint: "[backend|pack-api|both] [--skip-tests] [--dry-run]"
---

# Deploy to Fly.io

Guided deployment with safety checks. Two deployable apps; every step below is keyed on the **target**.

## Targets

| Target (arg) | App dir | Fly app | Token env var (repo-root `.env`) | Health URL | Processes |
|---|---|---|---|---|---|
| `backend` (default) | `apps/quiz-agent` | `quiz-agent-api` | `FLY_API_TOKEN` | `https://quiz-agent-api.fly.dev/api/v1/health` | `app` |
| `pack-api` | `apps/quiz-pack-api` | `quiz-pack-api` | `FLY_API_TOKEN_QUIZ_PACK_API` | `https://quiz-pack-api.fly.dev/health` | `web` + `worker` |
| `both` | run `backend`, then `pack-api` — each with its own pre-flight tests, deploy, and verification | | | | |

Fly tokens are **app-scoped** (2026-09-04): using the wrong one fails with `Error: unauthorized`. Without any token (`env -u FLY_API_TOKEN`) flyctl falls back to the founder's `flyctl auth login`. Always deploy from a checkout of `origin/main`. If the shared checkout (`$CLAUDE_PROJECT_DIR`) is on another branch or dirty, create a throwaway worktree and deploy from it:

```bash
git -C "$CLAUDE_PROJECT_DIR" fetch origin main
git -C "$CLAUDE_PROJECT_DIR" worktree add --detach "$CLAUDE_PROJECT_DIR/.claude/worktrees/deploy-main" origin/main
DEPLOY_DIR="$CLAUDE_PROJECT_DIR/.claude/worktrees/deploy-main"   # otherwise DEPLOY_DIR="$CLAUDE_PROJECT_DIR"
```

Remove it afterwards (`git worktree remove --force <path>`). `.env` is gitignored and lives only in the shared checkout, so it is always sourced by absolute path from `$CLAUDE_PROJECT_DIR`.

## Pre-flight Checks (always run, per target)

Run all checks before deploying. Stop and report if any fail.

### 1. Git status
```bash
git status --porcelain
```
- If there are uncommitted changes, **warn the user** and ask whether to proceed.
- Report the current branch name.

### 2. Branch check
```bash
git branch --show-current
```
- If on `main` or `master`, proceed (deploying from main is expected).
- If on a feature branch, **warn** that deploying from a non-main branch is unusual and ask to confirm.

### 3. Remote sync
```bash
git log origin/$(git branch --show-current)..HEAD --oneline 2>/dev/null
```
- If there are unpushed commits, **warn** that local changes haven't been pushed to remote.

### 4. Test gate (unless `--skip-tests`)
The deployed commit must have a green **Backend CI** run (it runs both app suites, path-filtered):
```bash
gh run list --commit "$(git -C "$DEPLOY_DIR" rev-parse HEAD)" --json name,conclusion,status --jq '.[] | "\(.name): \(.status) \(.conclusion)"'
```
- Require `Backend CI: completed success` for that exact commit. Still running → wait for it; failed or absent → **stop deployment of that target** and report.
- Do not run pytest inside a fresh worktree (no `.venv` there, and the repo-root build is flaky under `uv sync`). A local run is only meaningful from the shared checkout on `main`: `cd "$CLAUDE_PROJECT_DIR/<App dir>" && uv run --no-sync pytest tests/ -x -q --tb=short -m "not integration"`.

### 5. Check fly CLI is available
```bash
fly version 2>/dev/null
```
- If `fly` is not installed, report and stop.

## Deploy

Load the token for the target, then deploy its `fly.toml`:

```bash
cd "$DEPLOY_DIR" && set -a && source "$CLAUDE_PROJECT_DIR/.env" && set +a && \
  FLY_API_TOKEN="$<Token env var>" fly deploy -c <App dir>/fly.toml --yes
```

- `backend`: `FLY_API_TOKEN="$FLY_API_TOKEN" fly deploy -c apps/quiz-agent/fly.toml --yes`
- `pack-api`: `FLY_API_TOKEN="$FLY_API_TOKEN_QUIZ_PACK_API" fly deploy -c apps/quiz-pack-api/fly.toml --yes`

### `--dry-run`
Same command with `--build-only` (builds the image for the chosen target, deploys nothing). Skip post-deploy verification.

## Post-deploy Verification (per target)

After each successful deploy:

### 1. Health check
```bash
curl -s -o /dev/null -w '%{http_code}' <Health URL>
```
- Expect HTTP 200. Retry up to 3 times with 10s between attempts (app needs ~8s to start).

### 2. Smoke test
```bash
curl -s https://<Fly app>.fly.dev/docs | head -c 100
```
- Verify the docs page loads.

### 3. Check deployment status
```bash
fly status -a <Fly app>
```
- Every process in the target's **Processes** column must exist on the new version. `app` / `web` scale to zero (`min_machines_running = 0`), so `stopped` right after a deploy is normal idle — the health check above auto-starts them and is the real signal. `worker` (`pack-api`) has no HTTP service and must be `started`; a missing or stopped `worker` is a failed deploy — report it, never a green.

## Report

One block per deployed target:
```
DEPLOYMENT SUMMARY — <Fly app>
─────────────────
Branch:     <branch>
Commit:     <short hash> <message>
Tests:      <passed/skipped/failed>
Deploy:     <success/failed>
Health:     <HTTP status>
Processes:  <started list>
URL:        https://<Fly app>.fly.dev
```
