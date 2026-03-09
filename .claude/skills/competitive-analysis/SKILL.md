---
name: competitive-analysis
description: Research competitors and create feature matrix with positioning analysis
allowed-tools: WebSearch, WebFetch, Read, Write, Glob
model: sonnet
---

# Competitive Analysis

Research competitor apps and produce a feature comparison matrix with strategic insights.

## Arguments

`$ARGUMENTS` — Comma-separated competitor names (e.g., "Trivia Crack, QuizUp, Kahoot")

## Instructions

1. **Parse competitors** from `$ARGUMENTS`. If empty, search for "top trivia quiz apps 2026" and select 3-5 relevant competitors.

2. **Research each competitor** using WebSearch + WebFetch:
   - Core features and unique selling points
   - Monetization model (free, freemium, subscription, ads)
   - Target audience
   - App Store ratings and review themes
   - Notable UX patterns or innovations
   - Voice/hands-free features (if any)

3. **Build feature matrix**:

```markdown
# Competitive Analysis: Trivia Quiz Apps

**Date:** [today] | **Competitors analyzed:** [count]

## Feature Matrix

| Feature | CarQuiz | [Comp 1] | [Comp 2] | [Comp 3] |
|---------|---------|----------|----------|----------|
| Voice input | Yes | ... | ... | ... |
| Hands-free mode | Yes | ... | ... | ... |
| Multiplayer | No | ... | ... | ... |
| Offline mode | No | ... | ... | ... |
| Custom categories | ... | ... | ... | ... |
| AI-powered | Yes | ... | ... | ... |
| Free tier | Yes | ... | ... | ... |

## Competitor Profiles

### [Competitor 1]
- **What they do well:** ...
- **Weaknesses:** ...
- **Key takeaway for CarQuiz:** ...

...

## CarQuiz Positioning

### Unique Advantages
- [What CarQuiz does that nobody else does]

### Gaps to Address
- [Features competitors have that CarQuiz lacks]

### Strategic Recommendations
1. [Recommendation with rationale]
2. ...

## Sources
1. ...
```

4. **Save** to `docs/research/competitive-analysis-[date].md`

5. **Report** file path, competitor count, and top 3 strategic insights.

## Notes

- Focus on features relevant to CarQuiz's driving/voice-first use case
- Note any competitor that has shut down (e.g., QuizUp) — explain why
- Be honest about CarQuiz's current gaps
- If info isn't available, mark as "Unknown" rather than guessing
