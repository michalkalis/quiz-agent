# Research: CLAUDE.md Patterns — Monorepo, iOS/Swift, Python/FastAPI

**Date:** 2026-05-11 | **Query:** Real-world CLAUDE.md examples for Swift+Python monorepo

## Executive Summary

- Root CLAUDE.md should stay under 60–100 lines (hard cap ~200 before compliance degrades); delegate details to `@imported` files or `.claude/rules/` scoped files.
- iOS rules files universally document: architecture pattern (MVVM/@Observable), Swift concurrency stance, anti-patterns (never touch `.pbxproj`, no `nonisolated(unsafe)`), and build/test commands. Codable contracts and naming conventions appear in better examples.
- Python/FastAPI rules converge on: async-by-default, Pydantic for all schemas, `Depends()` for DB sessions, pytest with specific fixture patterns, and a short "Don't" section for anti-patterns.
- Monorepos: root CLAUDE.md covers global conventions + package map; each `apps/<name>/CLAUDE.md` covers stack-specific rules. The `.claude/rules/` directory handles cross-cutting concerns with `paths:` frontmatter for conditional loading.
- Deploy pitfalls belong in a separate `docs/runbooks/` or `docs/issues/` file that CLAUDE.md `@imports` only when relevant — not inline in the root.

---

## 1. iOS CLAUDE.md: Concrete Content Patterns

### Pattern 1 — Architecture Declaration (most common)

Every iOS CLAUDE.md studied declares the architecture in the first section so Claude never proposes alternatives. Example from `keskinonur/claude-code-ios-dev-guide`:

```markdown
## Architecture
- Pattern: MVVM with @Observable (not ObservableObject — deprecated)
- ViewModels: @MainActor classes, never nonisolated(unsafe)
- Views: SwiftUI only, extract when > 100 lines
- DI: @Environment for dependencies, not singletons
```

For Swift 6 strict concurrency, the critical addition is:
```markdown
## Concurrency
- All ViewModels are @MainActor
- Use async/await everywhere — no callbacks, no DispatchQueue
- Never use nonisolated(unsafe) in production
```

### Pattern 2 — Anti-Pattern Blocklist ("Never" section)

The most-cited rule across iOS examples (including the `banagale` gist and the indragie.com blog post) is a hard block on `.pbxproj` edits:

```markdown
## Never
- Modify .pbxproj directly — create files via Xcode or `xcodegen`, add them manually
- Use force unwrap (!) in production code
- Use nonisolated(unsafe) — use @MainActor or OSAllocatedUnfairLock instead
- Mix async/await with DispatchQueue/completion handlers
```

### Pattern 3 — Build & Test Commands Table

Concrete commands prevent Claude from guessing. The `artemnovichkov/iOS-26-by-Examples` repo and the ios-dev-guide both use a table format:

```markdown
## Commands
| Task        | Command |
|-------------|---------|
| Build (sim) | xcodebuild -scheme Hangs-Local -destination 'platform=iOS Simulator,name=iPhone 17 Pro' |
| Run tests   | xcodebuild test -scheme Hangs-Local -destination '...' |
| Open project | open apps/ios-app/Hangs/Hangs.xcodeproj |
```

### Pattern 4 — Codable/API Contract Rule

Less common but present in more advanced setups. The pattern is to declare the source of truth:

```markdown
## API Contract
- iOS Codable structs must match backend Pydantic models exactly
- Source of truth: OpenAPI spec at http://localhost:8002/openapi.json
- Run /verify-api after any API model change
- Never add fields to Codable that don't exist in the backend response
```

### Pattern 5 — File Organization

From multiple examples, a brief map prevents mis-placed files:

```markdown
## File Organization
ViewModels/    — @MainActor classes, business logic only
Views/         — SwiftUI views, no business logic
Services/      — Network/data layer, protocol-based for testability
Models/        — Codable structs matching backend responses
```

### Ideal Length & Structure

- **Total length:** 80–120 lines for a dedicated `ios.md` rules file; 20–30 lines for the iOS section in a root CLAUDE.md.
- **Structure:** Architecture → Concurrency → Commands → Anti-patterns → File organization. Put the "Never" section near the top — it's highest-leverage.
- **Import pattern:** Root CLAUDE.md does `See @.claude/rules/ios.md for iOS patterns` rather than inlining.

---

## 2. Python/FastAPI CLAUDE.md: Concrete Content Patterns

The `abhishekray07/claude-md-templates` Python FastAPI template and the ruvnet wiki both converge on a 7-section structure:

### Pattern 1 — Stack Declaration

