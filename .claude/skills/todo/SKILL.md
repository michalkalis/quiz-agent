---
name: todo
description: Manage the local todo list at docs/todo/TODO.md. Add, list, mark wip/done, edit, or remove items via natural language.
disable-model-invocation: true
allowed-tools: Read, Edit, Write, Bash
model: sonnet
---

# Todo Manager

Manage `docs/todo/TODO.md`. Three states: `[ ]` todo · `[~]` wip · `[x]` done. Items numbered continuing the existing `docs/issues/issue-NN-*.md` series.

## Workflow

1. **Read** `docs/todo/TODO.md`. Note the current state and the highest item number used.
2. **Decide intent** from the user's most recent message(s):
   - **List** (default if intent is unclear): print items, hide `[x]` unless user asks for "all" or "done".
   - **Add**: append `- [ ] #NN {title}` using the next number. If the task is sizable, offer to also scaffold a plan file at `docs/issues/issue-NN-{slug}.md` and link it as `— [plan](../issues/issue-NN-{slug}.md)`.
   - **Mark wip/done/reopen**: flip the checkbox of the referenced item.
   - **Edit / remove**: change the title text, or delete the line. Prefer marking done over deleting unless the user explicitly says "remove" or "delete".
3. **Apply** the change with Edit and print the affected line(s) so the user sees what happened.

## Intent examples

- `/todo` → list `[ ]` and `[~]`
- `/todo add fix translation lag` → add as `[ ]` next number
- `/todo mark 19 done` or `done 19` → flip to `[x]`
- `/todo working on 21` or `take 21` → flip to `[~]`
- `/todo all` → list including `[x]`
- `/todo remove 22` → delete line (confirm first if ambiguous)

## Rules

- One line per item. No type/priority columns — descriptive title instead.
- Numbers monotonically increase. Don't reuse numbers from removed/done items.
- If a number reference is ambiguous (e.g. user says "done" without a number and multiple `[~]` exist), ask which one.
- TODO.md is the source of truth — don't sync to GitHub Issues, Linear, etc.
