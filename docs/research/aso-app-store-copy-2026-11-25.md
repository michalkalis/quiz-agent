# ASO research for Trubbo: App Store product page copy (researched 2026-11-24)

Confidence key: [A] Apple primary source. [P] practitioner or vendor claim. [?] unverified or possibly stale. Notes: web search was US-only and some pages were read through a summarizer, so quotes are paraphrased.

## 1. Field-by-field rules

Apple's product page guidance (no publication date shown, copyright 2026, says it applies to iOS 11 and later): https://developer.apple.com/app-store/product-page/ [A]

- **Name (30)**: searchable. Simple, memorable, hints at what the app does. Avoid generic terms. [A] same URL
- **Subtitle (30)**: searchable. Explain value or typical use, no "world's best" claims. Can change with each version. [A] same URL
- **Keywords (100)**: searchable. Comma-separated, no spaces after commas (spaces inside a phrase are fine). Do not add plurals of words already in singular form, the category name or "app", duplicate words, or special characters. No trademarks, celebrity names or competitor app names (a common rejection cause). [A] same URL
- **Repeating words across fields**: Apple only says to avoid duplicate words inside the keyword field. Practitioners say words in name and subtitle are already indexed, so do not repeat them in the keyword field. [?] Not re-verified in this run. Related context: https://www.apptweak.com/en/aso-blog/ai-reshaping-app-store-relevance (updated 4 Feb 2026) says relevance is moving toward semantic clusters. [P]
- **Promotional text (170)**: shown at the top of the description, editable any time without a new version, does NOT affect search, and Apple says not to use it for keywords. Use it for news, sales and upcoming features. [A] same URL
- **Description (4000)**: Apple's page does not list it as searchable. Searchable items are name, subtitle, keywords, in-app purchases, and the first 1 to 3 screenshots when there is no preview. Ratings and reviews influence ranking. The first sentence is visible before "more": open with a concise paragraph, then list main features. Put accolades at the end or in promo text. No keyword stuffing and no specific prices. [A] same URL. Appfigures found no sign that descriptions are indexed: https://appfigures.com/resources/guides/app-store-algorithm-update-2025 (published 2025-06-12, modified 2026-11-17). [P] No sourced ideal length was found, so write for readers: short hook, then a feature list.
- **What's New**: not covered by the Apple page above and no sourced indexing claim found. Treat it as a short human update. [?]
- **Screenshot captions**: Apple does not document caption indexing. Appfigures, Phiture and SplitMetrics report that Apple has extracted caption text as a ranking signal since about June 2025, weaker than name, subtitle and keywords. AppTweak says there is no conclusive proof. [P] Sources: https://appfigures.com/resources/guides/app-store-algorithm-update-2025 ; https://phiture.com/blog/aso-trends-in-2026/ ; https://splitmetrics.com/blog/apple-app-store-ranking-factors/ (1 Sep 2025) ; https://www.apptweak.com/en/aso-blog/ai-reshaping-app-store-relevance (4 Feb 2026). Practical rules from Appfigures: write captions as real search phrases ("Track Sleep Patterns", not "Easy to Use"), one keyword theme per screenshot, large high-contrast text, captions at the top, align with name, subtitle and keywords. Captions match only in their own language, so English captions will not help Slovak or Czech searches (one vendor claim). A dev.to post claims Apple confirmed this at WWDC25; I could not verify it, so discard it: https://dev.to/shotlingo/apple-now-indexes-screenshot-text-why-screenshot-captions-are-an-aso-ranking-factor-in-2026-4lh7 [?]
- **App preview**: up to 3 videos, each up to 30 seconds, on-device footage. They autoplay muted, so the first seconds must hook. A poster frame shows when they do not autoplay. Previews can be localized. [A] same URL
- **App Store tags and AI-generated tags**: no primary source found in this run. [?] Check https://developer.apple.com/app-store/whats-new/ by hand.

## 2. Cross-localization and storefront indexing

