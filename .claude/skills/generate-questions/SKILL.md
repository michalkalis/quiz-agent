---
name: generate-questions
description: Generate high-quality quiz questions using Claude and save for review
allowed-tools: Read, Bash, AskUserQuestion
model: haiku
argument-hint: "[count] [--category kids|adults|...] [--theme \"Name\"] [--language en|sk|cs] [--dry-run] [--session]"
---

# Generate Quiz Questions

Thin client over `apps/quiz-pack-api/scripts/generate_pack.py` (issue #36 task 2.16). The `PackGenerator` orchestrator owns sourcing, generation, verification, scoring, dedup, and persistence — this skill only gathers parameters, shells out to the script, and reports results.

## Instructions

### 1. Parse Arguments

Map `$ARGUMENTS` to the CLI flags accepted by `scripts/generate_pack.py`:

| Skill arg | CLI flag | Default | Notes |
|-----------|----------|---------|-------|
| positional count | `--target-count` | `10` | First positional integer is the count |
| `--category <c>` | `--category` | unset | e.g. `kids`, `adults`, `general` |
| `--theme "<name>"` | `--theme` | unset | e.g. `"Harry Potter"` |
| `--language <code>` | `--language` | `en` | ISO 639-1 (`en`/`sk`/`cs`) |
| `--prompt "<text>"` | `--prompt` | inferred | If omitted, build from theme/category/topics |
| `--dry-run` | `--dry-run` | off | Skip persistence (no DB writes) |
| `--session` | env `LLM_GATEWAY=session` | off | Run every LLM step on the Claude Code subscription instead of paid APIs (#169 — session gateway). Same pipeline, same prompts/guards; only the transport changes. Judge panel is always OFF in session runs (founder 2026-09-02: D21 showed judges add nothing; parity with the prod worker). Embeddings still need `OPENAI_API_KEY`. |

If `--prompt` is not supplied, synthesize one from the user's words (e.g. `"<count> questions about <theme or topic> for <category>"`). When ambiguous, ask the user via `AskUserQuestion` for the missing piece (prompt, language, or category) rather than guessing.

### 2. Run the Script

Always run from `apps/quiz-pack-api/` (per `feedback_qgen_import_cwd`).

**`--session` preflight:** run `claude auth status` and require `"authMethod": "claude.ai"` (`loggedIn: true`); if not, stop and tell the user to log in with `claude` — never fall back to the paid path silently. Then prefix the command with `LLM_GATEWAY=session`. Session runs share the subscription quota with this very session: keep counts small (≤ 30) and do not run two heavy session jobs at once.

```bash
cd apps/quiz-pack-api && [LLM_GATEWAY=session] python scripts/generate_pack.py \
  --prompt "<prompt>" \
  --target-count <N> \
  --language <lang> \
  [--category <c>] \
  [--theme "<name>"] \
  [--dry-run]
```

The script streams `[NN] start/finish <step>` breadcrumbs for each pipeline stage and then prints:

```
pack_id: <uuid or dry-run:<uuid>>
questions: <N>
cost_cents: <int>
  1. <question>  →  <answer>   [<source_url>]
  ...
```

### 3. Report Back

Summarize for the user:

- `pack_id` (so it can be referenced in TODO / review tooling)
- count of questions produced vs requested
- `cost_cents` totals
- with `--session`: cost is subscription quota, not dollars — report the token totals the script prints (model ids `session:<alias>` are unpriced by design)
- any questions with `(no source)` — flag them, since F8 requires non-null `source_url` on persisted runs (#36 §Phase 2E)

If the script exits non-zero, surface the last stage to fail (read the `[NN] start <step>` breadcrumb that has no matching `finish`) and the error verbatim — do not retry silently.

### 4. Next Steps

- Persisted runs land in Postgres; point the user to the review UI: `http://localhost:8003/web/review`.
- Dry runs print only — remind the user to drop `--dry-run` once they are happy with the shape.
- For deeper QA, suggest `/score-questions` or `/verify-questions` against the generated pack.

## Important

- Do NOT reimplement sourcing, critique, or scoring inside this skill — that logic lives in `PackGenerator` and its stages (`apps/quiz-pack-api/app/orchestrator/`). Any drift between the skill and the orchestrator violates #36 §Definition of Done #5.
- Do NOT load prompt templates here. The script's `GenerationStage` reads them through `AdvancedQuestionGenerator`.
- `--dry-run` is the safe default while iterating on prompts or themes; only omit it once the user wants the pack saved.
