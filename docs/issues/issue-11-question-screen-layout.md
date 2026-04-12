# Issue #11: Improve Question Screen Layout

## Status: DONE

## Current issues (visible in screenshot)
- Question text cut off at bottom of card (long Slovak text doesn't fit)
- Error message at very bottom is easy to miss
- Skip + keyboard buttons feel cluttered
- "Tap to answer" hint not very prominent

## Already done (uncommitted)
- Added ScrollView wrapping question content
- Moved AnswerTimerBadge from bottom to top of question area
- Removed `.fixedSize(horizontal: false, vertical: true)` from text
- Removed "Recording starts automatically..." hint text

## Remaining improvements
- Ensure ScrollView works well with long text (gradient fade at bottom if truncated)
- Move error message to more visible position (below top bar? as banner?)
- Simplify bottom button area
- Better visual hierarchy between question and controls

## Files to modify
- `apps/ios-app/CarQuiz/CarQuiz/Views/QuestionView.swift`
- `apps/ios-app/CarQuiz/CarQuiz/Views/ImageQuestionView.swift`

## Verification
- Test with long Slovak questions (like screenshot: "Dvaja otcovia...")
- Test with image questions
- Test on smaller devices (iPhone SE)