```markdown
## Stack
- Python 3.12, FastAPI 0.115+, Pydantic v2 (strict mode)
- SQLAlchemy 2.0 async + asyncpg
- pytest + pytest-asyncio + httpx for testing
- Deployed to Fly.io via `fly deploy` from apps/quiz-pack-api/
```

### Pattern 2 — Async-by-Default Rule

> "Async by default for route handlers. Never mix sync and async code."

```markdown
## Conventions
- All route handlers: async def
- DB sessions via Depends() — never instantiate directly in handlers
- Use Pydantic models for all request/response schemas — no raw dicts
- HTTPExceptions centralized in app/exceptions.py
```

### Pattern 3 — Testing Fixture Pattern

```markdown
## Testing
- pytest tests/ -v
- Unit tests: mock OpenAI calls, use fixtures
- Integration tests: in-memory SQLite via conftest.py
- Never test with real external API calls in CI
- Coverage target: 80% minimum
```

### Pattern 4 — Type Checking & Linting Commands

```markdown
## Commands
| Task       | Command |
|------------|---------|
| Run tests  | cd apps/quiz-pack-api && pytest tests/ -v |
| Type check | mypy app/ |
| Lint       | ruff check . && ruff format --check . |
| Start dev  | uvicorn app.main:app --reload --port 8003 |
```

### Pattern 5 — Anti-Pattern "Don't" Section

From the FastAPI template:
> "Don't catch bare `Exception` — catch specific exceptions"

```markdown
## Don't
- Catch bare Exception — use specific exception types
- Put business logic in route handlers — use service layer
- Duplicate type definitions — import from packages/shared/
- Commit .env files — secrets in Fly.io secrets or .env (gitignored)
```

---

## 3. Monorepo Splitting: Where to Draw the Line

### The Three-Layer Model (consensus pattern)

**Layer 1 — Root `CLAUDE.md`** (60–100 lines max):
- What the repo is and why it exists
- Package map (what lives in `apps/`, `packages/`, etc.)
- Global conventions: commit format, branch strategy, shared package import rules
- Table of commands (one per package)
- Cross-cutting "Never" rules

**Layer 2 — Package-level `CLAUDE.md`** (each `apps/<name>/CLAUDE.md`):
- Stack-specific patterns for that package
- Local build/test commands (redundant with root but faster to find)
- Package-specific anti-patterns
- Links to deeper rules files

Example from `MuhammadUsmanGM/claude-code-best-practices` monorepo template:
> "Import from `@acme/shared` for shared types — never duplicate type definitions across packages"
> "This package is a dependency of all other packages — breaking changes here affect everything"

**Layer 3 — `.claude/rules/` scoped files** (conditional loading via `paths:` frontmatter):
- Load only when Claude touches specific file types or directories
- Examples: `ios.md` (paths: `apps/ios-app/**`), `backend.md` (paths: `apps/quiz-pack-api/**`), `testing.md` (paths: `tests/**`)
- Keeps root file short; Claude only reads relevant rules per task

### The `@import` Bridge

Root CLAUDE.md references but doesn't inline:
```markdown
- Git workflow: @.claude/rules/shared.md
- iOS patterns: @.claude/rules/ios.md  
- Backend patterns: @.claude/rules/backend.md
```

The browser-use monorepo gist uses a more explicit version: each sub-project has its own git history and the root CLAUDE.md explicitly tells Claude "always cd into the relevant sub-project before doing any git operations."

---

## 4. Deploy Pitfalls / Post-Mortem Notes: Best Location

**Consensus:** Do NOT inline deploy pitfalls in CLAUDE.md rules files. They clutter every session regardless of relevance.

**Recommended pattern:**

1. **`docs/issues/issue-NN-*.md`** or **`docs/runbooks/<service>.md`** — the full post-mortem detail
2. **`@import` on-demand** — root CLAUDE.md mentions the file but only Claude reads it when deployment is in scope
3. **Hook-enforced guardrails** — for pitfalls that are truly "never do this," encode as a pre-commit or pre-deploy hook (deterministic, not advisory)

From builder.io's guide:
> "After mistakes, update your CLAUDE.md so this doesn't happen again — Claude writes its own rule, preventing future recurrence."

But HumanLayer's guidance cuts the other direction:
> "Your CLAUDE.md should contain as few instructions as possible — ideally only ones which are universally applicable."

The right answer: one-line reference in CLAUDE.md (`Deploy pitfalls: @docs/runbooks/fly-deploy.md`) with the detail in the runbook. For the truly critical ones (e.g., "never run alembic upgrade in production without a backup"), a hook beats a CLAUDE.md rule.

