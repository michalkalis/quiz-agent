# Issue #3: Fix "suchy bodliak" — Translation Validation

## Status: DONE

## Root Cause
GPT-4o-mini translation returned just 2 words ("suchy bodliak") instead of translating the full question to Slovak. The translation output is blindly trusted with zero validation.

## What to fix

### 1. `apps/quiz-agent/app/translation/translator.py` (line 45-96)
Add output validation to `translate_question()`:
- **Length ratio**: if `len(translated) / len(original) < 0.3`, reject
- **Minimum length**: if `len(translated) < 15`, reject (no valid quiz question is 2 words)
- **Fallback**: on validation failure, return original English text + log warning
- Prompt: "You are a professional translator. Translate quiz questions to Slovak. Preserve the meaning and difficulty. Return ONLY the translated question, nothing else."
- `max_tokens=200` — check if this causes truncation

### 2. `apps/quiz-agent/app/api/deps.py` (lines 160-171)
First question translation path — `question_to_dict_translated()`. Add validation after translation call.

### 3. `apps/quiz-agent/app/quiz/flow.py` (lines 305-318)
Subsequent questions path — `_question_to_dict_translated()`. Same validation needed.

### 4. Consider: improve the translation prompt
- Add "The output must be a complete question sentence"
- Add "Do NOT answer the question, only translate it"

## Verification
- Start quiz in Slovak, play 20+ questions
- Check backend logs for any translation validation warnings
- Test with edge cases: short questions, questions about plants/nature
- Verify fallback to English works when translation fails validation
