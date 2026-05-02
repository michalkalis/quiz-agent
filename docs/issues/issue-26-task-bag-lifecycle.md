# Issue 26: Introduce `TaskBag` — concentrate `QuizViewModel`'s task lifecycle

**Triage:** enhancement · done
**Status:** Shipped 2026-05-02 — `TaskBag` + `TaskKey` introduced; all 10 task handles migrated; 107 iOS tests pass.
**Created:** 2026-04-30
**Surfaced by:** architecture review, candidate #5

## TL;DR for next session

`QuizViewModel` (1085 lines) tracks **ten** nullable concurrent `Task` handles
as `var` properties, mutated freely from four extension files
(`+QuizViewModel`, `+Audio`, `+Recording`, `+Timers`). Adding a new timer is a
four-edit change: declaration, start, cancel, reset.

Current handles:

```
autoAdvanceTask, voiceSubmissionTask, answerTimerTask,
autoStopRecordingTask, silenceDetectionTask, autoConfirmTask,
thinkingTimeTask, sttEventTask, sttChunkTask, bargeInTask
```

`resetState()` (lines 979–997) is 52 lines of nothing but
cancel-and-nil-assign. Every other "stop everything" path duplicates a subset
of those calls.

The extension split is cosmetic — the four files share `internal` access to
each other's mutable state, so the file-level seam isn't a real seam.

## What to implement

Introduce a `TaskBag` (or `CancellableScope`) module that owns task handles
keyed by an enum or string:

```swift
final class TaskBag {
    func add(_ task: Task<Void, Never>, key: TaskKey)   // cancels existing under same key
    func cancel(_ key: TaskKey)
    func cancelAll()
}

enum TaskKey {
    case autoAdvance, voiceSubmission, answerTimer, ...
}
```

`QuizViewModel` holds **one** `TaskBag` instance. Each starting site does:

```swift
taskBag.add(Task { ... }, key: .autoConfirm)
```

`resetState()` becomes `taskBag.cancelAll()`. The ten `var` declarations
disappear from the ViewModel.

## Where the work lands

| Where | What changes |
|---|---|
| `apps/ios-app/Hangs/Hangs/Concurrency/TaskBag.swift` (new) | `TaskBag` + `TaskKey` enum |
| `apps/ios-app/Hangs/Hangs/ViewModels/QuizViewModel.swift` | Replace 10 `var Task?` properties with `private let taskBag = TaskBag()`; `resetState()` shrinks to one call |
| `QuizViewModel+Timers.swift`, `QuizViewModel+Recording.swift`, `QuizViewModel+Audio.swift` | Replace direct `someTask = Task { ... }` with `taskBag.add(Task { ... }, key: ...)`; replace `someTask?.cancel(); someTask = nil` with `taskBag.cancel(.someKey)` |
| `apps/ios-app/Hangs/HangsTests/` | New unit test file for `TaskBag` (cancellation correctness, idempotency, replace-on-same-key) |

## Benefits

- **Locality.** Task lifecycle in one module. Adding a new timer is one
  edit (the `TaskKey` case + the start site).
- **Leverage.** Callers get cancel-on-replace, cancel-all, and (optionally)
  introspection for free.
- **Testability.** `TaskBag` is a pure unit-testable type. The 1367-line
  `QuizViewModelTests` can shrink as task-lifecycle assertions move into
  `TaskBagTests`.
- **File size.** `QuizViewModel.swift` shrinks toward the ~300-line ceiling
  per `feedback_file_size_limit` memory.

## Caveats and traps

- **`@MainActor` matters.** `QuizViewModel` is main-actor-bound. `TaskBag`
  should also be main-actor-bound (or carry its own isolation) so cancel and
  replace are linearizable. Revisit `feedback_nonisolated_unsafe` memory.
- **Don't change task semantics in this refactor.** Some tasks are currently
  reset to nil after completion; some aren't. Preserve current behaviour
  exactly — this issue is structural, not behavioural. Behavioural cleanup
  is a follow-up.
- **The four extension files might consolidate naturally** once the shared
  mutable state is gone. Don't force it in this issue; the extension split
  can stay if it still helps readability.
- **`Task<Void, Never>` may not cover every handle.** Audit the throwing /
  non-throwing types. The bag may need to be generic, or expose two methods.
- **Don't add new timers in this issue.** Migrate the existing ten as-is.

## Related

- Memory `feedback_file_size_limit` — `QuizViewModel.swift` is the worst
  offender at 1085 lines.
- Memory `feedback_structural_fixes` — this is the structural answer to
  repeated "I forgot to cancel X" patches.
- Memory `project_crash_elimination` — Wave 3 timer bug (open since
  2026-04-15) lives in this code; landing 26 first may make that fix easier.
