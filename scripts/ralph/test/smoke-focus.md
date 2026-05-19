# Ralph Smoke Test

Trivial focus file to verify the Ralph harness end-to-end on the agent Mac:
fresh `claude -p` session → reads focus → does one tiny task → commits → emits
`RALPH_RESULT` marker the harness can parse.

**Not** a real task. Do not run this against the main backlog; it exists only
to confirm the loop is wired correctly.

## What to do

- [ ] Create `scripts/ralph/test/SMOKE.md` containing exactly one line:
  `PASS <YYYY-MM-DD>` (use today's date). Mark this checkbox `[x]` in the same
  commit. Commit message: `test(ralph): smoke pass <YYYY-MM-DD>`.

## Acceptance

- `scripts/ralph/test/SMOKE.md` exists with one `PASS YYYY-MM-DD` line.
- One new commit on `main` with the smoke message.
- `RALPH_RESULT: {"status": "done", ...}` in the iteration log.

## When this is `no-tasks`

If `SMOKE.md` already exists and the checkbox above is already `[x]`, the focus
file is empty — exit with `status: no-tasks`, no changes. (Operator deletes
`SMOKE.md` and reverts the checkbox to re-run the smoke.)
