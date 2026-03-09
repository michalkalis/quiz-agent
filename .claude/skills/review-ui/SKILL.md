---
name: review-ui
description: Analyze a UI screenshot against iOS HIG and output SwiftUI improvement suggestions
allowed-tools: Read, Write, Glob, Grep, WebSearch
model: opus
---

# Review UI — iOS Design Analysis

Analyze a screenshot of the CarQuiz app against Apple's Human Interface Guidelines and provide actionable SwiftUI code suggestions.

## Arguments

`$ARGUMENTS` — Path to a screenshot file (e.g., "screenshots/home-screen.png")

## Instructions

1. **Read the screenshot** at the provided path using Read tool (it supports images).

2. **Read current SwiftUI code** for the screen being reviewed:
   - Scan `apps/ios-app/CarQuiz/CarQuiz/Views/` to identify which view matches the screenshot
   - Read the matching view file(s)

3. **Analyze against iOS HIG criteria**, scoring each 1-5:

| Category | Score | Notes |
|----------|-------|-------|
| **Layout & Spacing** | /5 | Margins, padding, alignment, safe areas |
| **Typography** | /5 | Font sizes, hierarchy, readability |
| **Color & Contrast** | /5 | Accessibility (WCAG AA), dark mode support |
| **Touch Targets** | /5 | Min 44pt, spacing between tappable areas |
| **Information Hierarchy** | /5 | Visual weight, scanning order, clarity |
| **Accessibility** | /5 | VoiceOver labels, Dynamic Type support |
| **Motion & Feedback** | /5 | Animations, loading states, haptics |
| **iOS Conventions** | /5 | Navigation patterns, system controls, SF Symbols |

4. **Provide specific fixes** — for each issue scoring below 4, provide:
   - What's wrong and why it matters
   - The exact SwiftUI code to fix it (show before → after)
   - Reference the relevant HIG section

5. **Output format**:

```markdown
# UI Review: [Screen Name]

**Screenshot:** [path] | **Date:** [today]
**Overall Score:** [X/40] ([qualitative rating])

## Scores
[table from step 3]

## Issues & Fixes

### [Issue 1]: [Category] — [Brief description]
**Severity:** High/Medium/Low
**Current:**
```swift
// current code
```
**Suggested:**
```swift
// improved code
```
**Why:** [HIG reference and rationale]

...

## Quick Wins
[Top 3 changes with highest impact-to-effort ratio]
```

6. **Save** to `docs/research/ui-review-[screen-name].md`

7. **Report** overall score and top 3 quick wins.

## Notes

- If `$ARGUMENTS` is empty or not a valid image path, ask for a screenshot path
- Focus on the driving use case — large text, high contrast, minimal distraction
- Consider both light and dark mode
- For voice-first app: emphasize visual feedback for audio states (recording, playing, processing)
- Use `model: opus` because visual analysis benefits from stronger reasoning
