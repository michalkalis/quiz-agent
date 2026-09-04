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

Fly tokens are **app-scoped** (2026-09-04): using the wrong one fails with `Error: unauthorized`. Without any token (`env -u FLY_API_TOKEN`) flyctl falls back to the founder's `flyctl auth login`. Always deploy from a checkout of `origin/main` (use a worktree if the shared checkout is on another branch).

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

### 4. Run the target's tests (unless `--skip-tests`)
```bash
cd <App dir> && uv run --no-sync pytest tests/ -x -q --tb=short -m "not integration" 2>&1
```
- `backend` → `apps/quiz-agent`; `pack-api` → `apps/quiz-pack-api`; `both` → run each suite before its own deploy.
- If tests fail, **stop deployment of that target** and report failures.
- If no tests exist, note this and continue.

### 5. Check fly CLI is available
```bash
fly version 2>/dev/null
```
- If `fly` is not installed, report and stop.

## Deploy

Load the token for the target, then deploy its `fly.toml`:

```bash
cd "$CLAUDE_PROJECT_DIR" && set -a && source .env && set +a && \
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
- Every process in the target's **Processes** column must be `started` (for `pack-api` that is both `web` and `worker`); a missing or stopped process is a failed deploy — report it, never a green.

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