- Apple's own table lists default and additional display languages per storefront, and says nothing about search indexing: https://developer.apple.com/help/app-store-connect/reference/app-information/app-store-localizations [A]. For Slovakia it shows default English (U.K.) with Slovak as additional. For Czechia it shows default English (U.K.) with Czech as additional.
- The one Apple sentence on search: users can search with localized keywords in all countries or regions where the App Store supports that language. https://developer.apple.com/help/app-store-connect/manage-app-information/localize-app-store-information [A] The same page says that if no localization matches the user's language, the next most relevant one is used, and elsewhere the primary language is shown. [A]
- Indexing table from an AppTweak test, published 2023-03-23 (**possibly stale, re-verify**): https://www.apptweak.com/en/aso-blog/how-to-benefit-from-cross-localization-on-the-app-store [P]

| Storefront | Primary | Extra indexed locales |
|---|---|---|
| Slovakia | sk | English (UK) |
| Czechia | cs | English (UK) |
| US | en-US | es-MX, ru, zh-Hans, ar, fr, pt-BR, zh-Hant, vi, ko |
| UK | en-GB | en-AU |

- What this means for Trubbo (derived from the table, so [P] and [?]):
  - Your **en-GB** keyword field is probably indexed in Slovakia and Czechia as well as the UK, giving those storefronts a second 100-character field. Use it for English terms Slovaks and Czechs type ("trivia", "quiz", "voice", "general knowledge"). Do not duplicate Slovak or Czech terms there.
  - **en-US is not an extra locale for SK or CZ**, and en-GB is not extra in the US. Extra US slots come from other locales such as es-MX, fr or pt-BR. This is the commonly cited trick, see https://app.appfigures.com/resources/guides/extend-keyword-list (date not checked) [?], but the localized listing text would be shown to users of those languages, so keep it presentable.
  - Adding en-AU gives extra slots for the UK storefront only.
  - Verify by tracking a unique made-up keyword per locale for about a week (the AppTweak and Phiture method), since the 2023 table may have changed.

## 3. Conversion copywriting

- Apple: the first 1 to 3 screenshots (or the preview) appear in search results, each screenshot should show one main benefit, and the first sentence of the description is visible before "more". https://developer.apple.com/app-store/product-page/ [A]
- The first three screenshots carry the most weight because people rarely scroll past them: https://www.apptweak.com/en/aso-blog/how-to-optimize-your-app-screenshots (date not checked) [P]. The first screenshot should add new information, not repeat the icon: https://appfigures.com/resources/videos/screenshots-that-convert-live-product-page-teardown [P] ; https://dev.to/asoplaybook/the-first-app-store-screenshot-is-usually-your-biggest-conversion-leak-1jpe (weak source) [P].
- Suggested sequence for Trubbo (my recommendation, not a study result): screenshot 1 the hook "Answer trivia with your voice" with the voice screen; screenshot 2 the hands-free benefit; screenshot 3 the variety of categories. Show real UI.
- Benefit versus feature, social proof, pricing transparency: no rigorous source found in this run. Apple's rules: no specific prices in the description, accolades at the end or in promo text. [A] same URL. State "30 free questions every month" in a screenshot or the first description lines as a trust signal (recommendation, not evidence-backed).
- Length: Apple gives caps only, no evidence-based optimal length found.
- Validate with Product Page Optimization A/B tests (Apple confirms PPO and custom product pages exist). [A] Small apps may lack traffic for significant results, so test big changes such as screenshot 1.

## 4. Commonly missed App Store Connect features for small apps

