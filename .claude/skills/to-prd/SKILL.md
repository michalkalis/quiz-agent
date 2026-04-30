---
name: to-prd
description: Turn the current conversation into a PRD saved to docs/product/prds/<slug>.md and linked from docs/todo/TODO.md. Use when the user wants to crystallize a discussion into a product requirement doc — no interview, just synthesize what you already know.
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
model: sonnet
---

# /to-prd

Synthesize the current conversation context and codebase understanding into a PRD. **Do not interview the user** — read what's already been said and turn it into a doc. If something genuinely cannot be inferred, ask one targeted question rather than running a full grilling session.

For a discovery-style interview from a blank slate, use `/write-prd` instead.

## Conventions for this repo

- **PRDs live at** `docs/product/prds/<kebab-slug>.md`. Existing example: `docs/product/prds/mvp-launch.md`.
- **Domain language**: read `CONTEXT.md` at repo root before writing. Use those terms verbatim — don't drift into synonyms ("auto-confirm timer" not "automatic submission feature").
- **TODO link**: after writing the PRD, append a TODO line in `docs/todo/TODO.md` of the form `- [ ] #NN <one-line title> — [PRD](../product/prds/<slug>.md)` where `NN` continues the issue numbering (`ls docs/issues/issue-*-*.md | sort -V | tail -1` to find the highest).
- **Issue tracker**: there is no GitHub Issues for this repo. Triage state lives in the issue file's `**Triage:**` line and in TODO.md. See `.claude/skills/triage/SKILL.md`.

## Process

### 1. Read the room

Skim what's been discussed in this conversation. Identify:
- The user-facing problem
- Constraints, non-goals, and decisions already made
- Modules / files mentioned

Then read `CONTEXT.md` and skim any nearby PRDs (`ls docs/product/prds/`) to match tone and avoid duplicating scope.

### 2. Sketch the modules

Identify the major modules you'd build or modify. Actively look for **deepening opportunities** — places where a deep module hides a lot of behavior behind a small interface (see `.claude/skills/improve-codebase-architecture/LANGUAGE.md` for the vocabulary).

Show the module sketch to the user. Two questions, max:
- Do these modules match your expectations?
- Which of them do you want test coverage on?

Skip the questions if the conversation already answered them.

### 3. Write the PRD

Use the template below. Save to `docs/product/prds/<slug>.md`. Add the TODO line. Link the PRD from the line.

The PRD's **Triage** state starts as `needs-triage` until the user confirms direction.

## PRD template

```markdown
# PRD: <Title>

**Author:** <user> + Claude | **Date:** <YYYY-MM-DD> | **Status:** Draft
**Triage:** enhancement · needs-triage

## Problem Statement

The problem the user is facing, from the user's perspective.

## Solution

The solution from the user's perspective.

## User Stories

A long, numbered list. Each: `As a <actor>, I want <feature>, so that <benefit>`.

Cover the full feature, including edge cases and error paths.

## Implementation Decisions

- Modules to build / modify (use CONTEXT.md vocabulary)
- Interfaces of those modules
- Architectural decisions
- Schema changes / API contract changes
- Specific interactions

Do **not** include file paths or code snippets — they go stale.

## Testing Decisions

- What makes a good test for this work (test external behavior, not internals)
- Which modules will get tests
- Prior art in the codebase for similar tests

## Out of Scope

What is explicitly *not* part of this PRD.

## Further Notes

Open questions, ADR pointers, related PRDs/issues.
```

## After writing

Print one line:
```
PRD: docs/product/prds/<slug>.md  (TODO #NN added)
```

Then offer: "Want me to break this into vertical-slice issues now?" If yes, draft `docs/issues/issue-NN-<slug>.md` files (one per slice) and update the TODO.
