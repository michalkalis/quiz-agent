# Issue 28: iOS category picker — expand catalog + add `age_appropriate`

**Triage:** enhancement · ready-for-agent
**Status:** Open
**Created:** 2026-05-02
**Surfaced by:** Split of #21 (Groups B-E). This is **Group B** of `question-pipeline-remaining.md`.

## TL;DR

iOS only exposes three categories today (`nil` (All), `"adults"`, `"general"`). Backend already filters on richer category metadata via `QuestionRetriever._build_metadata_filters()`, but the picker has nothing to send. Add the new categories the question-generator now produces, and introduce an `age_appropriate` field so the picker can also gate kid-friendly content.

## What to implement

### B1. Extend the category picker

| Where | Change |
|---|---|
| `apps/ios-app/Hangs/Hangs/Utilities/Config.swift` | Add categories: `kids`, `wizarding-world`, `superheroes`, `disney`, `football`, `sports-mix` |
| `apps/ios-app/Hangs/Hangs/Models/QuizSettings.swift` | Surface the new options to the picker model |
| `SettingsView` (or wherever the picker renders) | Render new options; group themed vs core if it helps the UI |

No backend change — `QuestionRetriever._build_metadata_filters()` already filters on whatever the client sends.

### B2. Add `age_appropriate` to the `Question` model

| Where | Change |
|---|---|
| `packages/shared/quiz_shared/models/question.py` | New field `age_appropriate: Optional[str]` with values `all` \| `8+` \| `12+` \| `16+` |
| `apps/ios-app/Hangs/Hangs/Models/Question.swift` | Mirror as `ageAppropriate: String?` |
| Question-generator prompt templates (kids / themed / default) | Emit the field; default to `all` when not set |
| `/verify-api` | Run after the model change to confirm sync |

UI hookup for `age_appropriate` (filter chip / toggle in `SettingsView`) is in scope; persistence of the user's choice goes through the same path as the existing category filter.

## Acceptance

- iOS picker shows the new categories and they round-trip to the backend filter.
- `age_appropriate` is present on freshly generated questions and decoded by iOS without errors.
- `/verify-api` passes.
- Existing questions without `age_appropriate` still decode (Optional).

## Caveats

- **Stale paths in the original spec.** The `question-pipeline-remaining.md` doc references `apps/ios-app/CarQuiz/CarQuiz/...` — that's pre-rename. Use the `Hangs/...` paths above.
- Existing 69 questions in ChromaDB have no `age_appropriate` value. Don't backfill here; let #29 handle data hygiene.
- Don't add the field to the SQLite ratings table — `age_appropriate` is question metadata, not rating metadata.

## Related

- #21 (umbrella, superseded) — this issue carries Group B.
- #29 — Backfill for existing questions (Group D1).
- #30 — Batch generation that produces content for the new categories (Group E).
- `docs/issues/question-pipeline-remaining.md` — original spec; will be marked superseded.
