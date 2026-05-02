---
name: generate-questions
description: Generate high-quality quiz questions using Claude and save for review
allowed-tools: Read, Write, Bash, Glob, Grep, AskUserQuestion
model: opus
argument-hint: "[count] [difficulty] [topics] [--category kids|adults|...] [--theme \"Name\"] [--fact-first]"
---

# Generate Quiz Questions

Generate high-quality pub quiz questions directly in this Claude Code session, following the project's established quality criteria.

## Instructions

### 1. Parse Arguments

Parse `$ARGUMENTS` for parameters. Positional args are backward-compatible; named flags are optional:

| Param | Type | Default | Examples |
|-------|------|---------|---------|
| count | positional | `10` | `15`, `20`, `5` |
| difficulty | positional | `mixed` | `easy`, `medium`, `hard`, `mixed` |
| topics | positional | broad mix | `"science,history"`, `"nature"` |
| `--category` | flag | `adults` | `kids`, `adults`, `general`, `wizarding-world`, `superheroes`, `disney`, `football`, `sports-mix` |
| `--theme` | flag | none | `"Harry Potter"`, `"Marvel"`, `"Premier League"` |
| `--fact-first` | flag | off | (no value, just the flag) |

Examples of `$ARGUMENTS`:
- `` (empty) → 10 mixed questions, adults category
- `10 hard science` → 10 hard science questions, adults (backward compatible)
- `5 --category kids` → 5 mixed kids questions
- `10 medium --theme "Harry Potter" --category wizarding-world` → 10 medium HP questions
- `15 --category football --theme "Premier League"` → 15 Premier League football questions
- `20 --fact-first` → 20 mixed fact-grounded questions

When `--theme` is set but `--category` is not, infer category from theme:
- Harry Potter, Fantastic Beasts → `wizarding-world`
- Marvel, DC, Spider-Man → `superheroes`
- Disney, Pixar → `disney`
- Premier League, Champions League, World Cup → `football`
- Olympics, Mixed sports → `sports-mix`
- Otherwise → `general`

### 2. Select Prompt & Read Quality Guidelines

Based on category and theme, read the appropriate prompt file:

**If `--theme` is provided:**
- Read `apps/question-generator/prompts/question_generation_themed.md`
- Mentally substitute `{theme}` with the provided theme name throughout
- Follow its themed Pattern Library, audience balance, and structural diversity rules
- If `--category` is also `kids`: additionally read and enforce the safety rules from `apps/question-generator/prompts/question_generation_kids.md` (safety rules are non-negotiable overlay)

**If `--category` is `kids` (without theme):**
- Read `apps/question-generator/prompts/question_generation_kids.md`
- Follow ALL safety rules, language rules, and kids patterns
- Use simple vocabulary (8-year-old level), max 2-sentence questions
- Include `explanation` field (mandatory for kids)

**Otherwise (default — adults/general):**
- Read `apps/question-generator/prompts/question_generation_v2_cot.md`

**Always also read:**
- `apps/question-generator/prompts/question_critique.md` — 6-dimension scoring rubric

### 3. Generate Questions

Follow the selected prompt's structured process for EACH question:

**Step 1: REASONING** — Pick a pattern from the relevant Pattern Library. Think about why it's interesting and check the Boring Detector.

**Step 2: GENERATE** — Write the question using that pattern.

**Step 3: SELF-CRITIQUE** — Rate honestly on the prompt's dimensions (1-10 each).

**Step 4: DECISION** — Keep if score >= 8.0, regenerate if below.

### Constitutional Principles (MUST follow)

1. **Delight over Memorization** — Joy, surprise, wonder. Not rote memory.
2. **Universal over Niche** — International audience. No US-specific, no English wordplay.
3. **Narrative over Facts** — Tell a story. Not isolated facts.
4. **Clever over Straightforward** — Creative framing. Never "What is..." or "Who wrote...".

### Boring Detector (REJECT if any apply)

- "What is the capital of...", "Who wrote...", "What year did..."
- Pure memorization (chemical symbols, dates, names)
- Niche references (video games, obscure films, specific sports stats)
- US-specific content (unless explicitly requested)
- Language-dependent wordplay (puns, anagrams that only work in English)
- Predictable answers from question wording

### 4. Generate MORE than requested, keep the best

Generate ~30-50% more candidates than the requested count. Score them all, then select only the top N that score 8.0+. If difficulty is "mixed", aim for roughly: 20% easy, 50% medium, 30% hard.

### 5. Save Output

Save the questions to `data/generated/claude_batch_NNN.json` where NNN is the next available number. Use this exact JSON structure:

```json
{
  "questions": [
    {
      "question": "Question text?",
      "type": "text",
      "correct_answer": "Answer",
      "possible_answers": null,
      "alternative_answers": ["answer", "answer variant"],
      "topic": "Topic",
      "category": "<category flag value>",
      "difficulty": "medium",
      "tags": ["tag1", "tag2"],
      "language_dependent": false,
      "source": "generated",
      "source_url": "https://en.wikipedia.org/wiki/...",
      "source_excerpt": "Brief 1-2 sentence excerpt confirming the answer.",
      "review_status": "pending_review",
      "generation_metadata": {
        "model": "claude-opus-4-7",
        "provider": "anthropic",
        "prompt_version": "<v2_cot | kids | themed>",
        "stage": "claude_code_session",
        "theme": "<theme name if --theme used, omit otherwise>",
        "reasoning": { "pattern_used": "...", "why_interesting": "...", "universal_appeal": "...", "boring_check": "..." },
        "self_critique": { "surprise_factor": 9, "universal_appeal": 9, "clever_framing": 9, "educational_value": 9, "clarity": 9, "factual_accuracy": 9, "overall_score": 9.0, "reasoning": "..." },
        "ai_score": 9.0
      }
    }
  ],
  "metadata": {
    "model": "claude-opus-4-7",
    "provider": "anthropic",
    "generated_at": "<ISO timestamp>",
    "total_generated": 13,
    "total_selected": 10,
    "pipeline": "claude_code_session",
    "prompt_version": "<v2_cot | kids | themed>",
    "category": "<category>",
    "theme": "<theme or null>"
  }
}
```

