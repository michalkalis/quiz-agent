---
name: research
description: Deep research on any topic with web sources, saves structured report
allowed-tools: WebSearch, WebFetch, Read, Write, Glob, Grep
model: sonnet
---

# Domain Research

Conduct deep research on a topic and produce a structured report with sources.

## Arguments

`$ARGUMENTS` — Research topic or question (e.g., "popular trivia quiz apps 2026")

## Instructions

1. **Plan the research**: Break the topic into 3-5 specific search queries that cover different angles (market data, user behavior, technical approaches, trends).

2. **Execute searches**: Use WebSearch for each query. For promising results, use WebFetch to get full article content. Aim for 5-10 quality sources.

3. **Synthesize findings** into a structured report:

```markdown
# Research: [Topic]

**Date:** [today] | **Query:** [original question]

## Executive Summary
[3-5 bullet points with the most important findings]

## Key Findings

### [Finding 1 Title]
[2-3 paragraphs with specifics, data points, quotes]

### [Finding 2 Title]
...

## Implications for CarQuiz
[How these findings relate to the quiz-agent project specifically]

## Recommendations
1. [Actionable recommendation]
2. ...

## Sources
1. [Title](URL) — [1-line summary of what was useful]
2. ...
```

4. **Save** to `docs/research/[kebab-case-topic].md`

5. **Report** file path and 3-line summary of key takeaways.

## Notes

- If `$ARGUMENTS` is empty, ask what topic to research
- Prioritize recent sources (2025-2026)
- Always cite sources — never present unsourced claims as fact
- If a WebFetch fails, note the source but don't block on it
- Keep reports focused — 1-3 pages, not an encyclopedia
