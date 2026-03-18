---
name: deploy
description: Deploy backend to Fly.io with pre-flight checks and post-deploy verification
model: haiku
allowed-tools: Bash, Read
argument-hint: "[backend|--skip-tests|--dry-run]"
---

# Deploy to Fly.io

Guided deployment with safety checks for the quiz-agent backend.

## Pre-flight Checks (always run)

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

### 4. Run backend tests (unless `--skip-tests`)
```bash
cd apps/quiz-agent && python -m pytest tests/ -x -q --tb=short 2>&1
```
- If tests fail, **stop deployment** and report failures.
- If no tests exist, note this and continue.

### 5. Check fly CLI is available
```bash
fly version 2>/dev/null
```
- If `fly` is not installed, report and stop.

## Deploy

### Default or "backend"
```bash
cd /Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent && fly deploy -c apps/quiz-agent/fly.toml
```

### "--dry-run"
Show what would be deployed without actually deploying:
```bash
cd /Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent && fly deploy -c apps/quiz-agent/fly.toml --build-only
```
Skip post-deploy verification.

## Post-deploy Verification

After a successful deploy:

### 1. Health check
```bash
curl -s -o /dev/null -w '%{http_code}' https://quiz-agent-api.fly.dev/api/v1/health
```
- Expect HTTP 200. Retry up to 3 times with 10s between attempts (app needs ~8s to start).

### 2. Smoke test
```bash
curl -s https://quiz-agent-api.fly.dev/docs | head -c 100
```
- Verify the docs page loads.

### 3. Check deployment status
```bash
fly status -a quiz-agent-api
```

## Report

Provide a summary:
```
DEPLOYMENT SUMMARY
─────────────────
Branch:     <branch>
Commit:     <short hash> <message>
Tests:      <passed/skipped/failed>
Deploy:     <success/failed>
Health:     <HTTP status>
URL:        https://quiz-agent-api.fly.dev
```
