# Research: catching social trends for questions and posts (2026-11-18)

**Query:** How to catch trends and virals (TikTok / Instagram, sk/cs first, then global), where the data comes from, and how to turn them into Trubbo questions and social posts.

Builds on `social-audience-topics-2026-11-09.md` (what performs on our accounts) and `seasonal-themes-and-competition-2026-11-18.md` (holidays, small steps).

## Executive summary

- **Neither TikTok nor Instagram offers an official trend feed we can use.** TikTok's research access excludes commercial users; Instagram's official access covers only 30 hashtags a week and nothing on trending audio.
- **The trends that matter to a quiz are topics, not sounds or dances.** A person, show, film or event that people suddenly look up is quiz material; a dance is not. Topics are visible for free outside TikTok and Instagram.
- **Two free, legal sources already work for Slovakia and Czechia** (both tested live today): Google's daily search trends feed and Wikipedia's most-read articles. YouTube's most-popular list per country is a third free official source.
- **Wikipedia's list is the best fit for us**: every item is already an article, which is our first-choice source for fact-checking questions.
- **TikTok-native signals are available only through paid third-party scrapers** (roughly $0.5 to $2 per 1,000 rows). Cheap, but unreliable (TikTok closed parts of the feed in 2026) and against TikTok's terms. Recommended only as a later add-on, if at all.

## Key findings

### 1. Official platform access is a dead end

