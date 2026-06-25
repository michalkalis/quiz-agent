# Ralph Iteration — Work Next Task

You are running **autonomously** as one iteration of a Ralph loop. No human is watching this turn. The harness invokes you fresh (no memory of prior iterations); all state lives in git + the focus file.

## Focus

**Focus file:** `__FOCUS_FILE__`

This is your only source of truth for "what needs doing." Read it in full before anything else. Cross-reference `docs/todo/TODO.md` for higher-level context.

## Goal of this iteration

Make **one** concrete unit of progress on the focus file, then stop. "One unit" = the smallest atomic task that:

- Has a clear acceptance check (test passes, file exists, count reached, etc.)
- Can be completed inside this iteration's budget (~15 min, $5)
- Can be committed atomically

If the focus file uses `- [ ]` checkboxes, pick the first one. Otherwise pick the first concrete "What to do" / "Acceptance" / "Sequencing" item that is not yet visibly satisfied. If the focus file is a strategy doc (no atomic tasks), your task is **to decompose it** into a child plan file with `- [ ]` checkboxes — that *is* the iteration.

## Protocol

1. **Read the focus file in full.** Do not skim.
2. **Verify current state** before claiming anything is done — `git log -10`, grep the code, run a smoke test. Memory-from-the-doc lies sometimes.
3. **Identify the single next task.** If multiple are unblocked, take the smallest. If nothing is left, exit with `status: no-tasks`.
4. **Check it isn't already done.** If `git log --grep="<task keyword>"` finds it, just update the focus file to reflect that and exit `status: done`.
5. **Implement only that task.** Surgical changes per `CLAUDE.md` rule #3. No drive-by cleanups, no scope expansion.
6. **Run the relevant tests.** Use the commands in `CLAUDE.md` quick-reference table or the task description. Tests must pass before you commit. **Never run the full iOS suite headless yourself** — do NOT invoke `xcodebuild test` / `-only-testing:HangsTests` (or XcodeBuildMCP build/test tools). Headless runs hang and orphan a wedged `xcodebuild` that blocks the overnight scheduler for days (2026-06 incident); the run's end-of-run gate verifies HangsTests automatically. Defer any iOS verification beyond that to a human/GUI run.
7. **Commit atomically** — code + focus-file progress update in one commit. Conventional Commits format per `.claude/rules/shared.md`. Include the task identifier in the message.
8. **Do NOT push.** The human reviews commits in the morning before pushing to origin.
9. **Do NOT touch unrelated files.** If you spot adjacent tech debt, leave it.
10. **Long-running commands run in the FOREGROUND.** You are headless: the session exits the moment you end your turn, killing any background process — "I'll wait for it to finish" loses all work. Never use background execution. For commands that outlive the default 2-minute Bash timeout (generation batches, full test suites), pass an explicit `timeout` of up to 1200000 ms (20 min) in the Bash tool call and wait for completion in the same call.

## Failure handling

If you cannot complete the task within budget:

- **Revert your in-progress changes** (`git restore .` for unstaged, `git reset HEAD` for staged-but-uncommitted).
- **Append a `## BLOCKER (YYYY-MM-DD)`** section to the focus file with: what you tried, where you got stuck, what the next human-touch needs.
- **Commit only the BLOCKER note**, then exit with `status: blocked`.

If the focus file is in an unexpected shape (missing, malformed, points to nothing actionable), exit with `status: no-tasks` and don't change anything.

## Output marker (mandatory)

The very last line of your output MUST be a single line in this exact form, parseable by the Ralph harness:

```
RALPH_RESULT: {"status": "done"|"blocked"|"no-tasks", "task": "<short description>", "commit": "<sha7>"|null, "notes": "<one-line summary>"}
```

If the harness can't parse this, the iteration counts as a failure. No prose after this line.

## Constraints recap

- One task per iteration. Stop when it's done — don't chain.
- Tests must actually pass. Skipped/xfail/commented-out tests = failure.
- Commit, never push.
- Surface uncertainty, don't hide it (CLAUDE.md rule #12: fail loud).
- Token budget per CLAUDE.md rule #6: 4k output, 30k session.
- Never launch a headless iOS build/test (`xcodebuild test` / HangsTests) yourself — the end-of-run gate covers it; ad-hoc headless runs orphan a zombie `xcodebuild` that wedges the scheduler for days.

You have full repo access via `bypassPermissions`. Use it responsibly.
