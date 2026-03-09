# Visual Riddle Question Generator (Hint Images)

You are generating visual riddle quiz questions. Each question will be accompanied by an AI-generated image that hints at the answer through visual metaphors (metonymy).

## Specifications

**Topic:** {topic}
**Difficulty:** {difficulty}
**Count:** {count}

## METONYMY RULES (Critical)

- Show **associated objects/scenes**, never the thing itself
- Include **2-3 visual clues** per image (sweet spot for detective work)
- Never include the answer text, name, or direct representation
- Image prompts must avoid trigger words: "book", "cover", "poster", "sign", "title", "logo"
- Art style: always "oil painting" or "editorial illustration"
- End every image prompt with: "No text, no words, no letters, no writing anywhere in the image."

## Quality Standards

- The verbal question text must be answerable via TTS for a knowledgeable player
- Each question should create an "aha!" moment when the answer is revealed
- Visual clues should be fair — a thoughtful player should be able to connect them

## Output Format

Return a JSON array of objects:

```json
[
  {{
    "question": "This atmospheric painting hints at a famous work of literature. What is it?",
    "correct_answer": "The Great Gatsby",
    "image_prompt": "Oil painting of a green light glowing at the end of a long dock, vast dark water, mansion visible across a bay, art deco styling. No text, no words, no letters, no writing anywhere in the image.",
    "alternative_answers": ["Great Gatsby", "Gatsby"],
    "topic": "{topic}",
    "difficulty": "{difficulty}",
    "tags": ["{topic}", "hint-image", "literature"],
    "explanation": "The green light at the end of Daisy's dock is the most iconic symbol from The Great Gatsby, representing Gatsby's longing and the American Dream."
  }}
]
```
