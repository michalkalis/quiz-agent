# Issue 128: Idiom-based question breaks in Slovak: "murder of crows" translated literally as "vražda"

**Triage:** bug · needs-triage
**Status:** Filed 2026-07-28 from the founder's TestFlight field test. Mechanism CONFIRMED in code (no language-portability guard exists at generation, scoring, or translation time); which specific corpus row was served is UNPROVEN without a prod query. Needs `/prepare-issue` before an agent run.
**Created:** 2026-07-28

## Symptom

TestFlight, Slovak session, kids category (two founder screenshots). The question served was:

> "Ako nazývate skupinu vrán, keď sa všetky spolu zdržujú – stádo, kŕdeľ alebo vražda?" — accepted answer: **"Vražda"**.

Founder: "is that really true? weird question, but if it's true then I guess OK."

It is not true in Slovak. The English original ("a murder of crows") is a genuine English collective noun; the Slovak collective noun for crows is **kŕdeľ**, and *vražda* means homicide. The Slovak text is fluent, grammatical and confidently wrong — the app taught the founder a fabricated fact and scored the correct real-world answer ("kŕdeľ") as wrong.

This is **not** [#107 — Slovak quiz serves untranslated English question](issue-107-slovak-english-question-leak.md): there translation *fails* and leaks raw English. Here translation *succeeds* — the fact itself does not survive translation.

## Root cause

**CONFIRMED as a class of gap** (three guards, none of which covers language-bound facts); **UNPROVEN** for this specific row.

1. **Generation rubric is scoped to orthography only, and most pipelines never mention the flag.** `Question.language_dependent` exists for exactly this job (`packages/shared/quiz_shared/models/question.py:128-131`), but its docstring scopes it to "wordplay, spelling, letter counts, acronyms". Only two prompts instruct the model to *set* it: `question_generation.md:78` and `question_generation_v2_cot.md:318,349` — both worded as "English spelling, letter counts, or wordplay that breaks in translation". A collective-noun idiom is none of those, so a rubric-compliant model correctly tags it `false`.
2. **The kids pipeline — the one the founder hit — has no rule text at all.** `question_generation_kids.md` (198 lines) contains `language_dependent` exactly once, at line 183, as a `false` value inside the JSON output example. Same for `question_generation_themed.md:160`, `question_generation_open.md:115`, `question_generation_entertainment.md:260`, `question_generation_v3_fact_first.md:240`, `question_rewrite.md:67`. A `false` example with no rule behind it biases the model toward `false` for everything.
3. **Nothing downstream can catch a mistag.** The 5-dimension scorer (`apps/quiz-pack-api/app/scoring/multi_model_scorer.py:129-157`) has no language-portability dimension (grep: zero hits for language/translat/idiom). `TranslationService.translate_question` (`apps/quiz-agent/app/translation/translator.py:170-244`) is a literal-translation LLM call with no fact-check and no refusal path; its caller `question_to_dict_translated` (`apps/quiz-agent/app/serializers.py:25-49`) holds the full `Question` but forwards only `question.question`, so `language_dependent` is never read at translation time.
4. **The only guard that exists is at retrieval, and custom packs skip it.** `question_retriever.py:239-241` and `:305-307` drop `language_dependent=True` for non-English sessions — but `:218-227` returns early for `session.pack_id`, deliberately dropping difficulty / review_status / language_dependent / category (comment: "a pack is a fixed bundle in its ordered language"). So even a correctly-tagged row is served unguarded inside a custom pack.

**What would settle which path produced it:** a direct prod query for the row text (`vrana`/`vražda`/`crow`) — whether it is one of the 31 approved shared-corpus rows, or a `pack_id`-scoped row. Not answerable from the repo; no local export contains this text.

## Scope of a fix

**(A) Stop generating them**
- Widen the `language_dependent` definition (model docstring + every generation prompt) beyond orthography to cover facts that hold only as an English lexical convention: collective nouns, idioms, proverbs, naming quirks whose literal translation changes the truth value.
- Give `question_generation_kids.md`, `_themed`, `_open`, `_entertainment`, `_v3_fact_first`, `question_rewrite.md` actual rule text — today they only carry a `false` JSON example.
- Add a language-portability probe to the scorer or a generation-time self-critique field: "would this still be true translated literally into a non-English language?"

**(B) Stop serving them**
- Thread `language_dependent` into `question_to_dict_translated` / `translate_question` as a fail-loud refusal or Sentry-flagged pass-through — defense in depth for rows mistagged upstream, mirroring the pattern #107 already established.
- Decide the custom-pack bypass (`question_retriever.py:218-227`): reinstate the filter for packs, or add an equivalent guard inside pack generation.
- Audit + pull: check whether this crow row is live (shared corpus or a pack) and retire it via the existing admin review-status endpoint; sweep the corpus for sibling idiom/collective-noun rows.

## Founder decisions needed

- **Widen the rubric everywhere, or patch narrowly?** Widening touches all seven generation prompts plus the kids pipeline (which has zero guidance today) and invalidates prior tagging; a narrow collective-noun/idiom rule is cheaper but leaves adjacent classes (proverbs, English-only naming conventions) open. Tradeoff: prompt-churn and regeneration cost vs. recurrence.
- **Should custom packs (#95) inherit the `language_dependent` filter?** They are exempt on purpose today for yield ("a pack is a fixed bundle in its ordered language"). Filtering costs pack completeness on paid content; not filtering means paid Slovak packs can carry untranslatable facts.
- **Retro-screen the existing 31-row approved corpus** for language-bound facts before the next non-English session, or accept the risk and fix forward only? The archive-to-31 was already a deliberate quality bar, so the sweep is small.

## Related

- [#107 — Slovak quiz serves untranslated English question](issue-107-slovak-english-question-leak.md) — same subsystem, opposite failure mode (fail-open to raw English). Not a duplicate; the #107 retry/Sentry path is the model for track (B).
- [#95 — custom quiz-pack client](issue-95-custom-pack-client.md) — owns the pack-session filter bypass.
- [#99 — question-formulation craft v2](issue-99-question-formulation-craft-v2.md) — owns the scorer rubric a portability dimension would join.
- [#72 — question fun/engagement redesign](issue-72-question-fun-engagement-redesign.md) — owns the current generation-prompt family.
- [#63 — question-quality review](issue-63-question-quality-review.md) — owns the 2026-07-27 live run (164 `pending_review`, `category=general` rows, not yet imported); worth ruling in/out as the source.

**Out of scope here:** translation quality/fluency in general, the #107 fallback path, the review/import gate for the 2026-07-27 batch, and any change to the freemium or pack-ordering flow.