| Source | What it gives | Usable for us? |
|---|---|---|
| TikTok Research access | Public video search | No. Commercial users are excluded, approval per research project ([TikTok FAQ](https://developers.tiktok.com/docs/en/research-api-faq)). |
| TikTok Creative Center (website) | Trending hashtags and top videos per country | By hand only. No public feed; in 2026 the songs and creators lists were removed and anonymous access to the data behind the page is blocked, per scraper vendors ([Apify listing](https://apify.com/data_xplorer/tiktok-trends), vendor claim, not confirmed by TikTok). Whether Slovakia is in its country list is **unverified**. |
| Instagram official access | Top posts for a hashtag we name | Barely. 30 hashtags per 7 days, needs app review, no trending list, no audio trends ([Meta docs](https://developers.facebook.com/documentation/instagram-platform/instagram-api-with-facebook-login/hashtag-search)). It answers "how is #kviz doing", not "what is trending". |

### 2. Free, legal topic signals (tested today for SK and CZ)

| Source | What we got on 2026-11-16/18 | Notes |
|---|---|---|
| **Wikipedia most-read articles**, per language edition | sk: Adéla (singer), Farma (TV show), Nežná revolúcia, Robert Pattinson, Sissi, James Bond, Mária Terézia. cs: Sametová revoluce, Karel Kryl, Marie Rottrová, Robert Pattinson, Marie Antoinetta, James Bond | Official open data, about 1,000 articles a day per language, free. Shows the holiday (17 November), TV (Farma, a Sissi series), film and music at a glance. The per-country variant returns only 6 rows for Slovakia (privacy threshold), so use the per-language list. |
| **Google daily search trends feed**, per country | SK: ps5, ticketmaster, zima, plus politicians and news names. CZ: biatlon, plus news names | Public feed, 10 items a day with search volume and linked news articles. Noisier and heavy on politics and crime, which we skip. Google's official trends access is a closed alpha and excludes "trending now" ([Search Engine Journal](https://www.searchenginejournal.com/google-trends-api-alpha-launching-breaking-news/551935/)). |
| **YouTube most popular per country** | not tested | Official, free, one cheap call per country ([Google docs](https://developers.google.com/youtube/v3/guides/implementation/videos)). Good for music, trailers, games. |

Also free and predictable, no feed needed: cinema and streaming release dates, award shows, sports finals, anniversaries. Cultural moments like a film release keep attention for about 2 to 3 weeks, long enough for us to prepare ([Metricool](https://metricool.com/trendjacking-what-works-and-what-backfires/)).

### 3. Paid scrapers for TikTok-native trends

Many small vendors on Apify resell the Creative Center lists: $0.15 to $2 per 1,000 rows, one outlier at $15 ([webdata_labs](https://apify.com/webdata_labs/tiktok-hashtag-trends-scraper), [fetch_cat](https://apify.com/fetch_cat/tiktok-trends-scraper), [data_xplorer](https://apify.com/data_xplorer/tiktok-trends)). A daily pull for SK, CZ and one global market would cost well under $5 a month.

Risks:
- **Reliability.** Vendors contradict each other on what still works after TikTok's 2026 changes. Expect breakage.
- **Terms.** Scraping breaks TikTok's and Meta's terms. A US court found logged-out scraping of public Meta data was not a breach ([TechCrunch](https://techcrunch.com/2024/01/24/court-rules-in-favor-of-a-web-scraper-bright-data-which-meta-had-used-and-then-sued), [Quinn Emanuel](https://www.quinnemanuel.com/the-firm/news-events/client-alert-what-does-the-meta-v-bright-data-summary-judgment-ruling-mean-for-web-scraping/)), but that is one US ruling and commentators call it narrow. EU law was not researched. Going through a vendor keeps our own accounts out of it; scraping with our own logins would put the accounts at risk and is not recommended.
- **Fit.** Hashtags and sounds rarely translate into a factual question.

### 4. Does trend-riding work for small accounts?

No solid numbers exist. Sources are agency blogs: small accounts can win because they react faster and the TikTok feed is not tied to follower count; a late or forced trend post does harm; fast "trending topics" last hours to days, broader cultural moments weeks ([Metricool](https://metricool.com/trendjacking-what-works-and-what-backfires/), [Influencer Marketing Hub](https://influencermarketinghub.com/tiktok-trendjacking/)). Treat it as an experiment to measure, not a proven channel.

Our own data points the same way as the topic approach: local identity and well-known names win (Karel Gott 1,800 views, about 4x the next video; the Michael Jackson biopic was the best EN entertainment reel).

## Implications for Trubbo

- A trend is useful to us only if it yields a **timeless fact with a source**: "Robert Pattinson is trending" becomes a question about his films, not about today's news. This keeps the question valid after the trend passes and respects the rule of no current politics and wars.
- Our weekly video batch rhythm cannot catch a 2-day trend. It can catch multi-week moments and next-day reactions to a holiday, a TV show or a film.
- Every trend question still needs a source, the normal quality check and native sk/cs wording. Unreviewed questions stay out of the App Store build.
- TikTok itself is still an account we do not operate through automation (ban risk noted on 11-09), so TikTok-native trend formats would have to be posted by hand.

## Recommendations

1. **Daily "what people are looking up" digest (free).** Pull Wikipedia most-read (sk, cs, en) and Google daily trends (SK, CZ), filter out politics, crime, wars and navigation pages, and keep names that stay up for 2+ days or jump sharply. Output: 5 to 10 topic candidates per language per week.
2. **Trend questions in small numbers.** From the digest, 3 to 5 questions a week per language through the normal generation and review, tagged as trend questions so we can compare their results with ordinary ones.
3. **Same question, two places.** The trend question goes out as a reel/short with the trend name in the hook, and into the app (daily challenge or a small "This week" set) so a viewer who installs finds what they saw.
4. **Calendar of predictable moments.** Film and series premieres, awards, sports finals, anniversaries for the next 6 to 8 weeks, prepared ahead, same as holidays.
5. **Measure for 3 to 4 weeks**, then decide: views and stay-rate of trend videos against the ordinary ones, and plays of trend questions in the app.
6. **TikTok-native layer only if step 5 shows a lift**: a 10-minute manual look at Creative Center once a week first; a paid scraper (under $5 a month) only if the manual look proves useful.

## Sources

1. [TikTok Research Tools FAQ](https://developers.tiktok.com/docs/en/research-api-faq) — commercial users not eligible.
2. [Meta: Instagram Hashtag Search](https://developers.facebook.com/documentation/instagram-platform/instagram-api-with-facebook-login/hashtag-search) — 30 hashtags per 7 days, app review.
3. [Search Engine Journal: Google Trends API alpha](https://www.searchenginejournal.com/google-trends-api-alpha-launching-breaking-news/551935/) — closed alpha, no "trending now".
4. [Wikimedia Analytics API, country data](https://doc.wikimedia.org/generated-data-platform/aqs/analytics-api/concepts/country-data.html) — bucketed counts; live calls made 2026-11-18.
5. [Google: YouTube most popular videos](https://developers.google.com/youtube/v3/guides/implementation/videos) — per-country chart, 1 quota unit.
6. Apify listings: [data_xplorer](https://apify.com/data_xplorer/tiktok-trends), [webdata_labs](https://apify.com/webdata_labs/tiktok-hashtag-trends-scraper), [fetch_cat](https://apify.com/fetch_cat/tiktok-trends-scraper) — prices and 2026 Creative Center changes (vendor claims).
7. [TechCrunch](https://techcrunch.com/2024/01/24/court-rules-in-favor-of-a-web-scraper-bright-data-which-meta-had-used-and-then-sued), [Quinn Emanuel](https://www.quinnemanuel.com/the-firm/news-events/client-alert-what-does-the-meta-v-bright-data-summary-judgment-ruling-mean-for-web-scraping/) — Meta v. Bright Data, scope and limits.
8. [Metricool: trendjacking](https://metricool.com/trendjacking-what-works-and-what-backfires/), [Influencer Marketing Hub](https://influencermarketinghub.com/tiktok-trendjacking/) — timing and risk; opinion, not measured data.

**Not verified:** Creative Center country coverage for Slovakia; current state of each scraper; EU legal position on scraping; YouTube list quality for SK/CZ.
