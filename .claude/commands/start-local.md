# Start Local Development

Start the backend API and/or web UI for local development.

## Instructions

Based on $ARGUMENTS, start the appropriate services:

### "backend" or "api" or no argument
Start the backend API server:
```bash
cd apps/quiz-agent && uvicorn app.main:app --reload --port 8002
```
Verify it's running: `curl http://localhost:8002/docs`

### "web" or "ui"
Start the web UI:
```bash
cd apps/web-ui && npm run dev
```

### "all" or "both"
Start both backend and web UI in separate processes.

### "questions" or "generator"
Start the question generator service:
```bash
cd apps/question-generator && uvicorn app.main:app --reload --port 8003
```

After starting, confirm the service is running and report the URL.
