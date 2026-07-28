# Issue 130: UI stays English when the quiz language is Slovak — mixed-language app

**Triage:** ux · ready
**Status:** Researched 2026-07-28 → [`docs/research/research-130-ui-vs-content-language.md`](../research/research-130-ui-vs-content-language.md). **Founder picked Option B on 2026-07-28**: two decoupled lists — many quiz-content languages, exactly two interface languages (English + Slovak). Implementation in progress.
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

## Decided approach (Option B, founder 2026-07-28)

Content languages and interface languages are two separate lists that grow at different speeds.

- **Quiz language** — stays as is: 10 languages, free to extend, drives questions, answers, voice and speech recognition.
- **App language** — English and Slovak only. An interface language is a permanent maintenance commitment, so it is added only when a native speaker can review it.
- **No second in-app picker.** iOS already exposes a per-app interface language (Settings → Trubbo → Preferred Language) as soon as the bundle ships more than one localization. Settings gets a read-only row that deep-links there.
- **No runtime/on-the-fly translation** of the interface: non-deterministic, costs a model call on the hot path, and would break the fixed-phrase voice command lexicon.

Rejected: English-only forever (leaves the reported symptom in place) and translating into all 10 quiz languages (research measured up to 1 in 6 machine-translated UI strings carrying an error, and 8 of those languages have no reviewer).

## Tasks

- [ ] Slovak translations for the String Catalog (274 keys), translated with per-string context, founder-reviewed
- [ ] Declare `sk` as a supported localization so the iOS per-app language row appears
- [ ] Settings: caption the Quiz language row, add the read-only App language row deep-linking to iOS settings
- [ ] Verify both interface languages on the simulator, no clipped or wrapped hero texts in Slovak

## Not in scope

Interface languages beyond English and Slovak. Any change to the quiz-language list.

## Related

- Existing Slovak localization work: #56 (String Catalog localization) — the app already has the machinery, just not the translations.
- [`docs/issues/issue-128-idiom-questions-break-in-translation.md`](issue-128-idiom-questions-break-in-translation.md) — the content-side twin (questions that don't survive translation).
