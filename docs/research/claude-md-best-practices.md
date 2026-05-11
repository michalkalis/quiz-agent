# Research: CLAUDE.md Best Practices (May 2026)

**Date:** 2026-05-11 | **Query:** CLAUDE.md structure, size, @import vs path-scoped rules for monorepo

## Executive Summary

- Anthropic's official soft limit is **200 lines per CLAUDE.md file** — beyond that, adherence drops and important rules get ignored
- `@import` directives are **eager, not lazy**: imported files load into context at launch, so they save organization but not tokens
- Path-scoped `.claude/rules/` files with `paths:` frontmatter are **the recommended pattern** for reducing context for monorepos — but known bugs exist (see §3)
- Root CLAUDE.md should be a thin "router" for universal facts; behavioral rules and domain specifics belong in scoped rules files
- The biggest anti-pattern is a bloated root CLAUDE.md where important rules get lost in the noise

---

## 1. Official Anthropic Guidance

Source: [https://code.claude.com/docs/en/memory](https://code.claude.com/docs/en/memory) (verified May 2026)

**Size:** "Target under 200 lines per CLAUDE.md file. Longer files consume more context and **reduce adherence**."

**Loading:** CLAUDE.md files are loaded into the context window as a user message (not the system prompt) at every session start. All ancestor CLAUDE.md files (from filesystem root to cwd) load in full at launch. Subdirectory CLAUDE.md files load on demand when Claude reads files in those directories.

**@import:** "`@path/to/import` syntax — imported files are expanded and loaded into context **at launch** alongside the CLAUDE.md that references them." Recursive up to 5 hops. Critically: "@import helps organization but **does not reduce context**, since imported files load at launch."

**`paths:` frontmatter:** "Rules can be scoped to specific files using YAML frontmatter with the `paths` field. These conditional rules **only apply when Claude is working with files matching the specified patterns**." Rules without a `paths` field load unconditionally at launch (same as .claude/CLAUDE.md).

**Adherence tip:** "CLAUDE.md content is delivered as a user message after the system prompt, not as part of the system prompt itself. Claude reads it and tries to follow it, but there's no guarantee of strict compliance, especially for vague or conflicting instructions."

**Compaction safety:** "Project-root CLAUDE.md survives compaction: after `/compact`, Claude re-reads it from disk and re-injects it." Nested subdirectory CLAUDE.md files are **not** re-injected automatically — they reload the next time Claude reads a file in that subdirectory.

---

## 2. File Size / Structure Recommendations

| Source | Recommendation |
|--------|---------------|
| Anthropic official docs | Under 200 lines per file; longer = lower adherence |
| community (promptcertifications.com) | Under 500 lines (less strict; community wisdom) |
| Anthropic best-practices page | "Ruthlessly prune. If Claude already does something correctly without the instruction, delete it." |
| claudefa.st/rules-directory | "Splitting a monorepo's CLAUDE.md into service-level files can reduce total word count by 80% while improving rule-following" |

**Verdict for your setup:** Your root CLAUDE.md at ~150 lines with 12 rules is within the official 200-line soft limit if you keep it lean. The existing `.claude/rules/` files (27–71 lines each) are well within bounds. No restructuring is required for size alone, but rule placement matters for adherence (see §4).

---

## 3. @import vs Path-Scoped Frontmatter — Current Best Practice (May 2026)

### @import (`@.claude/rules/backend.md`)
- **Eager**: file contents load into context at session start, every session
- **Use for**: README, package.json, workflow docs you want Claude to reference globally
- **Does not** save context — it just avoids copy-pasting content into CLAUDE.md directly
- Good for organizing non-conditional content across multiple files

### `paths:` frontmatter in `.claude/rules/`
- **Lazy**: rule file loads only when Claude reads a file matching the glob pattern
- **Use for**: iOS-specific rules, backend-specific rules, test conventions — anything not needed every session
- **Saves context** by deferring load until relevant
- **Known bugs (as of early 2026):**
  - [Issue #16299](https://github.com/anthropics/claude-code/issues/16299): All `.claude/rules/` files may load globally regardless of `paths:` in some Claude Code versions
  - [Issue #23478](https://github.com/anthropics/claude-code/issues/23478): Path-based rules only inject on Read tool, not Write/Create tool
  - [Issue #21858](https://github.com/anthropics/claude-code/issues/21858): `paths:` is ignored in user-level (`~/.claude/rules/`) — only works in project-level rules
  - [Issue #13905](https://github.com/anthropics/claude-code/issues/13905): Glob patterns starting with `{` or `*` must be quoted in YAML frontmatter

### Recommendation
- Keep `paths:` frontmatter in `.claude/rules/` (as you already do) — it's the right pattern even with the bugs
- Do **not** use `@import` for ios.md or backend.md — that makes them eager-loaded regardless of context
- Verify glob syntax is quoted: `paths: ["apps/ios-app/**"]` not `paths: apps/ios-app/**`

---

## 4. What Goes Where

| Content type | Belongs in | Reason |
|---|---|---|
| Build/test commands, CI structure | Root `CLAUDE.md` | Universal, needed every session, short |
| Commit conventions, git workflow | `.claude/rules/shared.md` (no paths) | Needed every session but separable |
| Architecture overview (2-3 lines) | Root `CLAUDE.md` | Quick reference pointer |
| Detailed API contract rules | `.claude/rules/shared.md` (no paths) | Every session for API work |
| **Behavioral rules (12 Mnilax rules)** | Root `CLAUDE.md` or `.claude/rules/shared.md` | Universal behavior — load every session. If they push root past 200 lines, move to `shared.md` without `paths:` (loads at launch anyway) |
| iOS patterns, SwiftUI conventions | `.claude/rules/ios.md` (`paths: apps/ios-app/**`) | iOS-only context |
| Python/FastAPI standards | `.claude/rules/backend.md` (`paths: apps/quiz-agent/**`) | Backend-only context |
| Deploy pitfalls, post-mortem notes | `.claude/rules/backend.md` OR a `deploy-pitfalls.md` with no `paths:` | If deploy pitfalls are critical and universal, no `paths:` so they load every session |
| Quick reference commands table | Root `CLAUDE.md` | Developers need this regardless of file context |

**Behavioral rules specifically:** The 12 Mnilax/Karpathy rules (e.g., "always explain your reasoning", "don't hallucinate filenames") are **universal behavioral constraints** — they should load every session. Put them in root `CLAUDE.md` if the file stays under 200 lines, or in `.claude/rules/shared.md` without a `paths:` field (which also loads at launch). Do NOT scope them to a path.

---

## 5. Anti-Patterns

**1. Using @import to "save context"**
Importing a file with `@` does not defer loading. Both `@.claude/rules/backend.md` in your root CLAUDE.md and having a `paths:`-scoped rule in `.claude/rules/backend.md` get the file into context — but only the `paths:` version does so lazily. Using `@import` for path-specific content loads it every session whether you're on iOS files or backend files.

**2. Putting everything in root CLAUDE.md**
Official docs are explicit: "If your instructions are growing large, use path-scoped rules so instructions load only when Claude works with matching files." A monolithic root CLAUDE.md over 200 lines is the most common failure mode — important rules get lost in the noise and Claude ignores them.

**3. Duplicating rules across files (conflicting instructions)**
"If two rules contradict each other, Claude may pick one arbitrarily." In a monorepo where multiple CLAUDE.md files concatenate, contradictions cause unpredictable behavior. Review `.claude/rules/` periodically to prune outdated or conflicting instructions. Use `claudeMdExcludes` in settings if ancestor CLAUDE.md files from other teams inject irrelevant instructions.

---

## Sources

1. [How Claude remembers your project — official docs](https://code.claude.com/docs/en/memory) — Primary source: size limits, loading behavior, @import semantics, paths: frontmatter, compaction behavior
2. [Best practices for Claude Code — official docs](https://code.claude.com/docs/en/best-practices) — What to include/exclude from CLAUDE.md, over-specified CLAUDE.md anti-pattern
3. [Claude Code Rules Directory guide](https://claudefa.st/blog/guide/mechanics/rules-directory) — Rules directory structure, path targeting, anti-patterns
4. [CLAUDE.md Best Practices — DEV Community](https://dev.to/cleverhoods/claudemd-best-practices-from-basic-to-adaptive-9lm) — Behavioral rule phrasing (RFC 2119), router pattern
5. [When Your CLAUDE.md Gets Too Long](https://www.promptcertifications.com/learn/posts/when-your-claude-md-gets-too-long-import-rules-and-the-memory-command) — @import vs paths: comparison, 500-line community threshold
6. [Issue #16299 — paths: frontmatter global load bug](https://github.com/anthropics/claude-code/issues/16299)
7. [Issue #23478 — paths: rules only inject on Read, not Write](https://github.com/anthropics/claude-code/issues/23478)
8. [Issue #21858 — paths: ignored in user-level rules](https://github.com/anthropics/claude-code/issues/21858)
