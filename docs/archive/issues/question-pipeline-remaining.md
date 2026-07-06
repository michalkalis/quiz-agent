# Question Pipeline — Remaining Tasks

**Triage:** enhancement · superseded
**Status:** Superseded 2026-05-02 — content split into focused issues. See "Issue split" below. Kept for archaeology only; do not extend.

## Issue split (2026-05-02)

| Was | Now | Status |
|---|---|---|
| Group A | (shipped 2026-04-15, commit `c7b0743`) | done |
| Group B (iOS category picker + `age_appropriate`) | [#28](issue-28-ios-category-picker-expansion.md) | ready-for-agent |
| Group D1 (backfill existing questions) | [#29](issue-29-backfill-existing-questions.md) | ready-for-agent |
| Group E (batch generate new categories) | [#30](issue-30-batch-generate-categories.md) | ready-for-agent (gate on #28 + #29) |
| Group C (multi-model A/B + analytics) | **deferred** | data-blocked: needs ≥50 user ratings before C2/C3 are meaningful. Revisit after #30 batches accumulate ratings. |
| Group D2 (rating feedback loop) | **deferred** | same — needs ratings volume |
| Group D3 (difficulty calibration) | **deferred** | same — needs correctness telemetry first |

The original umbrella `#21` is closed in favor of #28/#29/#30. Deferred items will get their own issues when the data prerequisite clears.

---

## What Was Done (commit c7b0743)

Implementované v predchádzajúcom vlákne:

| # | Task | Stav | Kľúčové súbory |
|---|------|------|----------------|
| 1 | WebSearchSource + Tavily | DONE | `apps/question-generator/app/sourcing/web_search_source.py` |
| 2 | `generated_by` tracking (backend + iOS) | DONE | `apps/quiz-agent/app/serializers.py`, `Question.swift`, `ResultView.swift` |
| 3 | FactVerifier service | DONE | `apps/question-generator/app/verification/fact_verifier.py` |
| 4 | Verification API endpoints | DONE | `apps/question-generator/app/api/routes.py` (`POST /verify`, `/verify/batch`) |
| 5 | Multi-model scoring + DB | DONE | `apps/question-generator/app/scoring/multi_model_scorer.py`, `sql_client.py` (`model_scores` tabuľka) |
| 6 | Kids prompt | DONE | `apps/question-generator/prompts/question_generation_kids.md` |
| 7 | Themed prompt | DONE | `apps/question-generator/prompts/question_generation_themed.md` |

---

## What Remains

### Group A: Skills (Claude Code workflow) — DONE

**A1. Vylepšiť `/generate-questions` skill** — DONE
- Pridané `--category` a `--theme` flagy
- Auto-verify cez FactVerifier po generovaní
- Prompt selection: kids/themed/default podľa kategórie
- `generated_by` tagging v generation_metadata

**A2. Nový `/score-questions` skill** — DONE
- Nový: `.claude/skills/score-questions/SKILL.md`
- 5 dimenzií (CS, S/D, Tell, DrF, CF), approve/revise/reject
- Voliteľné `--save-to-db` pre model_scores tabuľku

**A3. Vylepšiť `/verify-questions` skill** — DONE
- Batch verifikácia cez FactVerifier (`POST /api/v1/verify/batch`)
- Fallback na manuálny WebSearch ak service nebeží
- Claude sanity check + deep-dive len na flagnuté otázky

### Group B: iOS Category Picker

**B1. Rozšíriť category picker v iOS**
- `apps/ios-app/CarQuiz/CarQuiz/Utilities/Config.swift` — pridať nové kategórie
- Aktuálne len: nil (All), "adults", "general"
- Nové: "kids", "wizarding-world", "superheroes", "disney", "football", "sports-mix"
- UI: `SettingsView` alebo kde sa vyberá kategória
- Backend filtering už funguje cez `QuestionRetriever._build_metadata_filters()`

**B2. Pridať `age_appropriate` do Question modelu**
- `packages/shared/quiz_shared/models/question.py` — nové pole `age_appropriate: Optional[str]` (`all | 8+ | 12+ | 16+`)
- `Question.swift` v iOS — pridať `ageAppropriate: String?`
- Po zmene → spustiť `/verify-api`

### Group C: A/B Testing & Analytics

**C1. Multi-model generovanie experiment**
- Vygenerovať rovnaký set otázok (10 general, 10 kids) cez:
  - Claude Opus 4.6 (cez Claude Code — zadarmo)
  - Gemini 2.5 Pro (cez API — `GOOGLE_API_KEY` v `.env`)
  - GPT-4.1 (cez API — `OPENAI_API_KEY` v `.env`)
- Tagovať `generated_by` na každej otázke
- Importovať do ChromaDB, miešať v sessions
- Existujúci `MultiModelScorer` (`apps/question-generator/app/scoring/multi_model_scorer.py`) podporuje OpenAI a Anthropic, treba pridať Google

**C2. Analytics script**
- Nový: `scripts/analyze_model_performance.py`
- Query `question_ratings` (user feedback) JOIN s ChromaDB `generation_metadata.model`
- Query `model_scores` (automated scores) pre koreláciu
- Output: ranking modelov pre generovanie aj scoring
- Zatiaľ nemá dosť dát — spustiť až po nazbieraní 50+ user ratings

**C3. Pridať `generated_by` do `question_ratings` tabuľky**
- `packages/shared/quiz_shared/database/sql_client.py`
- ALTER TABLE alebo migrácia: `generated_by TEXT` column
- Update `add_rating()` a `_db_to_rating()` metódy
- Zjednodušuje analytics (netreba join s ChromaDB)

### Group D: Backfill & Feedback Loop

**D1. Backfill existujúcich 69 otázok**
- Spustiť FactVerifier na všetky existujúce otázky
- Script: `scripts/backfill_sources.py` (už existuje, treba rozšíriť)
- Doplniť `source_url`, `source_excerpt` do ChromaDB
- Flagovať fakticky chybné na review
- Vyžaduje bežiaci question-generator server na `localhost:8003`

**D2. Rating feedback loop**
- `apps/question-generator/app/generation/prompt_builder.py` — query ratings DB
- Otázky s rating ≤2 → inject do `user_bad_examples`
- Otázky s rating ≥4.5 → pridať do `data/examples/gold_standard.json`
- Nový script: `scripts/sync_ratings_to_examples.py`

**D3. Difficulty calibration**
- Trackovať actual correctness rates per question
- `apps/quiz-agent/app/quiz/flow.py` — po evaluation uložiť (question_id, was_correct) do SQLite
- Script na flag: ak "medium" má 95% úspešnosť → recategorize na "easy"

### Group E: Batch Generation

**E1. Batch generovanie otázok pre nové kategórie**
- Až keď skills (Group A) a prompty (DONE) sú hotové
- Cieľ: 50 otázok per hlavná kategória (kids, general, adults), 30 per themed
- Použiť `/generate-questions --category kids --count 20` viackrát
- Každý batch → verify → score → approve → import

---

## Odporúčané poradie

1. **Group A** (skills) — závisí na DONE taskoch, odomkne workflow
2. **Group B** (iOS categories) — nezávislé, malý scope
3. **Group D1** (backfill) — fix existujúcich 69 otázok
4. **Group E** (batch gen) — naplniť kategórie obsahom
5. **Group C** (analytics) — až po nazbieraní dát
6. **Group D2-D3** (feedback loop) — až po nazbieraní ratings

---

## Kontext & Rozhodnutia

- **Generovanie cez Claude Code** (nie API) — už zaplatený, najlepší model, žiadny iný nie je znateľne lepší
- **Fact verification: Tavily + Gemini Flash** — Tavily 93.3% SimpleQA, $0.003/query; Gemini Flash $0.30/$2.50
- **Legal: Themed kategórie** — fair use pre trivia o publikovaných dielach; nepoužívať trademarked mená v branding
- **Realtime custom kategórie = TODO na budúcnosť** — plánované ale nie priorita
- Plný pôvodný plán: `.claude/plans/expressive-tickling-quail.md`
