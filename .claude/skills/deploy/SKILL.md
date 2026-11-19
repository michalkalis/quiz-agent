---
name: deploy
description: Deploy the backend to the Hetzner production server (Backend Deploy workflow, or deploy-ssh.sh by hand in an emergency) with checks, post-deploy verification and rollback
model: haiku
allowed-tools: Bash, Read
argument-hint: "[backend|pack-api|both]"
---

# Deploy to Hetzner

Production runs on one Hetzner server (`trubbo-prod`, since 2026-11-06, #222 — moving the backend to Hetzner; [`infra/hetzner/README.md`](../../../infra/hetzner/README.md)). Every step below is keyed on the **target**.

> **Never `fly deploy` the app configs** (`apps/quiz-agent/fly.toml`, `apps/quiz-pack-api/fly.toml`) and never `fly deploy --image` on `quiz-agent-api` / `quiz-pack-api`. Those Fly apps now run only the forwarder (`infra/fly-forwarder/`) that passes `*.fly.dev` traffic from build 1.1, Apple and RevenueCat to the server. A Fly deploy replaces it with the old app, which still talks to the old Fly database: purchases and progress land where prod no longer reads. `fly status` / `fly logs` on those apps show only the forwarder. The only exception is the **Back** path of [`docs/setup/hetzner-cutover.md`](../../../docs/setup/hetzner-cutover.md), a founder decision.

## Targets

| Target (arg) | Workflow `apps` input | deploy-ssh services | Smoke |
|---|---|---|---|
| `backend` (default) | `quiz-agent` | `quiz-agent` | `infra/deploy/smoke.sh quiz-agent https://api.trubbo.app` |
| `pack-api` | `quiz-pack-api` | `pack` (web; the worker restarts too if it runs) | `infra/deploy/smoke.sh quiz-pack-api https://pack.trubbo.app` |
| `both` | `both` | `quiz-agent,pack` | both of the above |

## Normal path: the Backend Deploy workflow

```bash
gh workflow run backend-deploy.yml --ref main -f apps=<Workflow apps input>
```

It runs the full Backend CI, then one SSH forced command on the server (`infra/hetzner/deploy-ssh.sh`): lock, build, `alembic upgrade head` before the swap, restart, wait up to 120 s for health, and on failure an automatic rollback to the previous sha without migrating. Then it smoke-tests both domains and checks the pack worker heartbeat. A failure opens a `deploy-failed` issue. Prod deploys only from `main`; Hetzner has no staging stage, so a branch ref only runs the tests. Watch it with `gh run watch`.

## Manual emergency path (GitHub Actions down)

Only when the workflow cannot run. Needs the server login (`ssh trubbo-prod`, key `~/.ssh/trubbo_hetzner`).

1. **Commit:** the full 40-char sha of `origin/main` (`git fetch origin main && git rev-parse origin/main`). The script refuses short shas and anything not on `origin/main`.
2. **Test gate:** that exact commit must have a green **Backend CI** run:
   ```bash
   gh run list --commit <sha> --json name,conclusion,status --jq '.[] | "\(.name): \(.status) \(.conclusion)"'
   ```
   Require `Backend CI: completed success`. Still running → wait; failed or absent → stop and report.
3. **Deploy** (on the server; the same script and lock CI uses, so the two cannot overlap):
   ```bash
   ssh trubbo-prod
   SSH_ORIGINAL_COMMAND="deploy <sha> <deploy-ssh services>" ~/trubbo/bin/deploy-ssh.sh
   ```
   It ends with `OK: <sha> live`, or `rolled back to <prev> (<sha> was NOT deployed)`, or `ROLLBACK ALSO FAILED: inspect the server`. Only the first is a success.
4. This does not move the `deployed/<app>` tags, so the next workflow run may redeploy the same code once (harmless).

## Post-deploy verification

1. Smoke test for the target (table above). Expect it to pass.
2. Server state, in `~/trubbo/repo/infra/hetzner`: `docker compose ps` (touched services up and `healthy`; `pack-worker` up if it ran before) and `git -C ~/trubbo/repo rev-parse HEAD` = the deployed sha.
3. `pack-api`: the worker heartbeat must be newer than the deploy: `curl -fsS -H "X-Admin-Key: $PACK_KEY" https://pack.trubbo.app/api/v1/admin/worker/heartbeat` → `heartbeat_age_s` a number within ~1 min. A missing heartbeat is a failed deploy, never a green.

## Report

One block per target:
```
DEPLOYMENT SUMMARY — <target>
Commit:   <short sha> <message>
Path:     workflow <run URL> | manual deploy-ssh
Deploy:   <OK live / rolled back / rollback failed>
Smoke:    <pass/fail>
Worker:   <heartbeat age, pack-api only>
```

## Rollback

Never `alembic downgrade` the prod DB. Migrations are expand-only and the apps accept a DB ahead of their code, so roll back by running the previous code **without migrating** (see `.claude/rules/backend.md`).

- **The deploy step itself failed:** deploy-ssh.sh already rolled back (log line `rolled back to …`). Nothing to do but find the cause. On `ROLLBACK ALSO FAILED`, continue with the manual rollback below.
- **The new code is live but bad** (smoke or worker step red, or a problem found later): fix forward through the workflow when there is time. To go back right away, on the server, with the last good sha (the tag `deployed/<app>` moves only after a green smoke, so it is the last good code unless someone deployed by hand):
  ```bash
  ssh trubbo-prod
  cd ~/trubbo/repo/infra/hetzner
  git -C ~/trubbo/repo checkout -q --detach <good sha>
  docker compose build <services>        # quiz-agent and/or pack-web
  docker compose up -d <services>
  docker compose --profile worker up -d pack-worker   # pack-api only, if the worker was running
  docker compose ps
  ```
  This is what deploy-ssh.sh's own rollback does (build and restart, no migration). Do **not** use `deploy <older sha>` for this when the bad release shipped a migration: that path runs `alembic upgrade head` with the older code, which fails on the unknown revision and then "rolls back" to the bad sha.
- Afterwards rerun Post-deploy verification and report.