---

## 5. Specific Repos Worth Studying

1. **`abhishekray07/claude-md-templates`** — https://github.com/abhishekray07/claude-md-templates
   Best multi-layer template system: global / project / local / rules separation. Has a real Python FastAPI template. The 7-section structure (Project → Stack → Structure → Commands → Verification → Conventions → Don't) is a proven pattern worth copying directly.

2. **`MuhammadUsmanGM/claude-code-best-practices`** — https://github.com/MuhammadUsmanGM/claude-code-best-practices
   Has 11 stack-specific CLAUDE.md examples including a dedicated monorepo example showing Turborepo root + package-level split. Quotes the "never duplicate types across packages" and "shared package = breaking changes affect everything" rules.

3. **`josix/awesome-claude-md`** — https://github.com/josix/awesome-claude-md
   Curated collection of real CLAUDE.md files scraped from public GitHub projects, with pattern analysis. Useful for seeing what actual teams ship (vs. what tutorial authors recommend).

Honorable mention: **`pirate/browser-use` monorepo gist** (https://gist.github.com/pirate/ef7b8923de3993dd7d96dbbb9c096501) — real production monorepo CLAUDE.md with a FastAPI backend + Next.js frontend. Notable for: tab-only indentation rule, "use real objects not mocks" testing philosophy, and "cd into sub-project before git ops" pattern.

---

## Recommendations for quiz-agent

1. **Root CLAUDE.md:** trim to 80 lines; move iOS and backend detail into `.claude/rules/ios.md` and `.claude/rules/backend.md` with `@import` references. Current root is already close to this pattern.

2. **iOS rules file:** add an explicit Swift 6 concurrency section with `@MainActor` policy; add a 5-line Codable contract block referencing OpenAPI as source of truth; add "Never" section at the top.

3. **Backend rules file:** add a 3-line "async by default" rule, a Pydantic-for-all-schemas rule, and a `Depends()` for DB sessions rule. Add the `Don't` section for bare Exception catching.

4. **Deploy pitfalls:** move Fly.io-specific gotchas out of inline rules into `docs/runbooks/fly-deploy.md` and reference it with `@`. Encode hard blockers (e.g., no migration without backup) as pre-deploy hooks.

5. **Shared package rule:** add one line to root CLAUDE.md: "Import models from `packages/shared/` — never duplicate Pydantic models across apps."

---

## Sources

1. [Writing a good CLAUDE.md — HumanLayer Blog](https://www.humanlayer.dev/blog/writing-a-good-claude-md) — Best overall philosophy: WHAT/WHY/HOW framework, 60-line root target, progressive disclosure pattern
2. [Best practices for Claude Code — Official Docs](https://code.claude.com/docs/en/best-practices) — Authoritative guidance on CLAUDE.md structure, `@import` syntax, nested file loading behavior, `paths:` frontmatter for scoped rules
3. [50 Claude Code Tips and Best Practices — Builder.io](https://www.builder.io/blog/claude-code-tips-best-practices) — "150–200 instruction budget" finding; update-after-mistakes pattern; `.claude/rules/` for conditional loading
4. [claude-md-templates — abhishekray07](https://github.com/abhishekray07/claude-md-templates) — Best multi-layer template system; Python FastAPI template with 7-section structure
5. [claude-code-best-practices — MuhammadUsmanGM](https://github.com/MuhammadUsmanGM/claude-code-best-practices) — 11 stack examples including monorepo; "never duplicate types" rule
6. [claude-code-ios-dev-guide — keskinonur](https://github.com/keskinonur/claude-code-ios-dev-guide) — @Observable over ObservableObject, Swift 6 concurrency, type-safe navigation enum pattern
7. [Swift CLAUDE.md sample gist — banagale](https://gist.github.com/banagale/50dde8d6c56929d07e8ad17dab01680f) — 13-section Swift rules file; "Never" section; attribution rules
8. [browser-use monorepo CLAUDE.md gist — pirate](https://gist.github.com/pirate/ef7b8923de3993dd7d96dbbb9c096501) — Real FastAPI+Next.js monorepo; "real objects not mocks" testing philosophy
9. [awesome-claude-md — josix](https://github.com/josix/awesome-claude-md) — Curated real-world CLAUDE.md collection from public repos
10. [7 Claude Code Best Practices — eesel.ai](https://www.eesel.ai/blog/claude-code-best-practices) — Monorepo hierarchical CLAUDE.md recommendation; deploy pre-checks pattern
