# App Store listing review (2026-11-25)

Live state read from App Store Connect (version 1.2, live since 2026-11-07) and compared with `apps/ios-app/Hangs/fastlane/metadata`. Rules and sources: [aso-app-store-copy-2026-11-25.md](aso-app-store-copy-2026-11-25.md).

## Errors to fix with the next version

| # | What | Where | Fix |
|---|------|-------|-----|
| 1 | What's New on 1.2 says "First release." | en-GB (live and repo) | real release notes, same as en-US |
| 2 | Repo description (with "Checked questions", #763) never uploaded; live is the older text | all 4 | upload with next version (listing upload) |
| 3 | "First questions are ready to play within minutes" | description, all | founder 11-18: never "o pár minút", use "hrať môžeš takmer hneď" |
| 4 | Voice command list (start, confirm, next, again, repeat) | description, all | rewrite when the #243 voice navigation ships |
| 5 | Two new Apple age rating questions (dating, shared location) unanswered | App Information | answer "no" before next submission; add to `age_rating.json` |
| 6 | Annual subscription draft "Trubbo Unlimited Annual" stuck in Missing Metadata with old "Unlimited" naming | Subscriptions | delete or leave; not visible to players |

## App Store Connect messages

- **App Review:** no open threads, all 3 submissions complete.
- **China mainland:** app is on sale in China. Apps with AI generated content need an AIGC declaration and a security assessment by 2027-01-31. No Chinese localization, no users there: remove China from availability (founder decision).
- **Age ratings:** new questions (see 5 above).
- **Retention messaging:** new option to show a message or offer when someone cancels the subscription. Worth a later look.
- **Customer reviews:** 1 review in total (CZ, 5 stars, 2026-11-21, unanswered). The app never asks for a rating (no system rating prompt in the code).

## Search visibility (indexed: name, subtitle, keywords, IAP names)

- **Subtitle repeats "kvíz"** (sk, cs) which is already in the name: wasted indexed space. en-US "Fun for road trips and parties": only "road trips" and "parties" are search terms.
- **Name** sk/cs has 10 free characters. "Trubbo: Vedomostný kvíz hlasom" / "Trubbo: Vědomostní kvíz hlasem" (30) adds the likely most searched phrase.
- **Keywords with low value:** sk `pre`, `dvoch`; cs `pro`, `dva`; en `player`, `adults`. Freed space for e.g. sk `hádanky`, `trivia`, `zábava`, `auto`; cs `hádanky`, `zábava`, `auto` (search volume not measured).
- **en-GB keywords are also indexed in Slovakia and Czechia** (AppTweak test 2023, verify): today they duplicate en-US English words. Use them for the English words Slovaks and Czechs type (quiz, trivia, voice, ...), check with a test keyword.
- **No secondary category.** Games › Trivia as secondary is free reach; primary stays Entertainment (CarPlay reason, #97). CarPlay impact of a secondary category not verified.
- **IAP names are searchable:** "Custom Pack, 30 Questions" etc. are fine.

## Conversion

- **Description** (1450 to 1930 characters, 7 headed sections) is not indexed; only the first lines show before "more". A shorter text (about 900 characters, hook first, one list) costs nothing in search. Draft on the decision page.
- **Screenshots:** 6 per language, iPhone only (app is iPhone only, fine). Screenshot 1 is mostly an empty green card; the question sits at the bottom. Captions may be weakly indexed since 2025: write them as search phrases.
- **No app preview video.** The promo videos (#210) are a ready source; first seconds must work muted.
- **Not used:** In-App Events (fits the free category rotation and seasonal quizzes), promoted purchases (custom pack), custom product pages, A/B tests (traffic too low for now), marketing URL (empty).
- **Promo text** can change any time without review: use it for seasonal topics (Christmas).

## Tools

ASO skills exist (eronred/aso-skills, alirezarezvani/claude-code-aso-skill), all generic and English only. Not installed. A small check in the listing upload (limits, repeated words, filler words) covers the mechanical part.
