# Issue #7: Result Screen UI/UX Review & Redesign

## Status: DONE

## Context
User doesn't like the buttons at the bottom and overall layout of ResultView.

## Current layout
ScrollView: header (progress + X button) → result badge → answer comparison → explanation → source card → question rating → auto-advance countdown → action buttons (Continue, Stay Here, View Source).

## Approach
1. Use `/review-ui` skill to do HIG analysis on ResultView screenshot
2. Redesign button layout: floating bottom bar with primary action
3. Better visual separation between sections
4. Card-based layout for each section

## Files to modify
- `apps/ios-app/CarQuiz/CarQuiz/Views/ResultView.swift` (~350 lines)
- Components in Views/ directory (ResultBadge, AnswerCard, ExplanationCard, SourceCard, etc.)

## Key issues to address
- Action buttons (Continue, Stay Here, View Source) at bottom feel cluttered
- Need better visual hierarchy
- Auto-advance countdown could be more prominent
- Consider sticky bottom bar for primary CTA