For **kids** questions, also include:
- `"explanation": "Fun explanation for kids"` in each question object

For **themed** questions, also include:
- `"explanation": "Interesting context about the theme"` in each question object

### 6. Auto-Verify with FactVerifier

After saving, automatically verify all generated questions using the FactVerifier service.

1. Check if the service is running:
   ```bash
   curl -s -o /dev/null -w '%{http_code}' http://localhost:8003/health
   ```
   If NOT running (non-200), skip verification and note: "FactVerifier not running. Run `/start-local questions` to enable auto-verification, or run `/verify-questions` later."

2. If running, send the batch:
   ```bash
   .venv/bin/python -c "
   import json, urllib.request
   with open('data/generated/claude_batch_NNN.json') as f:
       data = json.load(f)
   payload = {'questions': [{'question': q['question'], 'correct_answer': str(q['correct_answer']), 'id': q.get('id', f'q_{i}'), 'topic': q.get('topic', '')} for i, q in enumerate(data['questions'])]}
   req = urllib.request.Request('http://localhost:8003/api/v1/verify/batch', data=json.dumps(payload).encode(), headers={'Content-Type': 'application/json'})
   resp = urllib.request.urlopen(req, timeout=300)
   print(resp.read().decode())
   "
   ```

3. Parse the response. Flag any questions with verdict `likely_wrong` or `wrong`:
   - Print a **WARNING** for each with the question text, claimed answer, and verifier's notes
   - Suggest removing or fixing before import

4. Show inline summary: `Fact Verification: 9/10 verified, 0 wrong, 1 uncertain`

### 7. Present Results

Show a ranked summary table of the selected questions with verification status:

```
  #  Score  Diff    Category  Verified  Question
  1   9.3   hard    adults    OK        Which creature has survived...
  2   9.0   medium  adults    OK        Which classic board game...
  3   8.5   easy    kids      ??        What amazing animal...
```

Verification column: `OK` = verified/likely_correct, `??` = uncertain, `WARN` = likely_wrong/wrong, `--` = not checked

### 8. Ask About Import

After presenting results, ask the user if they want to import to ChromaDB. If yes, run:

```bash
.venv/bin/python scripts/generate_questions_claude.py -i data/generated/claude_batch_NNN.json --count <N> --import-to-db
```

Then remind them to start the question generator if not already running:
```bash
# /start-local questions
```
And visit `http://localhost:8003/web/review` to rate them.

### 9. Suggest Next Steps

- If any questions were flagged or FactVerifier was not running: "Consider running `/verify-questions data/generated/claude_batch_NNN.json` for thorough verification."
- "Run `/score-questions data/generated/claude_batch_NNN.json` to score on engagement dimensions (Conversation Spark, Tellability, etc.)"

## Optional: Fact-First Mode (Source-Grounded Generation)

When the user passes `--fact-first`, the pipeline adds a Stage 0 before generation:

### Stage 0: FACT SOURCING
1. Import and run `FactSourcer` from `apps/question-generator/app/sourcing/`
2. Gather facts from Wikipedia (en, sk, cs), Open Trivia DB, and news RSS feeds
3. Deduplicate and collect ~30+ facts relevant to requested topics
4. Pass these facts into the V3 fact-first prompt template (`prompts/question_generation_v3_fact_first.md`)

### How it changes the pipeline
- **Stage 1 (GENERATE)** uses the V3 prompt with `{facts_section}` injected, instructing the LLM to ONLY use provided facts
- **Stage 2 (CRITIQUE)** and **Stage 3 (SELECT)** remain unchanged
- **Stage 4 (OUTPUT)** tags metadata with `"pipeline": "fact_first"` and `"prompt_version": "v3_fact_first"`
- Questions include `source_url` and `source_excerpt` from the sourced facts

### When to use fact-first mode
- When factual accuracy is paramount (reduces hallucination risk)
- When you want questions grounded in verifiable sources
- When sourcing from current events or trending topics
- When generating questions about specific cultural topics (SK/CZ Wikipedia)

### CLI usage
```bash
.venv/bin/python scripts/generate_questions_claude.py --fact-first --count 10 --topics "science,history"
```

### In Claude Code session
When the user requests fact-first mode, run the sourcing step first, then use the sourced facts as the basis for question generation, following the same quality criteria as standard mode.

## Important

- **Factual accuracy is critical.** Only include facts you are confident about. If unsure, skip the question — never guess.
- **Avoid duplicating questions** already generated. Check existing files in `data/generated/` before finalizing.
- **alternative_answers** should include lowercase variants and common alternative phrasings.
- **language_dependent** should be `true` only if the question fundamentally relies on English spelling/wordplay.
- **source_url / source_excerpt** — Include when you're confident of a reliable source. These power the iOS app's SourceCard on the result screen. If unsure, leave null and let `/verify-questions` find them.
