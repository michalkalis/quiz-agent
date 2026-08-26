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

- [x] Slovak translations for the String Catalog — 430 keys, all translated with per-string context (the catalog was stale: 141 keys had never been extracted from source, so they were re-synced first)
- [x] Declare `sk` as a supported localization so the iOS per-app language row appears
- [x] Settings: caption the Quiz language row, add the read-only App language row deep-linking to iOS settings; Home uses the same "Quiz language" wording
- [x] Fix English leaks in a localized interface: difficulty value, voice-command status readout, and the audio / speech / purchase / persistence error descriptions
- [x] Verified on the simulator in Slovak (onboarding, home, settings, error screen) and 787 unit tests pass
- [ ] Founder review of the Slovak wording (native-speaker pass — the point of limiting interface languages to reviewable ones)

## Known-English surfaces, by decision

- **Command engine row** ("Standard · English") — diagnostics-grade control, deliberately raw per its own code comment. Not translated.
- **Backend-supplied error messages** (e.g. "Authentication required") — the server returns English text and the client shows it verbatim. Localizing those is a backend change, not part of this issue.
- **Quiz content** — follows the Quiz language setting, as designed.

## Not in scope

Interface languages beyond English and Slovak. Any change to the quiz-language list.

## Related

- Existing Slovak localization work: #56 (String Catalog localization) — the app already has the machinery, just not the translations.
- [`docs/issues/issue-128-idiom-questions-break-in-translation.md`](issue-128-idiom-questions-break-in-translation.md) — the content-side twin (questions that don't survive translation).

## TODO detail (migrované z TODO.md 2026-08-26)

> - [~] #130 UI stays English when the quiz language is Slovak — mixed-language app — [plan](../issues/issue-130-ui-language-mix-when-quiz-language-not-english.md) · [research](../research/research-130-ui-vs-content-language.md) — researched + **founder picked Option B on 2026-07-28**: two decoupled lists, many quiz-content languages vs. exactly two interface languages (English + Slovak). Implemented: string catalog re-synced (141 keys had never been extracted) and all 430 keys translated to Slovak with plural variations; `sk` declared as a supported localization so the iOS per-app language picker appears; Settings gained scope captions + a read-only App language row deep-linking to iOS; English leaks fixed (difficulty value, voice-command status, audio/speech/purchase/persistence error text). 787 unit tests green, verified in Slovak on the simulator. This also lands #56's deferred `56.6 [HUMAN]` catalog-populate + plural step. Remaining: **founder review of the Slovak wording**.

