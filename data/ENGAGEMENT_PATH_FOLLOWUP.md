# Follow-Up: Engagement Path Improvements

## Status: What's Done

The core prompt and data changes are complete and uncommitted on the `develop` branch:

### Completed Changes (5 files, ~530 lines)

| File | Change |
|------|--------|
| `data/examples/gold_standard.json` | All 50 rated, 3 facts fixed, 5 weak questions replaced with reasoning/estimation, `engagement_type` added to all |
| `apps/question-generator/prompts/question_generation_v2_cot.md` | Principle 5, Patterns 11-13, diversity rule, monotony detector, answerability self-critique |
| `apps/question-generator/prompts/question_generation_v3_fact_first.md` | Same additions (abbreviated) |
| `apps/question-generator/prompts/question_critique_v2.md` | Dimension 7 (Answerability) with calibration anchors, Dead-End red flag |
| `data/examples/anti_patterns.json` | 4 "interesting but unguessable" anti-patterns |

### Gold Standard Distribution
- Before: ~46 recall / ~4 reasoning
- After: 31 recall / 9 reasoning / 10 estimation (38% engagement-path)

---

## What's Left: Issues Discovered During Implementation

### Issue 1: GPT-4o Copies Few-Shot Examples Verbatim (HIGH PRIORITY)

**Problem:** When generating via `AdvancedQuestionGenerator` (OpenAI), GPT-4o copies gold standard examples word-for-word instead of using them as patterns. In a test batch of 10, 8/10 were verbatim copies from the gold standard.

**Root cause:** `examples.py:load_gold_standard()` injects 10 full Q+A pairs. GPT-4o treats these as a menu, not as inspiration.

**Proposed fixes (pick one or combine):**
1. **Add explicit instruction** to the prompt: "NEVER reproduce any example question. Generate entirely NEW questions inspired by these patterns."
2. **Reduce example count** from 10 to 5, and strip the answer from some examples (show pattern only)
3. **Separate pattern from example:** Show patterns as templates without full Q+A, then show 3-4 complete examples separately
4. **Post-generation dedup:** Add a dedup step in `_generate_batch()` that filters out any question with >80% text overlap with gold standard entries

**Files to modify:**
- `apps/question-generator/app/generation/examples.py` — change `load_gold_standard()` format
- `apps/question-generator/app/generation/advanced_generator.py` — add dedup step
- `apps/question-generator/prompts/question_generation_v2_cot.md` — add "do not copy" instruction

### Issue 2: Self-Critique Metadata Not Parsed (MEDIUM PRIORITY)

**Problem:** The `_parse_response()` method in `advanced_generator.py` doesn't extract `reasoning` or `self_critique` fields from GPT-4o's response. All pattern metadata shows "unknown" and self-critique scores show "?".

**Root cause:** GPT-4o likely returns a JSON response where the model includes these fields but the parser's `_dict_to_question()` only extracts them if present in the parsed dict. The issue is likely that GPT-4o wraps responses differently (markdown code blocks, extra text) causing the JSON extraction (`content.find('{')` to `content.rfind('}')`) to miss nested structures.

**Debug approach:**
1. Add `--verbose` logging to print raw GPT-4o response before parsing
2. Check if `reasoning` and `self_critique` keys exist in parsed `q_data` dict
3. Verify the new `answerability` field in self_critique is being passed through

**Files to modify:**
- `apps/question-generator/app/generation/advanced_generator.py` — `_parse_response()` and `_dict_to_question()`

### Issue 3: "Which..." Frequency Still Above Target (MEDIUM PRIORITY)

**Problem:** Target was ≤30% "Which..." starters. Test batch showed 50%. The prompt now includes the Structural Monotony red flag, but the model isn't complying.

**Proposed fixes:**
1. **Stronger instruction:** Move the 30% rule from the Boring Detector section to the top-level generation instructions (more prominent placement)
2. **Add post-generation check:** If >30% start with "Which", regenerate the worst offenders
3. **Diversify question openers in examples:** Rewrite some gold standard questions to start with different words (e.g., "How many...", "If you...", "What happens when...", "True or false:...")

### Issue 4: Run Proper Control vs Treatment Comparison (LOW PRIORITY)

**Problem:** No API key for Anthropic was available, so we couldn't run the Claude-based generator which produces better results. The GPT-4o test was compromised by the example-copying issue.

**To run comparison:**
```bash
export ANTHROPIC_API_KEY=sk-ant-...
# Control: generate with OLD prompts (git stash changes first)
python scripts/generate_questions_claude.py --count 10 --difficulty medium --best-of-n 0 --output data/generated/comparison_v4_control.json

# Treatment: generate with NEW prompts (git stash pop)
python scripts/generate_questions_claude.py --count 10 --difficulty medium --best-of-n 0 --output data/generated/comparison_v4_treatment.json
```

Then compare:
- Pattern diversity (≥3 reasoning patterns in treatment)
- "Which..." frequency (≤30% in treatment)
- Answerability scores in critique output (new dimension present)
- Overall quality scores

### Issue 5: Answerability Score in Quality Ratings Model (LOW PRIORITY)

**Problem:** The `Question.quality_ratings` dict in `_dict_to_question()` only captures 4 self-critique dimensions. The new `answerability` field won't be stored unless the parsing code is updated.

**Fix:** In `advanced_generator.py:_dict_to_question()`, add:
```python
quality_ratings = {
    "surprise_factor": self_critique.get("surprise_factor", 0),
    "universal_appeal": self_critique.get("universal_appeal", 0),
    "clever_framing": self_critique.get("clever_framing", 0),
    "educational_value": self_critique.get("educational_value", 0),
    "answerability": self_critique.get("answerability", 0),  # ADD THIS
}
```

**Files to modify:**
- `apps/question-generator/app/generation/advanced_generator.py` — `_dict_to_question()`

---

## Recommended Execution Order

1. **Commit current changes** — the prompt/data work is complete and correct
2. **Fix Issue 5** (answerability in quality_ratings) — trivial 1-line fix
3. **Fix Issue 1** (example copying) — highest impact on generation quality
4. **Fix Issue 2** (metadata parsing) — enables proper pattern tracking
5. **Fix Issue 3** (Which... frequency) — depends on #1 being fixed first
6. **Run Issue 4** (comparison) — validates all fixes work end-to-end

---

## Verification Checklist

After all fixes:
- [ ] Generate 10 questions — 0 should be copies of gold standard
- [ ] Pattern diversity: ≥3 different reasoning patterns (7-13) in batch
- [ ] "Which..." frequency: ≤30%
- [ ] Answerability scores appear in both self-critique and external critique
- [ ] Pattern metadata populated (not "unknown") for all questions
- [ ] Mean answerability score ≥6 for the batch
- [ ] `data/generated/comparison_v4_engagement.json` has clean treatment results
