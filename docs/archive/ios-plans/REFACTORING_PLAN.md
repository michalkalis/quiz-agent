# CarQuiz iOS App - Code Review & TDD Refactoring Plan

> **Usage**: Reference this file from fresh threads for each subtask.

## Summary

Thorough code review found 10 issues ranging from unnecessary complexity (actor-based locks on `@MainActor` classes) to MVVM violations (views directly controlling recording and mutating ViewModel state). This plan breaks the fixes into 9 incremental subtasks using TDD - write tests first, then implement.

**Approach**: Simplest/safest deletions first, then architectural changes. Each subtask leaves the app in a buildable, working state.

---

## Subtask 1: Remove Streak & Best Score ✅
## Subtask 2: Remove `isLoading` ✅
## Subtask 3: Remove `StateCoordinator` Actor ✅
## Subtask 4: Remove `AudioQueue` Actor ✅
## Subtask 5: Fix `pendingResponse` Modal Swipe-to-Dismiss ✅
## Subtask 6: Consolidate Error State into ViewModel ✅
## Subtask 7: Move Recording Lifecycle into ViewModel ✅
## Subtask 8: Consolidate Persistence ✅
## Subtask 9: Refactor `QuizState` to Carry Associated Values ✅

See full plan details in the implementation thread.
