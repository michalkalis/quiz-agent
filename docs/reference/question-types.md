# Question Types — Taxonomy & Data Shapes

Canonical reference for the question types the platform supports: their data
shapes, how generation routes patterns into types, how answers are evaluated,
and the implementation status across backend / iOS / design.

This consolidates what was previously scattered across the model, the generator,
the iOS app, and issue files. **All identifiers below are quoted from code** —
keep this doc in sync when those change.

## Source of truth

| Concern | File |
|---|---|
| `QuestionType` enum + answer fields | `packages/shared/quiz_shared/models/question.py` |
| Pattern → type routing | `apps/quiz-pack-api/app/generation/pattern_routing.py` |
| Answer evaluation (MCQ + text) | `apps/quiz-agent/app/evaluation/evaluator.py` |
| iOS decoding + UI dispatch | `apps/ios-app` — `Question.swift`, `QuestionView.swift`, `MCQOptionPicker.swift` |

## The five question types

```python
QuestionType = Literal["text", "text_multichoice", "audio", "image", "video"]
```

| Type | Answer UI | Status |
|---|---|---|
| `text` | Open-ended voice (speak the answer) | ✅ full production |
| `text_multichoice` | Tap A–D options (voice supported by backend) | ✅ backend · ⚠️ iOS tap-only |
| `image` | Image prompt + answer (subtype-driven) | ✅ quiz-pack-api · ⚠️ iOS partial |
| `audio` | — | ⏸ reserved, not implemented |
| `video` | — | ⏸ reserved, not implemented |

The iOS `QuestionType` enum decodes `.text`, `.textMultichoice` (raw
`"text_multichoice"`), and `.image`; `audio`/`video` are absent and fall back to
`.text` on decode.

## Answer data shapes

From `question.py` (lines ~86–98, 184–187):

```python
possible_answers: Optional[Dict[str, str]]   # MCQ only: {"a": "Paris", "b": "London", ...}
correct_answer:   Union[str, List[str]]      # a key ("a") OR a value ("Paris"); list for multi-select
alternative_answers: List[str]               # accepted variants: ["paris", "paris france"]
media_url:        Optional[str]              # audio/image/video asset
image_subtype:    Optional[str]              # "silhouette" | "blind_map" | "hint_image"
```

Notes:
- `correct_answer` may be stored **either** as the option key (`"a"`) **or** as
  the option value (`"Paris"`). The evaluator resolves both (see below).
- **Image subtypes live on the `image_subtype` field**, *not* in the pattern
  router. `silhouette` / `blind_map` / `hint_image` are values of
  `image_subtype` on an `image`-type question.
- The reasoning pattern that produced a question is recorded separately, on
  `GenerationProvenance.reasoning_pattern` (not on `Question` directly).

## Pattern → type routing (generation)

`pattern_routing.py` decides whether a generated question becomes plain `text`
or `text_multichoice`, based on its reasoning pattern:

```python
PATTERNS_TO_MCQ = frozenset({
    "true_false",
    "odd_one_out",
    "comparison_bet_older_larger",
    "year_guess",
})

def choose_question_type(pattern: str | None) -> Literal["text", "text_multichoice"]:
    if pattern and pattern in PATTERNS_TO_MCQ:
        return "text_multichoice"
    return "text"
```

| Pattern | → Type | Options shape |
|---|---|---|
| `true_false` | `text_multichoice` | 2 options (`{"a": "True", "b": "False"}`) |
| `comparison_bet_older_larger` | `text_multichoice` | 2 options |
| `odd_one_out` | `text_multichoice` | 4 options |
| `year_guess` | `text_multichoice` | 4 options |
| *(anything else / unknown)* | `text` | — (open-ended) |

`silhouette` / `blind_map` / `hint_image` are **not** routed here — they are
image subtypes, handled via `image_subtype`, not this function.

## Answer evaluation

`evaluator.py` → `_evaluate_mcq` (the MCQ fast-path; reached only when
`question.possible_answers` is truthy — otherwise text questions fall through to
LLM evaluation):

- Normalizes the user's answer and matches it against **both** the option key
  (`"a"`) **and** the option value (`"Paris"`).
- Resolves `correct_answer` to a key whether it is stored as a key or a value.
- Returns `("correct", 1.0)` or `("incorrect", 0.0)` — **no partial credit** for
  MCQ.

Because matching accepts the spoken value, **a voice answer to an MCQ is already
evaluable server-side** — the user can say "Paris" or "a".

## Implementation status

| Capability | Backend | quiz-pack-api | iOS | Design (`design/quiz-agent.pen`) |
|---|---|---|---|---|
| `text` open-ended voice | ✅ | ✅ | ✅ | ✅ Question-Waiting / Question-Recording |
| `text_multichoice` tap | ✅ | ✅ | ✅ `MCQOptionPicker` | ✅ Question-MultiChoice / Question-TrueFalse |
| `text_multichoice` **voice** | ✅ `_evaluate_mcq` | ✅ | ❌ **gap** | ✅ slim "listening" indicator on MCQ screens |
| `image` (silhouette/blind_map/hint_image) | ✅ | ✅ | ⚠️ partial | ❌ no screen yet |
| `audio` / `video` | ⏸ reserved | ⏸ | ❌ | ❌ |

### Known gap: MCQ voice path missing in iOS

On iOS, `QuestionView` dispatches multichoice questions to `mcqBody`, which
renders `MCQOptionPicker` — **tap-only**. The voice/mic path (mic affordance,
recording state, transcript confirmation) lives in `voiceBody`, which is
unreachable when `question.isMultipleChoice` is true. `submitMCQAnswer` sends the
selected option **value** (e.g. `"Paris"`) through the text-input endpoint.

So although the backend can evaluate a *spoken* MCQ answer, iOS never offers one.
The redesigned MultiChoice / TrueFalse screens show options **plus** a slim
"listening" indicator to signal that speaking the answer is (intended to be)
valid — closing this gap is a separate iOS implementation task.
