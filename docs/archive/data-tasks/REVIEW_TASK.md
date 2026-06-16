# Gold Standard Review Task

## What to do

Review and curate `data/examples/gold_standard.json` — the 50-question calibration library used by the question generation system. Every question in this file becomes an example shown to the LLM during generation, so quality here directly affects output quality.

## How to start this review

Open a new Claude Code session and paste:

```
Review the gold standard examples at data/examples/gold_standard.json. For each of the 50 questions, show me the question and answer, and I'll rate it keep/fix/replace. Present them in batches of 10 so I can work through them efficiently. For each batch, also note any factual concerns from the automated review below.
```

## Known issues from automated review

### Factually wrong (must fix)
- **Q3** (apron/Egyptian butchers): Unverifiable origin story, likely fabricated
- **Q25** (France time zones): Answer says 11, actually 12
- **Q35** (ants vs humans weight): Debunked by 2022 research — ants are ~20% of human mass, not equal

### Accuracy concerns (should fix)
- **Q6** (banana DNA): Should say "60% of genes" not "60% of DNA"
- **Q16** (lonsdaleite): Called "gemstone" but it's a mineral; hardness claim is theoretical
- **Q38** (potato chips): Origin story is disputed legend, not established fact
- **Q15** (sodium/potassium): Two acceptable answers — should pick one

### Weakest questions (consider replacing)
- **Q46** (body is 60% water): Too well-known
- **Q45** (bat is only flying mammal): Children's trivia level
- **Q32** (Coca-Cola as medicine): Overexposed "fun fact"
- **Q21** ("incorrectly" riddle): Too well-known
- **Q41** (octopus 3 hearts 9 brains): Overexposed internet fact

### Topic gaps
- Zero questions about: music, arts, literature, film
- Only 1 sports question (the weakest one)
- Western-centric bias — limited non-Western content

## File locations
- Gold standard: `data/examples/gold_standard.json`
- Anti-patterns: `data/examples/anti_patterns.json`
- Generation prompt that uses these: `apps/question-generator/app/generation/examples.py`
- Dynamic sampling logic: `apps/question-generator/app/generation/prompt_builder.py`
