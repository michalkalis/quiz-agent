# Product Index

Dashboard of all PRDs and user-story sets. Updated by `/to-prd` and during `/triage` reviews.

## How to read this

- **Status** — `Draft` (in progress), `Approved` (locked, implementation tracked via `docs/issues/`), `Shipped` (released), `Deferred` (paused, not rejected — see `.out-of-scope/` for rejections).
- **Implementation** — links to relevant issues so you can trace PRD → execution.

## PRDs

| Title | File | Status | Implementation |
|---|---|---|---|
| Hangs MVP Launch | [mvp-launch.md](prds/mvp-launch.md) | Draft (2026-03-18) | Tracked across many issues — see `docs/issues/INDEX.md` |

## User Stories

| Title | File | Status |
|---|---|---|
| MVP User Stories | [mvp-user-stories.md](stories/mvp-user-stories.md) | — |

## Conventions

- New PRD: save to `prds/<kebab-slug>.md` via `/to-prd` or `/write-prd`. Add a row above. Add a TODO line linking the PRD.
- New user-story set: save to `stories/<kebab-slug>.md` via `/user-stories`.
- A PRD ships when all its tracked issues reach `done` and the user explicitly marks the PRD `Shipped`.
- `Deferred` ≠ `Wontfix`. Deferred PRDs sit here. Rejected concepts go to `.out-of-scope/`.
