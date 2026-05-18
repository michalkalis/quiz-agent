---
name: handoff
description: Write a structured handoff doc to docs/handoffs/handoff-YYYY-MM-DD-HHMM.md so a fresh session can resume the current work without re-explaining context. Use when the user wants to save state before ending a session, when context is filling up, or when explicitly invoked.
disable-model-invocation: true
allowed-tools: Read, Bash, Grep, Glob, Write, Edit
model: sonnet
---

# Handoff

Write a checked-in markdown file at `docs/handoffs/handoff-$(date +%Y-%m-%d-%H%M).md` that captures everything a fresh Claude Code session needs to pick up where this one left off.

This is the **file-on-disk** counterpart to `/summarize` (which prints a one-shot copy-pasteable block). Use `/handoff` when the work is incomplete and you want a durable record committed to the repo.

## Gather signals

Run in parallel where possible:
- `git status --short` and `git diff --stat`
- `git log --oneline -15` and `git log --oneline main..HEAD` if on a branch
- `git branch --show-current`
- Read `docs/todo/TODO.md` — find any `[~]` (wip) item
- If a `docs/issues/issue-NN-*.md` is referenced from TODO or recent commits, read it
- Skim the conversation: what did the user actually ask for, what's done, what's pending, what's blocked, what decisions were made and why

## Determine the file path

```
docs/handoffs/handoff-$(date +%Y-%m-%d-%H%M).md
```

If `docs/handoffs/` doesn't exist, create it. If a handoff file already exists for the current minute, append `-2`, `-3`, etc.

## Write the handoff

Use exactly this structure. Drop a section only if it genuinely doesn't apply (e.g. "Blockers: none"). Keep prose tight — bullets > paragraphs except in Recap.

```markdown
# Handoff YYYY-MM-DD HH:MM

## Recap

One paragraph. What was accomplished this session, in plain terms. Mention issue numbers, file moves, deploys, and anything that touches prod.

## Current task

What you were working on and exactly where you left off (file path + line number where applicable). Reference the plan file (`docs/issues/issue-NN-*.md`) if one exists.

## Next steps

1. First concrete action (command or file:line, not "investigate X")
2. Second
3. Third (cap at ~3 — more than that and the next session should re-plan)

## Key files touched

Created:
- `path/to/new/file` — one-line purpose

Modified:
- `path/to/existing/file` — what changed and why

Memory updated (if applicable):
- `feedback_*.md` / `project_*.md` — what was added or changed

## Decisions

Non-obvious choices made and their rationale. The point of this section is preventing the next session from re-litigating settled questions. Skip the obvious; capture the surprising.

## Blockers / open questions

Anything unresolved, awaiting a human, or blocked on an external system. If none, say "None."

## Resume context

- **Branch:** current branch and whether it's pushed
- **Commits this session:** list of short SHAs + subjects
- **Live services touched:** URLs, ports, DB names — anything the next session will hit
- **Local dev stack:** commands to bring it up if needed
- **Secrets/env vars:** what's set where (never echo values)
- **Memory notes that matter for next steps:** point to `feedback_*` / `project_*` entries the next session should re-read before acting
```

## After writing

1. If the work is incomplete and there's no existing `[~]` entry in `docs/todo/TODO.md` for it, append a one-liner:
   ```
   - [~] Continue {task} — see docs/handoffs/handoff-YYYY-MM-DD-HHMM.md
   ```
2. Reply to the user with **just** the handoff path (one line, no preamble), so they can paste `Read docs/handoffs/handoff-...md and continue` into a fresh session.

## Rules

- **Cite real paths and line numbers**, never placeholders.
- **Don't echo secrets** — refer to them by env var name and where they're stored (e.g. "Fly secret on quiz-pack-api: `OPENAI_API_KEY`"). The handoff is committed to the repo.
- **Don't summarize what's already in CLAUDE.md or memory.** The handoff is for *this session's state*, not project-wide knowledge.
- **Don't speculate about next steps you haven't thought through.** Three solid next steps beat seven hand-wavy ones.
- **One file per invocation.** If the user runs `/handoff` twice in the same minute, suffix `-2`.
- **Read-only on git.** Never commit, push, or stash from this skill.
