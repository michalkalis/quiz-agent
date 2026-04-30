---
name: summarize
description: Generate a copy-pasteable handoff plan for resuming the current task in a fresh session.
disable-model-invocation: true
allowed-tools: Read, Bash, Grep, Glob
model: sonnet
---

# Summarize for Handoff

Output a self-contained block the user can paste into a new Claude Code session to continue the current task without re-explaining context.

## Gather signals (in parallel where possible)

- `git status --short` and `git diff --stat`
- `git log --oneline -15`
- Read `docs/todo/TODO.md` — find any `[~]` (wip) item
- Skim the conversation: what was the user trying to do, what's done, what's pending, what's blocked

## Pick the active task

In order of preference:
1. The `[~]` item in TODO.md
2. The task implied by the current diff (most-changed file area)
3. Ask the user to pick if there's no clear signal

## Print the handoff block

A single fenced block the user can copy. Keep it under ~30 lines. Drop sections that don't apply.

````
Continue work on #N: {title}.

Goal: {one sentence — what "done" looks like}

Done so far:
- {commit subject or completed step}
- ...

Next:
1. {concrete next action}
2. ...

Key files:
- path/to/file.ext:LINE — what's there
- ...

Start by: {exact command or first read — e.g. "run /test-ios", "read docs/issues/issue-N.md"}

Plan file: docs/issues/issue-N-{slug}.md  (omit if none)
````

## Rules

- Read-only — do not modify TODO.md or any other file from this skill.
- Cite real file paths and line numbers, not placeholders.
- If the active task has a plan file in `docs/issues/`, the handoff block should point to it as the primary source of truth.
