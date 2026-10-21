# Growth strategy research — what to optimize and what worked for comparable apps (2026-10-21)

Founder-facing version: https://claude.ai/artifact/UhUsqxZ7EPRFpJKSLGrhP1

Context: Trubbo (voice trivia, iOS, en/sk/cs, freemium: free questions per month + Trubbo Plus €4.99/mo + packs €2.99 + custom pack €8.99), solo founder, launch phase. Founder asked for research, not plans: followers vs installs vs purchases, what worked elsewhere. Builds on [social-marketing-2026-10-19.md](social-marketing-2026-10-19.md) and the content plan in [issue-210-content-plan.md](../issues/issue-210-content-plan.md). Three Sonnet research passes, synthesis by Opus. **[W]** = weak, vendor or anecdotal.

## 1. What to optimize

- **Followers are an input, not a goal.** TikTok: 85 % of views come from the For You feed, 0.3 % from the following feed ([quso.ai 2026](https://quso.ai/research/how-the-tiktok-algorithm-works)) [W]. Only 1 in 35 posts passes 10k views ([quso.ai](https://quso.ai/research/tiktok-data-findings)) [W].
- **Paying users are the goal; installs and first-session conversion are the levers.** The funnel below shows why reach alone is expensive.
- 57.7 % of new subscription apps never reach $1,000 revenue; below ~$100K the problem is usually product-market fit, not price ([Adapty 2026](https://adapty.io/blog/markdown/subscription-app-success-2026.md)) [W].

### Funnel numbers

| Step | Number | Source |
|---|---|---|
| Short-form views → install | 0.5–2 % blended (talking head 1–2 %, slideshows 0.2–0.4 %) → ~50–200 views per install | [Agniverse 2026](https://agniverse.co/ugc-content-benchmarks) [W] |
| Same, one anecdote | 2,000 TikTok views → 11 downloads | [Indie Hackers](https://www.indiehackers.com/post/day-10-11-downloads-2-000-tiktok-views-and-the-mistake-that-killed-my-us-conversions-1dcfbbeff5) [W] |
| Product page → download | US average 8.56 %, **Games – Trivia 5.2 % (lowest category)** | [AppTweak 2025](https://www.apptweak.com/aso-blog/mobile-app-store-conversion-rate-benchmarks-per-category) |
| Download → paid by day 35 | All apps 2.0 %, **Gaming 1.0 %**; freemium 2.1 % vs hard paywall 10.7 %; North America 2.8 % | [RevenueCat State of Subscription Apps 2026](https://www.revenuecat.com/state-of-subscription-apps) |
| Revenue per install at day 60 | freemium $0.38 vs hard paywall $3.09 | RevenueCat 2026 |
| Trial → paid | Gaming 25 %, Western Europe 29.7 % | RevenueCat 2026 |
| When people decide | 80–90 % of trial starts happen on install day | RevenueCat 2026, Adapty 2026 |
| Game retention (median) | D1 ~22 %, D7 ~4 %, D30 ~0.7 %; top 10 % 40/12/4 % | [GameAnalytics 2026 via summary](https://gamedevreports.substack.com/p/gameanalytics-mobile-and-pc-game) |

**Rule of thumb:** ~100 installs per paying user on freemium, so 1 payer ≈ 10–20k views. 100 payers ≈ 1–2M views. Moving free→paid conversion or the trivia page conversion pays back on every channel at once.

### In-app purchase drivers

- Day 0 is the decision moment (above). Onboarding paywall with a trial has the highest install→paid in Adapty data (1.78 %) [W].
- Hard paywall converts ~5× better but cuts reach; one-year retention is the same (28 % vs 27 %). Opal moved hard → freemium: paid share 20 % → 9 %, organic reach and DAU up "massively" ([RevenueCat](https://www.revenuecat.com/blog/growth/hard-paywall-vs-freemium), [Speedinvest](https://speedinvest.com/blog/scaling-smart-how-opal-built-a-10m-arr-business-in-just-2-years)).
- Free tier too generous → no reason to pay; too tight → no habit (RevenueCat 2026).
- Packs: hybrid buyers are 7 % of buyers but 25 % of revenue; RevenueCat still advises small teams to keep the subscription the core ([RevenueCat 2026](https://www.revenuecat.com/blog/growth/hybrid-monetization-techniques.md)).
- Price localization tests win 62 % of the time, the best win rate of any test type (Adapty 2026) [W]. Higher-priced apps convert better (2.8 % vs 1.4 %), so cheaper is not automatically better (RevenueCat 2026).

## 2. What worked for comparable apps

**Trivia and party games**
- **Heads Up!** — started on Ellen's TV show, $0.99 paid app, 24M downloads by 2016 ([Fortune](https://fortune.com/2016/06/03/ellen-degeneres-digital-network/)). The same team's Psych! without the show: ~0.2–0.35M [W].
- **Trivia Crack** — word of mouth through family networks in Latin America, user-submitted questions with author credit, later paid installs; ads ≈ 50 % of revenue ([Think with Google 2016](https://thinkwithgoogle.com/marketing-strategies/app-and-mobile/trivia-crack-wins-globally-by-staying-local)).
- **QuizUp** — 1.5M sign-ups in two weeks via a shareable result card; shut down because revenue didn't cover serving ~80M free users ([Inc42](https://inc42.com/resources/quizup-growth-story/)).
- **HQ Trivia** — peak 2.38M live players, dead by 2020: fixed appointment, cash prizes as the only reason to return, sponsors couldn't fund it ([Wikipedia](https://en.wikipedia.org/wiki/HQ_Trivia)).
- **Wordle** — spoiler-free emoji grid → 1.2M shared grids in two weeks; earned nothing itself, NYT used it to feed its subscription ([TechCrunch 2022](https://techcrunch.com/2022/05/04/wordle-new-york-times-user-growth)).
- **Jackbox** — one purchase serves the whole room (others join free); sales up to 10× in 2020 [W].
- **Alexa "Question of the Day"** (closest analogue: voice trivia, packs $1.95 + club $2.95/mo) — hundreds of thousands of monthly users, mostly from Alexa store front-page placement and Amazon emails ([Amazon 2019](https://developer.amazon.com/en-US/blogs/alexa/alexa-skills-kit/2019/05/matchbox-io-revs-up-alexa-game-skill-question-of-the-day-with-in-skill-purchasing-and-builds-a-voice-business)).
- **Drivetime.fm** (voice trivia for drivers, $11M raised 2019, $9.99/mo) — no user numbers; content stalled ([Voicebot](https://voicebot.ai/2019/09/09/drivetime-closes-11-million-series-a-round-with-investment-from-makers-fund-amazons-alexa-fund-and-google/)).

**Indie subscription apps**
- **Cal AI** — ~250 creators on monthly retainers, mid-six-figure creator spend per month, paywall testing; $30M+ ARR, acquired 2026. Not organic ([Latka 2025](https://getlatka.com/interviews/cal-ai-zach-yadegari-2025)).
- **Rizz** — paid faceless creators $1–2 per 1,000 views, ~$2M paid out, claims $15M revenue [W].
- **Opal** — hired a creator who already used the app; one video reached tens of millions and was reused as a paid ad.
- **Dumbphone** — one account, 2.4M views → 20k downloads, $9k MRR in 78 days.
- **HabitKit** (solo) — $28k MRR by Dec 2025, mainly from App Store search (ASO), not TikTok [W].

**Czech / Slovak**
- **Krycí jména** (Codenames, Czech-only, 25 CZK paid) — #1 paid on iOS and Android CZ in week one, on the back of a known board game ([CzechCrunch 2022](https://cc.cz/kryci-jmena-preskocila-minecraft-mobilni-verze-ceske-deskovky-je-nejprodavanejsi-na-ios-i-androidu/)).
- **DayByMe** — #1 free in the SK App Store on day one from its own ~1M Instagram/Facebook audience, yet only 25k registrations ([Startitup 2017](https://www.startitup.sk/?p=196226)). Small charts are reachable; a chart spike is not a business.

### Patterns

1. Every 10M+ trivia hit rode an existing mass audience (TV, NYT, family networks). None came from a solo brand account alone.
2. Sharing works when the output explains itself (score card, emoji grid) and trying is free.
3. Trivia on its own monetizes badly; money came from paid apps, one purchase for a room, sponsors or a parent subscription. Failures were cost and retention, not downloads.
4. Indie subscription "organic" stories mostly ran on paid creators (retainer or per view).
5. Store/platform featuring and an owned local audience were the small-market levers.

## 3. Levers other than own social posting

| Lever | Evidence | Cost |
|---|---|---|
| Apple featuring nomination + In-App Events | Old median lifts: App of the Day +685 %, Lists +240 % ([Sensor Tower 2018](https://sensortower.com/blog/ios-11-featuring-apps-tab)); In-App Events +16–30 % installs non-featured [W]; Apple names localization and accessibility as criteria ([Apple](https://developer.apple.com/app-store/getting-featured/)) | Free, nominate ≥2 weeks ahead per release |
| Product page: screenshots, Custom Product Pages, ratings prompt | CPP ~+23 % downloads (Adapty) [W]; trivia page conversion is the lowest category | One-time work |
| Shareable result card / spoiler-free share | Wordle, QuizUp; realistic K-factor 0.1–0.4 [W] | Small build |
| In-game referral reward (free pack / extra questions) | HQ extra-life codes worked while retention lasted | Small build, reuses packs |
| Apple Ads test CZ/SK | US Games CPI $4.63, discovery $1.34; Poland $1.12; CZ/SK not found ([AppTweak 2025](https://www.apptweak.com/en/aso-blog/apple-ads-benchmarks)) | $100–200 test, founder approval |
| Paid creators per view (Rizz model) or one creator who uses the app (Opal) | Main engine of indie hits; $50–500 per UGC video, small creators often a bad deal [W] | Cash + management time |
| Reddit / Product Hunt / local press | 40 to ~5,000 installs per post, Product Hunt tens of installs [W] | Hours, one-off |
| Partnerships (car makers, rentals, radio, pub quizzes) | Only precedent: Trivia Crack on VW infotainment via AirConsole, no results | Long sales cycle; revisit with CarPlay |

## 4. Implications for Trubbo (for founder discussion, not decided)

1. **North star = paying users per week**, with inputs: installs per channel, day-0 free→paid, D1/D7 retention (own analytics, #51 — own events table). Followers and views are diagnostics.
2. **Conversion before traffic:** at ~100 installs per payer, a better product page (trivia 5.2 %) and first-session offer multiply every channel; traffic without them is expensive.
3. **Product-market fit signal first:** D7 retention and whether Plus buyers renew; no trivia retention benchmark exists, so measure it.
4. **Trubbo's built-in strength is the Jackbox shape:** one phone plays for a whole car or room, so one install exposes 3–5 people. A spoiler-free result card after a round is the natural share artifact.
5. **Apple featuring is the free lever with the biggest upside** and fits the product (voice, sk/cs localization, accessibility); Alexa's voice-trivia analogue grew mostly from store placement.
6. **Own social content is a slow, cheap channel, not the engine.** Evidence says indie engines were paid creators or ASO. A small paid test (Apple Ads CZ/SK, or one creator) would give real cost per payer; spend is the founder's call.
7. Paywall shape (freemium vs trial vs harder paywall) is the biggest conversion lever in the data and a product decision for the founder.
