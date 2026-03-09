---
name: user-stories
description: Generate user stories with acceptance criteria from a feature description
allowed-tools: Read, Write, Glob, Grep
model: sonnet
---

# User Stories Generator

Generate structured user stories with Given/When/Then acceptance criteria.

## Arguments

`$ARGUMENTS` — Feature name or description (e.g., "daily challenge feature")

## Instructions

1. **Gather context**:
   - Read `CLAUDE.md` for project overview
   - Check `docs/product/prds/` for a related PRD — if one exists, use it as input
   - Scan existing stories in `docs/product/stories/` to avoid duplicates

2. **Identify personas** relevant to this feature from the CarQuiz context:
   - **Driver** — Primary user, hands-free interaction
   - **Passenger** — Secondary user, can use touch
   - **Admin** — Question management, analytics
   - Add others if the feature requires them

3. **Generate stories** using this format for each:

```markdown
### [STORY-NNN] [Title]

**As a** [persona],
**I want to** [action],
**So that** [benefit].

**Acceptance Criteria:**
- **Given** [precondition], **When** [action], **Then** [expected result]
- **Given** [precondition], **When** [action], **Then** [expected result]

**Priority:** Must / Should / Could
**Size:** S / M / L
```

4. **Organize** stories by priority (Must → Should → Could)

5. **Save** to `docs/product/stories/[kebab-case-feature].md` with a header:

```markdown
# User Stories: [Feature Name]

**Generated:** [today] | **Related PRD:** [link if exists]
**Total:** N stories (X must, Y should, Z could)
```

6. **Report** file path and story count summary.

## Notes

- If `$ARGUMENTS` is empty, ask what feature to write stories for
- Aim for 5-12 stories per feature (enough coverage, not exhaustive)
- Each story should be independently deliverable
- Include at least one edge case / error scenario story
