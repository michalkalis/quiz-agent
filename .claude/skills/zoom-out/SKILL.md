---
name: zoom-out
description: Tell the agent to zoom out and give broader context or a higher-level perspective on a section of code. Use when you're unfamiliar with an area of the codebase and need a map of modules and callers before diving in.
disable-model-invocation: true
model: sonnet
---

# /zoom-out

I don't know this area of code well. Go up a layer of abstraction.

Give me a map of:

1. **The relevant modules** — what they're called, what each one is responsible for, where they live.
2. **The callers** — who uses each module and through which interface.
3. **The seams** — where you'd cut for testing or substitution (terms from `.claude/skills/improve-codebase-architecture/LANGUAGE.md`).
4. **Related domain concepts** — use the vocabulary in `CONTEXT.md` at repo root. If a term in the area isn't in `CONTEXT.md` yet, flag it ("`<term>` is used here but not defined in CONTEXT.md — propose definition?").

Keep it concise. Names and one-line descriptions. Don't reproduce the code.

If the area touches an active PRD (`docs/product/prds/`) or an open issue (`docs/issues/issue-NN-*.md`), surface those at the end.
