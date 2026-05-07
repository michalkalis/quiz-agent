# Image Question Critique Template

You are evaluating an image-based quiz question. Rate it on each dimension 1-10.

## Question Details

**Question text:** {question}
**Correct answer:** {correct_answer}
**Question type:** {image_subtype}
**Image prompt:** {image_prompt}

## Rating Dimensions

### Standard Dimensions
1. **Surprise Factor** (1-10): Does the answer create an "aha!" moment?
2. **Universal Appeal** (1-10): Works for international audience?
3. **Clever Framing** (1-10): Is the question engaging and well-phrased?
4. **Educational Value** (1-10): Does the player learn something?
5. **Answerability** (1-10): Can the player reason toward the answer?

### Image-Specific Dimensions
6. **Visual Clarity** (1-10): Will the generated image be clear and well-composed?
7. **Clue Balance** (1-10): 2-3 clues = 9-10, 1 clue = 5, 4+ clues = 6, 0 or 5+ = 3
8. **Verbal Fallback Quality** (1-10): Is the question text alone answerable without seeing the image?

## Calibration Anchors

### Visual Clarity
- **10**: "Oil painting of a green light at the end of a dock, mansion across a bay" — iconic, simple, evocative
- **7**: "Oil painting of a clock, a train station, and a snowy landscape" — clear but busy
- **4**: "Oil painting of abstract shapes suggesting movement" — too vague
- **1**: "A complex scene with many small details" — impossible to parse

### Clue Balance
- **10**: 2 strong clues that together point to one answer (green light + dock + mansion = Gatsby)
- **7**: 3 clues, slightly redundant
- **4**: 1 clue, basically random guessing
- **1**: 5+ clues, answer is immediately obvious

### Verbal Fallback
- **10**: "This atmospheric painting hints at a famous novel featuring a dock, a green light, and a mansion across a bay"
- **7**: "This painting hints at a famous work of American literature"
- **4**: "What does this image represent?"
- **1**: "Look at this picture and guess"

## Output Format

Return JSON:
```json
{{
  "visual_clarity": 8,
  "clue_balance": 9,
  "verbal_fallback_quality": 7,
  "surprise_factor": 8,
  "universal_appeal": 7,
  "clever_framing": 8,
  "educational_value": 7,
  "answerability": 8,
  "overall_score": 7.8,
  "reasoning": "Brief explanation of strengths and weaknesses"
}}
```
