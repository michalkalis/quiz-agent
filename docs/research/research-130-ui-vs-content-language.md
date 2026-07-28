# Research #130 — UI language vs. content language

**Date:** 2026-07-28 · **For:** [`issue-130-ui-language-mix-when-quiz-language-not-english.md`](../issues/issue-130-ui-language-mix-when-quiz-language-not-english.md)

## Current state (verified in this repo)

| Fact | Evidence |
|------|----------|
| String Catalog exists, source language `en`, 274 keys, **zero non-English translations** (12 `en` entries only) | `apps/ios-app/Hangs/Hangs/Localizable.xcstrings` |
| Xcode project declares only `en` as development region | `Hangs.xcodeproj/project.pbxproj:264` |
| 10 quiz languages offered (en, sk, cs, de, fr, es, it, pl, hu, ro) | `Models/Language.swift` |
| Picker is already labelled **"Quiz language"**, not "Language" — founder decision 2026-07-12 | `Views/SettingsView.swift:266-281` |
| Quiz language also drives speech-to-text | `RecordingCoordinator+Capture.swift:119` |

So the two-setting model is **already half-adopted**: the in-app picker deliberately scopes itself to quiz content. What is missing is any interface localization at all.

## Q1 — Established practice when content and interface language differ

**They are separate settings, and the interface set is much smaller than the content set.** This is the dominant pattern:

- **Netflix** — "display language" (profile-level, interface) is distinct from audio and subtitle language, which are chosen per title at playback. Display languages are a curated list; audio/subtitle span 30+ languages. ([Netflix Help](https://help.netflix.com/en/node/13245), [How-To Geek](https://www.howtogeek.com/677960/how-to-change-your-netflix-profile-subtitle-and-audio-language/))
- **Apple platform convention** — language and region are separate axes; the OS itself offers a **per-app preferred language** so a multilingual user can run one app in Spanish and another in English without changing the device. ([Apple Localization](https://developer.apple.com/localization/), [Apple QA1828 — How iOS Determines the Language For Your App](https://developer.apple.com/library/archive/qa/qa1828/_index.html))
- Language-selector UX guidance places the interface selector in Settings/profile or onboarding, and treats it as a stable app-wide preference, not a per-action choice. ([SimpleLocalize](https://simplelocalize.io/blog/posts/language-selector-best-practices/))

**Fallback rule in practice:** interface falls back to the source language when a translation is absent; content does not fall back at all (it is generated on demand).

**Key consequence for us:** iOS already ships the interface-language picker for free. The moment the app bundle contains more than one localization, **Settings → Trubbo → Preferred Language** appears and the user can set the interface language per-app. We do not need to build a second in-app picker — we need translations. iOS picks the app language from the user's preference order intersected with the localizations the bundle declares ([QA1828](https://developer.apple.com/library/archive/qa/qa1828/_index.html)).

## Q2 — Is a partial or machine-translated interface acceptable?

**Partial: no. Machine-translated with review: yes, this is now mainstream.**

- Missing translations are worse than falling back to the source language, because a half-translated screen reads as broken. Consistency beats coverage. ([Localize](https://localizejs.com/articles/ui-localization-how-to-adapt-your-web-ui-for-global-audiences))
- Machine/AI translation now powers roughly 70% of localization workflows, and quality is materially better when the model receives context (product, tone, what the string does) rather than the bare string. ([Lokalise](https://lokalise.com/blog/ai-translation-quality/), [SimpleLocalize](https://simplelocalize.io/blog/posts/ai-machine-translation-guide/))
- But raw, context-free UI-string translation is still error-prone: a 2025 Lingoport/RWS study across 22 models found **up to 1 in 6 AI-translated UI strings contained an error**, concentrated in short, ambiguous strings — exactly what buttons and labels are. ([Lingoport/RWS](https://lingoport.com/blog/can-we-trust-llms-with-ui-string-translation-research-findings-from-lingoport-and-rws/), [TFOT summary](https://thefutureofthings.com/28510-up-to-1-in-6-ai-translated-ui-strings-may-contain-errors-testing-22-models-simultaneously-reveals-why/))
- Mitigation is context, not a better model: Xcode 26 generates translator context comments for String Catalog entries using an on-device model, which is precisely the input that raises AI translation quality. ([WWDC25 — Explore localization with Xcode](https://developer.apple.com/videos/play/wwdc2025/225/))

**On-the-fly runtime translation of the interface is rejected** by all sources implicitly and by our own constraints: it costs a model call on the hot path, is non-deterministic across launches, and breaks the voice command lexicon, which matches fixed Slovak/English phrases.

## Q3 — What scales to "many content languages, few interface languages"

The asymmetry is the point, and it is the industry norm:

- **Content languages** — free. The model generates in any language; adding one is a row in `Language.swift`.
- **Interface languages** — each is a permanent maintenance cost. Every new string must be re-translated for all of them, forever.

Scaling rule: **decouple the two lists explicitly and grow them at different speeds.** Add content languages freely; add an interface language only when there is a real user base for it, and treat an interface language as a commitment, not a feature flag. The String Catalog + LLM-with-context pipeline keeps the marginal cost of an *existing* interface language low (new strings get translated in the same pass), which is what makes a small curated set sustainable.

Second-order note: a translated interface pulls in more than strings — voice command phrases (`VoiceCommandLexicon`), the STT language, the earcon/copy tone, and layout width (some languages need up to 50% more space). For us the voice lexicon already has a Slovak path, so Slovak is by far the cheapest first interface language.

## Q4 — What the Settings picker must say

Current label "Quiz language" is already correct and should stay. The gap is that nothing tells the user the interface is a separate thing.

Recommended copy shape:
- Keep **"Quiz language"** for the existing picker, with a one-line caption: it sets the language of questions, answers and voice.
- Add a read-only **"App language"** row that reflects the current interface language and deep-links to the iOS per-app language screen (`UIApplication.openSettingsURLString`), rather than duplicating the OS picker in-app. This appears only once the bundle ships more than one localization.

## Options for the founder

| Option | What it means | Cost | Risk |
|--------|---------------|------|------|
| **A. English-only interface, forever** | Ship as-is; caption the picker so the split is explicit | Near zero | Mixed-language app stays; poor for the Slovak road-trip use case, which is the primary one |
| **B. Two-list model, Slovak as the only second interface language** | Translate all 274 strings to Slovak via LLM-with-context, founder reviews; iOS per-app picker handles switching | One translation pass + review; ongoing cost on new strings | Slovak review burden on the founder (they are a native speaker, so this is small) |
| **C. Translate the interface into all 10 quiz languages** | Interface matches content everywhere | 10× the strings, no reviewer for 8 of them | The 1-in-6 error rate lands unreviewed in production for languages nobody can check |

**Recommendation: B.** It matches Netflix/Apple prior art, it fixes the actual reported symptom (Slovak quiz + English UI), it reuses the OS picker instead of building one, and it keeps every interface language reviewable by someone who speaks it. Option C is where this becomes an unbounded translation project, which the issue explicitly warns against.
