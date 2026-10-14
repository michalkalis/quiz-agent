---
name: write-prd
description: Interactive PRD generator — asks discovery questions, then outputs structured PRD
allowed-tools: Read, Write, Glob, Grep, AskUserQuestion
model: sonnet
---

# Write PRD — Interactive Product Requirements Document

Generate a structured PRD through guided discovery. Ask questions first, then produce the document.

## Arguments

`$ARGUMENTS` — Feature name or brief description (e.g., "voice-based multiplayer quiz mode")

## Instructions

### Phase 1: Context Gathering

1. **Read existing project context**:
   - Read `CLAUDE.md` for project overview and architecture
   - Scan `docs/product/prds/` for existing PRDs to avoid duplication
   - If the feature touches iOS, scan `.claude/rules/ios.md` for constraints

2. **Ask 4-6 discovery questions** using AskUserQuestion. Ask ALL questions in a single message, not one at a time. Cover:
   - **Target user**: Who is this for? (drivers, passengers, admins?)
   - **Problem**: What pain point does this solve?
   - **Success criteria**: How will you measure success?
   - **Scope**: MVP vs full vision — what's the minimum viable version?
   - **Constraints**: Timeline, tech limitations, dependencies?
   - **Prior art**: Any inspiration from competitors or existing features?

### Phase 2: PRD Generation

3. **Generate the PRD** with this structure:

```markdown
# PRD: [Feature Name]

**Author:** [user] + Claude | **Date:** [today] | **Status:** Draft

## Problem Statement
[1-2 paragraphs from discovery answers]

## Goals & Success Metrics
- Goal 1 → Metric
- Goal 2 → Metric

## User Stories
| As a... | I want to... | So that... |
|---------|-------------|------------|
| ... | ... | ... |

## Scope

### In Scope (MVP)
- ...

### Out of Scope (Future)
- ...

## Technical Approach
[High-level architecture, key decisions, dependencies]

## Open Questions
- [ ] ...

## Timeline Estimate
| Phase | Description | Rough Size |
|-------|-------------|------------|
| 1 | ... | S/M/L |
```

4. **Save** to `docs/product/prds/[kebab-case-name].md`

5. **Report** the file path and a 2-line summary of what was captured.

## Notes

- If `$ARGUMENTS` is empty, ask the user what feature they want to spec out
- Reference existing codebase patterns when filling Technical Approach
- Keep the PRD concise — 1-2 pages, not a novel
