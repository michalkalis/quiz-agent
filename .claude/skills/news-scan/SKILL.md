---
name: news-scan
description: Monthly scan of Claude Code / agentic-coding news (official changelog, Anthropic blog, high-signal community sources) with a proposal of what to adopt in this repo. Run monthly; the session-start hook reminds when >30 days old.
allowed-tools: Bash, Agent, Read
disable-model-invocation: true
model: sonnet
---

# Agentic-Coding News Scan

Monthly external review: what changed in Claude Code and agentic-coding practice since the last scan, and what (if anything) we should adopt.

## Steps

1. Record the scan timestamp:
   ```bash
   date +%s > "$CLAUDE_PROJECT_DIR/.claude/.last-news-scan"
   ```
2. Delegate the research to a `general-purpose` subagent (`model: sonnet`) with the prompt below, adjusting the date window to "since <last scan date> (roughly the last month)".
3. Present the report, then propose 1-3 concrete adoption candidates for this repo and ask the founder which to green-light (interactively, per Rule #13). Do not implement anything without their pick.

## Research prompt (for the subagent)

```
Research the latest developments in Claude Code and agentic coding workflows. Use WebSearch and WebFetch. Window: since <DATE>. Trustworthy sources only:

1. Official: Claude Code CHANGELOG (github.com/anthropics/claude-code), Anthropic/Claude engineering blog, docs updates (Agent SDK, skills, hooks, MCP, subagents).
2. High-signal community: Simon Willison's blog, active awesome-claude-code lists, credible engineering blogs. No SEO spam.
3. Emerging agentic-coding patterns (orchestration, background/CI agents, memory, spec-driven dev).

Context (judge relevance only, don't audit): solo-founder monorepo (FastAPI + SwiftUI iOS), ~30 custom skills, hooks, subagent model routing (cheap workers / frontier decisions), overnight autonomous loop on a second Mac, file-based memory, issue/handoff docs discipline, XcodeBuildMCP + Pencil MCP.

Return ≤120 lines: (A) official changes, 1 line each + why it matters for a setup like ours; (B) 5-10 community tools/repos with links + honest signal assessment; (C) 3-6 emerging patterns with fit high/medium/low. Include URLs; mark anything unverified.
```

## Output

Findings go in chat (tight markdown). No report files unless the founder explicitly asks. If an adoption candidate is sizable, file it via `/triage` instead of implementing inline.
