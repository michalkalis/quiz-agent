# Product Index

Dashboard of all PRDs and user-story sets. Updated by hand when a PRD's status changes.

## How to read this

- **Status** — `Draft` (in progress), `Approved` (locked, implementation tracked via `docs/issues/`), `Shipped` (released), `Deferred` (paused, not rejected).
- **Implementation** — links to relevant issues so you can trace PRD → execution.

## PRDs

| Title | File | Status | Implementation |
|---|---|---|---|
| Trubbo MVP Launch | [mvp-launch.md](prds/mvp-launch.md) | Draft (2026-03-18) | Tracked across many issues — see `docs/issues/INDEX.md` |

## User Stories

| Title | File | Status |
|---|---|---|
| MVP User Stories | [mvp-user-stories.md](stories/mvp-user-stories.md) | — |

## Conventions

- New PRD: save to `prds/<kebab-slug>.md` Add a row above. Add a TODO line linking the PRD.
- New user-story set: save to `stories/<kebab-slug>.md`.
- A PRD ships when all its tracked issues reach `done` and the user explicitly marks the PRD `Shipped`.
- `Deferred` ≠ `Wontfix`. Deferred PRDs sit here. Rejected concepts get `wontfix` in their issue file.
