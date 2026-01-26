---
name: test-backend
description: Run backend pytest suite. Use after Python code changes.
disable-model-invocation: true
allowed-tools: Bash
model: haiku
argument-hint: "[all|specific-test-file|--verbose]"
---

# Run Backend Tests

Run pytest for the quiz-agent backend.

## Based on $ARGUMENTS:

### No argument or "all"
Run full test suite:
```bash
cd apps/quiz-agent && python -m pytest tests/ -v --tb=short
```

### Specific test file
```bash
cd apps/quiz-agent && python -m pytest tests/$ARGUMENTS -v --tb=short
```

### "--verbose" or "-v"
Run with full output:
```bash
cd apps/quiz-agent && python -m pytest tests/ -v --tb=long
```

## Report
- Total tests run
- Passed / Failed / Skipped count
- Details of any failures
- Suggest fixes if tests fail

## Note
If no tests exist yet, report that and suggest creating `apps/quiz-agent/tests/conftest.py` with proper fixtures.
