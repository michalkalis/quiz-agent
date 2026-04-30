# Out-of-Scope Knowledge Base

The `.out-of-scope/` directory at repo root stores persistent records of rejected feature requests. Two purposes:

1. **Institutional memory** — why a feature was rejected, so the reasoning isn't lost when the issue is closed.
2. **Deduplication** — when a new issue comes in matching a prior rejection, the skill surfaces the previous decision instead of re-litigating it.

Lazy-create the directory the first time `/triage` decides an enhancement is `wontfix`.

## Directory structure

```
.out-of-scope/
├── multiplayer-mvp.md
├── android-port.md
└── community-question-submission.md
```

One file per **concept**, not per issue. Multiple issues requesting the same thing are grouped under one file.

## File format

Written in a relaxed, readable style — more like a short design note than a database entry. Paragraphs, code samples, examples.

```markdown
# Multiplayer in MVP

This project does not support multiplayer in MVP. Multiplayer is a
post-MVP goal (see `project_product_vision` memory).

## Why this is out of scope

The MVP targets the founder and close circle for road-trip trivia. Voice
turn-taking across multiple participants requires:

- Per-participant identification + voice-print
- Score arbitration and turn ordering
- Lobby / pairing flow
- Backend session state for N participants

This is significantly more surface area than the single-player voice loop
the MVP is validating. Adding it now would dilute the validation signal —
we want to confirm the single-player loop works before layering coordination.

Post-MVP this becomes a primary roadmap item once the founder + circle
have validated the core experience.

## Prior requests

- (none yet)
```

### Naming the file

Short, descriptive, kebab-case: `multiplayer-mvp.md`, `android-port.md`. Recognizable enough that someone browsing the directory knows what was rejected without opening the file.

### Writing the reason

Substantive — not "we don't want this" but **why**. Good reasons reference:

- Project scope or philosophy ("MVP focuses on validating single-player voice; multiplayer is post-MVP")
- Technical constraints ("Supporting this would require Y, which conflicts with our Z architecture")
- Strategic decisions ("We chose A instead of B because...")
- Memory pointers (`project_product_vision`, `project_monetization`, etc.)

Durable. Avoid temporary circumstances ("we're too busy right now") — those are deferrals, not rejections. Deferrals belong in TODO with a `[ ]` marker, not here.

## When to check `.out-of-scope/`

During triage step 1 (Gather context), read all files in `.out-of-scope/`. When evaluating a new issue:

- Check if the request matches an existing out-of-scope concept
- Matching is by concept similarity, not keyword — "co-op trivia" matches `multiplayer-mvp.md`
- If there's a match, surface it: *"This is similar to `.out-of-scope/multiplayer-mvp.md` — we rejected this before because [reason]. Do you still feel the same way?"*

The user may:

- **Confirm** — append the new issue to the existing file's "Prior requests" list, then close the issue with `wontfix`.
- **Reconsider** — delete or update the out-of-scope file, then run normal triage on the new issue.
- **Disagree** — issues are related but distinct, proceed with normal triage.

## When to write to `.out-of-scope/`

Only when an **enhancement** (not a bug) is rejected as `wontfix`. Flow:

1. User decides a feature request is out of scope.
2. Check if a matching `.out-of-scope/` file already exists.
3. If yes: append the new issue to the "Prior requests" list.
4. If no: create a new file with the concept name, decision, reason, first prior request.
5. Append a final note on the issue file referencing the out-of-scope file.
6. Update the issue's `**Triage:**` line to `enhancement · wontfix`.
7. If the issue was on TODO, mark `[x]` (kept for history, not deleted).

## Updating or removing out-of-scope files

If the user changes their mind:

- Delete the `.out-of-scope/` file.
- The skill doesn't reopen old issues — they're historical records.
- The new issue that triggered the reconsideration proceeds through normal triage.
