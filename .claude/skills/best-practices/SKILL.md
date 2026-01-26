---
name: best-practices
description: Check Claude Code setup for improvements and best practices
allowed-tools: Task, Read, Write, Bash
model: sonnet
---

# Best Practices Check

Analyze the Claude Code setup for this project and suggest improvements.

## Arguments

- **full** (default): Complete analysis of CLAUDE.md, skills, agents, and hooks
- **quick**: Just the summary score and top 3 recommendations

## Steps

1. **Record check timestamp**: Update `.claude/.last-check` with current timestamp
2. **Delegate to analyzer**: Use the `best-practices-checker` agent to perform analysis
3. **Present results**: Format and display the findings

## Execution

First, update the last check timestamp:
```bash
date +%s > "$CLAUDE_PROJECT_DIR/.claude/.last-check"
```

Then delegate the analysis to the best-practices-checker agent with the following prompt:

```
Analyze this project's Claude Code setup:

1. Read CLAUDE.md in the project root
2. Read all files in .claude/skills/*/SKILL.md
3. Read all files in .claude/agents/*.md
4. Read .claude/settings.json for hooks configuration
5. Count lines in .claude/rules/*.md files

Mode: {argument or "full"}

Provide your analysis following the output format in your instructions.
```

## Tips Display

After the check completes, remind the user:
- Run `/best-practices` weekly to stay current
- The session-start hook will remind you if overdue (>7 days)
