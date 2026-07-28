# Issue 126: Correct answer marked wrong when the transcript carries a trailing period

**Triage:** bug · needs-triage
**Status:** Filed 2026-07-28 from the founder's TestFlight field test (older build). The punctuation theory in the title is REFUTED in code; the real mechanism is that answers are scored in English against a Slovak-spoken transcript — CONFIRMED as a code path, but which of the two branches fired for the two screenshots is UNPROVEN without session logs. Needs `/prepare-issue` before an agent run.
**Created:** 2026-07-28

## Symptom

TestFlight, Slovak session, two founder screenshots of the result screen, both verdict **MISSED IT**:

- "YOU SAID: **Pravda.**" vs "THE ANSWER: **Pravda**"
- "YOU SAID: **Diamant.**" vs "THE ANSWER: **Diamant**"

Founder: "Did it reject the answer because of the period? It happened several times, but sometimes it DID accept an answer with a period. It is pointless to put periods on short answers, but it should still evaluate the answer as correct."

The two strings differ only by a trailing period, which is what the founder saw. The intermittency ("sometimes accepted") is the load-bearing detail.

## Root cause

**The trailing period is NOT the cause — REFUTED.** `normalize_text()` (`packages/shared/quiz_shared/utils/text_normalization.py:28`) strips `.,!?;:'"()-` before *every* backend comparison: the exact-match fast path (`apps/quiz-agent/app/evaluation/evaluator.py:74`), the alternative-answers loop (`:79-81`) and the MCQ path (`:120,126`). The iOS pre-match (`MCQTranscriptMatcher.normalize`, `apps/ios-app/Hangs/Hangs/Utilities/MCQTranscriptMatcher.swift:70-79`) reduces every non-alphanumeric run to a space, so it also ignores the period. The period is a real ElevenLabs Scribe auto-punctuation artifact that is never stripped before display (`RecordingCoordinator+Streaming.swift`, `ElevenLabsSTTService.swift:203-211`), but it is cosmetic.

**CONFIRMED mechanism — the answer is scored in English while the player speaks Slovak.** Only the question *sentence* is translated. `question_to_dict_translated()` overwrites `question_dict["question"]` and nothing else (`apps/quiz-agent/app/serializers.py:36-46`), and `PublicQuestion` ships `possible_answers` verbatim (`packages/shared/quiz_shared/models/question.py:491-492`) — so MCQ options reach the client in English. Scoring runs on the canonical English row: `flow.py:117` fetches the question with no language parameter, `evaluate()` is called at `flow.py:140-144`, and `_translate_correct_answer` runs only *after* scoring, for display and TTS (`flow.py:146-150, 369-378`). `translator.py` has no translation path for option values at all. Two branches follow, and both reproduce the founder's screenshots:

- **MCQ / True-False branch (deterministic failure).** True/False options are generated in English by design (`apps/quiz-pack-api/app/generation/advanced_generator.py:140-142`, `{'a': 'True', 'b': 'False'}`). A Slovak "Pravda" cannot match key `a`/`b` or value `True`/`False`, and `_evaluate_mcq()` (`evaluator.py:104-145`) has **no LLM fallback and no partial credit** — it returns `("incorrect", 0.0)` every time. The iOS matcher cannot rescue it either: its `letterNames`/`numberWords` tables only cover Slovak ordinals and letter-names (`MCQTranscriptMatcher.swift:84-97`), never a translated option *value*, so `match()` returns nil and the raw Slovak transcript is submitted (`RecordingCoordinator+Streaming.swift:107-124`). The existing pinned test `TestMCQEvaluatorSlovakGap` (`apps/quiz-agent/tests/test_mcq_evaluator.py:89-111`) documents the backend-English contract, but only for ordinals/letter-names — translated values are outside what it covers.
- **Open-text branch (intermittent failure).** With no `possible_answers`, the miss falls through to `_llm_evaluate()` (`evaluator.py:87-102, 147-229`) — gpt-4o-mini at temperature 0.3 whose prompt (`:171-192`) never mentions cross-language answers. Whether "Diamant" is accepted against "Diamond" is undefined model behaviour, which is exactly the "sometimes it DID accept it" the founder reports.

**UNPROVEN:** which branch produced each screenshot. Settling it needs the Sentry/session record for that TestFlight run (question id + `type` + `possible_answers` for the two questions) — not consulted at triage time.

## Scope of a fix

**(A) Score the answer in the session's language** — the actual defect.
- Decide the direction (see founder decision below) and apply it consistently to the MCQ path *and* the open-text path; a fix that only covers one branch leaves half the symptom alive.
- Whatever ships must also cover what the client displays: today a Slovak player can be shown English `True`/`False` buttons, which is its own UX defect and is what pushes them to answer in Slovak prose.
- Make cross-language equivalence an explicit, tested rule for `_llm_evaluate`, not incidental model behaviour, so the intermittency has a regression test.
- Extend or replace the `TestMCQEvaluatorSlovakGap` contract deliberately — it currently *pins* English-only backend MCQ and will fail loud, by design, when this is fixed.

**(B) Cosmetic papercut** — strip trailing sentence punctuation from the transcript before it is shown as "YOU SAID". Independent of (A); does not change any verdict. Only worth shipping if it is cheap.

## Founder decisions needed

- **Should MCQ option text (True/False and every other option) be translated into the session's spoken language at all?** Today only the question sentence is translated and options stay English — a visible inconsistency in a Slovak session, and a product call, not an implementation detail.
- **If yes, which side gets translated?** Translate the *options* (one more LLM translation surface plus a new cache kind, paid once per question and cached) versus translate the *player's spoken answer back to English* before scoring (keeps the corpus single-language, but adds a call on every non-English answer — measurable against the per-answer cost model). Tradeoff is one-off cached cost vs. recurring per-answer cost.
- **Ship (B) regardless?** It is the thing the founder actually noticed, and it is near-free.

## Related

- [#107 — Slovak quiz serves untranslated English question](issue-107-slovak-english-question-leak.md) — same translation seam, but scoped to question *text* only; it does not cover answer/option values, which is this issue.
- [#128 — idiom questions break in translation](issue-128-idiom-questions-break-in-translation.md) — same field test, same Slovak-session translation area, different failure (a fabricated fact rather than a mis-scored answer). Corpus/generation-side; keep separate.
- [#125 — MCQ UI minimal redesign](issue-125-mcq-ui-minimal-redesign.md) — touches how options are presented; if option translation ships, the two overlap on the client.
- **Out of scope here:** STT accuracy and the ElevenLabs engine choice ([#120 — transcriber abstraction + Slovak commands](issue-120-transcriber-abstraction-slovak-commands.md)), voice *command* recognition ([#122 — voice command feedback and lexicon](issue-122-voice-command-feedback-and-lexicon.md)), and any change to how questions are generated.