- **Custom product pages**: own screenshots, promo text and previews, each with a unique URL, up to 70 at a time. Pages can be assigned keywords and then appear in search for those keywords instead of the default page. https://developer.apple.com/news/?id=gf6mgrs6 (read via search summary, date not checked) [A, partial]. Ideas: a voice-only page, a family page, a Slovak-language page.
- **In-App Events**: shown on the product page and in search, up to 10 published and 15 approved at a time. https://developer.apple.com/help/app-store-connect/offer-in-app-events/overview-of-in-app-events [A]. Fits weekly themed quizzes and seasonal topics.
- **Promoted in-app purchases**: appear on the product page, in search, and sometimes on tabs. They need a promotional image and localized name and description, and the app must support the purchase-intent API. https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/promote-in-app-purchases ; https://developer.apple.com/app-store/promoting-in-app-purchases [A]. IAPs are also searchable, so give the subscription and packs descriptive localized display names in sk, cs and en. [A] https://developer.apple.com/app-store/product-page/
- **Ratings and reviews** influence search ranking and the displayed rating, and developer responses are visible (latest review and response per user). [A] same product-page URL. The in-app rating prompt is not covered by the sources I read [?]: use the system prompt after a good moment such as a finished quiz.
- **Secondary category, age rating, IAP localizations**: no indexing evidence found. Fill them in for every locale. [?] Apple also says to include at least one Dark Mode screenshot if the app supports it. [A]
- **Localize everything**: description, keywords, previews and screenshots for each market. [A] product-page URL

## 5. Existing ASO skills and tools (not installed)

- **eronred/aso-skills** (Appeeky): https://github.com/Eronred/aso-skills . About 40 skills (keyword research, metadata, competitors, creatives, analytics), includes `/aso-audit`. MIT license, 2.3k stars, 26 commits, last commit date not visible. Works standalone from general knowledge. Live data needs the paid Appeeky API (Appeeky Connect from $8 per month). Most promising of the set. Read the SKILL.md files before use.
- **alirezarezvani/claude-code-aso-skill**: https://github.com/alirezarezvani/claude-code-aso-skill . Four agents, commands `/aso-full-audit`, `/aso-optimize`, `/aso-prelaunch`, `/aso-competitor`, plus templates. MIT, 471 stars, 35 commits, README release date Nov 2025. Reasonable, possibly less active.
- **davila7/claude-code-templates app-store-optimization**: https://claudemarketplaces.com/skills/davila7/claude-code-templates/app-store-optimization . Generic iOS and Google Play skill, widely installed, generic content, lower value.
- **borghei/claude-skills app-store-optimization**: https://claudemarketplaces.com/skills/borghei/claude-skills/app-store-optimization . Indie-focused, quality unverified.
- Listing sites: https://www.skills.sh/alirezarezvani/claude-code-aso-skill (about 72 installs), https://tessl.io/registry/skills/github/alirezarezvani/claude-code-skill-factory/app-store-optimization . One aggregator flagged a skill "suggest reviewing before use". No Anthropic-official ASO skill was found.
- Assessment: all are generic and English-centric, none knows Slovak or Czech storefront rules. Since the project already has fastlane metadata, a small custom checker (character limits, duplicate words, comma format, per-locale diff) may beat installing a generic skill.

## Top 10 actionable rules

1. Name and subtitle carry the most weight: put the main search phrases ("voice", "trivia" or "quiz") in them, per locale, 30 characters each. [A]
2. Keywords: 100 characters, comma-separated, no spaces after commas, no plurals of included singulars, no "app" or category word, no repeats of name or subtitle words, no competitor names. [A]
3. Use the en-GB keyword field as an extra 100 characters for Slovakia and Czechia (AppTweak 2023 table). Verify with a made-up keyword test first. [P, stale]
4. For extra US slots, other locales such as es-MX can hold more keywords, but only if the page still reads acceptably. [P]
5. Promo text: use it for current offers and seasonal topics. It is free to edit and not indexed. [A]
6. Description: the first sentence must sell the voice hook, no prices, no keyword stuffing, and do not spend effort on keyword density. [A]/[P]
7. Screenshots 1 to 3: one benefit each, real UI, captions written as real search phrases in each language, large and at the top. [A]/[P, unconfirmed by Apple]
8. Add an app preview whose first seconds show hearing a question and answering by voice, and localize it. [A]
9. Set up keyword-targeted custom product pages, an In-App Event rotation, and promoted IAPs with localized names and images. Name IAPs descriptively since they are searchable. [A]
10. Run a PPO test on screenshot 1 once traffic allows, and ask for ratings through the system prompt at a success moment. [A]/[?]

Gaps (not verified): App Store tags and AI tags, What's New indexing, evidence on description length, benefit-versus-feature and social proof studies, and a post-2023 cross-localization table.
