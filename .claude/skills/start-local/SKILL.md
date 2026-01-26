---
name: start-local
description: Start backend API, web UI, or question generator for local development
disable-model-invocation: true
allowed-tools: Bash
argument-hint: "[backend|web|questions|all]"
---

# Start Local Development

Based on $ARGUMENTS, start the appropriate services.

## Pre-flight checks

Before starting any Python service:

1. **Check `.env` file exists** at the repo root. If missing, warn the user that `OPENAI_API_KEY` and other secrets won't be available and ask whether to proceed.
2. **Check if the target port is already in use** with `lsof -ti :<port>`. If occupied, report the PID and ask the user whether to kill it before starting.

## "backend" or "api" or no argument

Port: **8002**

```bash
cd apps/quiz-agent && uv run uvicorn app.main:app --reload --port 8002
```

Run in background. Verify with: `curl -s -o /dev/null -w '%{http_code}' http://localhost:8002/docs` (expect 200).

## "web" or "ui"

Port: **3000**

```bash
cd apps/web-ui && npm run dev
```

## "questions" or "generator"

Port: **8003**

```bash
cd apps/question-generator && uv run uvicorn app.main:app --reload --port 8003
```

Run in background. Verify with: `curl -s -o /dev/null -w '%{http_code}' http://localhost:8003/docs` (expect 200).

## "all"

Start backend (port 8002) in background, then question generator (port 8003) in background, then web UI. Run pre-flight checks for all ports before starting any service.

## After starting

Confirm each service is running and report its URL. If a service fails to start, check the background task output for errors and report them.
