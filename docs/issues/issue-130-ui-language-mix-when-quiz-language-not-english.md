# Issue 130: UI stays English when the quiz language is Slovak — mixed-language app

**Triage:** ux · needs-triage
**Status:** Filed 2026-07-28 by the founder. No analysis, no research done yet — deliberately parked as a research + design task. Needs `/research` on best practices, then `/prepare-issue`.
**Created:** 2026-07-28

## Symptom

The user sets the quiz language to Slovak, so questions, answers and the surrounding quiz content come out in Slovak — but parts of the app interface (buttons, labels, settings, system copy) remain in English. The app reads as half Slovak, half English.

This is not Slovak-specific. The same mix will appear for every language the user can pick.

## Why it happens

The language models behind the questions handle many languages out of the box, so quiz content follows the user's choice for free. The app's own interface has only an English localization — translating the whole interface into every supported language is a large, ongoing effort that has not been done. The two halves therefore drift apart the moment the user picks anything other than English.

## What this issue must answer

- What is the established best practice when the *content* language and the *interface* language can differ? (Do they follow each other, are they two separate settings, is there a fallback rule?)
- Is a partial or on-the-fly translated interface acceptable, or does it read worse than a consistent English interface?
- Which option scales to "many content languages, few interface languages" without turning every new language into a translation project?
- What does the language picker in Settings need to say so the user understands what they are choosing?

Outward-sourced research with citations, prior art first (how do other multilingual / AI-content apps solve this). **No research in this session — founder asked to file only.**

## Not in scope (yet)

No implementation, no localization files, no picker changes until the approach is decided.

## Related

- Existing Slovak localization work: #56 (String Catalog localization) — the app already has the machinery, just not the translations.
- [`docs/issues/issue-128-idiom-questions-break-in-translation.md`](issue-128-idiom-questions-break-in-translation.md) — the content-side twin (questions that don't survive translation).
