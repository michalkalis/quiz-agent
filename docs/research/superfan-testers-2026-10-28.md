# Superfan testers for Trubbo — research (2026-10-28)

Scope: find engaged, would-pay testers for a voice trivia app (SK/CZ first, EN second). Not repeated: ASO, Apple featuring, Product Hunt, r/iosapps, nano-influencer barter, reels.
Evidence caveat: web search here is weak on Facebook groups (not indexable) and on rigorous studies. Anything not verified is marked **unverified**. Most "paid beta" evidence is practitioner opinion, not data.

## Executive summary

- The superfan vs. freebie split is real, but the evidence is behavioral, not demographic: Superhuman's method sorts users by how they would feel losing the product and then builds only for the "very disappointed" segment, and ignores the "not disappointed" group ([Superhuman](https://blog.superhuman.com/how-superhuman-built-an-engine-to-find-product-market-fit/)).
- Your current testers fail the Mom Test (compliments and opinions are "fluff"; only time, reputation or money commitments count as signal) ([summary](https://booksite-5ed.pages.dev/en/books/the-mom-test/), [notes](https://mtlynch.io/book-reports/the-mom-test/)). Family and friends are also a known-biased pool that does not match the target market ([Centercode](https://centercode.com/blog/the-definition-of-high-quality-feedback)).
- Best-supported screen: a short application form plus a small commitment (a price, a call, a weekly check-in). Sources are practitioner-level: [Cabana paid beta](https://siliconfilter.com/want-to-join-our-private-beta-pay-up), [Indie Hackers thread](https://www.indiehackers.com/post/where-do-you-find-your-first-beta-testers-these-days-109c73ee25). Caveat: paying testers expect more polish and support.
- Where to go: not "quizzers in general" but people who already run or attend a recurring social quiz ritual. Czechia has a large organized pub-quiz industry (Hospodský kvíz, Chytrý kvíz, PubQuiz) whose organizers/moderators are reachable and are power users of quiz content. Slovakia's scene is much thinner online (nothing comparable found).
- Hardcore quizzers are likely the wrong segment for taste, but a good segment for stress-testing question accuracy and the host's voice flow. Weight their feedback differently (see Q4). This is my inference; no source studies it.
- Channels that work for indie iOS recruiting are niche communities, asked admin-first: r/TestFlight-type subs, r/BetaTestersNeeded, Facebook groups where promos are already tolerated ([growthsnippets](https://growthsnippets.substack.com/p/20-steps-to-get-your-first-10000), [Indie Hackers](https://www.indiehackers.com/post/where-do-you-find-your-first-beta-testers-these-days-109c73ee25)). Marketplaces are mostly unvetted for tester intent.
- Mechanics: TestFlight public link is fine (10,000 external testers, criteria filter, funnel stats in App Store Connect), but public-link testers are anonymous, so you need your own identity layer (form/in-app code) to know who is a superfan ([Apple](https://developer.apple.com/testflight/), [9to5Mac](https://9to5mac.com/2018/09/26/testflight-public-links/)).

## Q1. Superfan vs. freebie seeker

**Frameworks**
- Sean Ellis / Superhuman: ask "How would you feel if you could no longer use this?"; under 40% "very disappointed" means no PMF. Superhuman started at 22%. Segment on the "very disappointed" group, use their words to define the ideal customer, selectively study "somewhat disappointed" users who cite your core benefit, ignore "not disappointed". Roadmap split about half/half between strengthening what fans love and removing blockers for the "somewhat" group ([Superhuman blog, 2018](https://blog.superhuman.com/how-superhuman-built-an-engine-to-find-product-market-fit/); the 40% / 22% figures are repeated in [summary](https://pshimanshu.substack.com/p/heres-what-i-learned-about-product), secondary). Ellis's benchmark sample size is reported inconsistently (100 vs 150 companies).
- Kevin Kelly, 1,000 True Fans: a true fan buys whatever you produce; 1,000 is only an order of magnitude ([secondary summary](https://www.gigazine.net/gsc_news/en/20230107-1000-true-fans); I did not fetch the original at kk.org). Useful as framing: you need tens now, not thousands.
- The Mom Test: opinions and compliments are worthless; ask about past specifics and seek commitments of time, reputation or cash ([booksite summary](https://booksite-5ed.pages.dev/en/books/the-mom-test/), [Lynch notes](https://mtlynch.io/book-reports/the-mom-test/)). Secondary sources; verify wording in the book before quoting.

**Screening methods that appear in the sources**
- Short application form for testers ([Indie Hackers thread](https://www.indiehackers.com/post/where-do-you-find-your-first-beta-testers-these-days-109c73ee25)).
- Find people already complaining/discussing the problem in niche communities and offer early access to those who describe it in detail (same thread).
- Paid or discounted founder pricing to test willingness to pay; a price keeps casual sign-ups out ([Cabana via SiliconFilter](https://siliconfilter.com/want-to-join-our-private-beta-pay-up), [Sliplane validation note](https://onepage-research.sliplane.app/lessons/validation/val-p229)).
- Platforms that rate testers on depth of feedback and penalize minimal effort ([BetaTesting](https://help.betatesting.com/en/articles/1907214-how-we-measure-quality-tester-participation-tips-for-success)).

**Does paying/commitment improve quality?** Plausible and widely claimed, but no controlled evidence found. Counterpoints: paying users expect support and polish ([Reddit thread summarized](https://redlib.cypherpunktools.com/r/indiehackers/comments/1kal7e8/should_users_pay_during_beta_testing)); free users "keep asking for more and never pay" (Indie Hackers commenter). For Trubbo, a hybrid fits the "never a hard paywall" rule: free with a lightweight commitment (form + 15-min call + 2 sessions a week), then a founding-member discount on Plus as the willingness-to-pay test.

## Q2. Where indie founders found first 10-50 testers

Real founder write-ups are scarce and mostly self-published; treat numbers as anecdotal.
- Codehub (2023, self-reported): TestFlight-oriented communities (Telegram channels, a Twitter account, r/TestFlight, r/BetaTestersNeeded, r/iOSBeta) produced about 1,500 installs in 3 days ([growthsnippets](https://growthsnippets.substack.com/p/20-steps-to-get-your-first-10000)). Installs, not engaged users: no quality data.
- Facebook groups: search the group for "beta", post only where others already promote apps, message admins first. A team reported FB groups helping only after admin permission ([Indie Hackers: where do you find your first beta testers](https://www.indiehackers.com/post/where-do-you-find-your-first-beta-testers-these-days-109c73ee25)).
- A founder reported about 80 TestFlight testers from three opt-in sites ([Product Hunt discussion](https://www.producthunt.com/discussions/finding-retaining-early-beta-testers)); see also [first 45 beta testers](https://www.indiehackers.com/product/vuzers/first-45-beta-testers--MxhcsAEeyV5ad8W3x4r) and [first 200](https://www.indiehackers.com/post/how-we-got-our-first-200-beta-testers-key-takeaways-868e81e03f) (not fetched; titles only).
- Pattern: reach people where the problem is already discussed, give value first, ask admins, offer early access / lifetime or free pro, give direct line to developer.
- **Gap:** I found no write-up comparing tester quality across channels. Do not assume Reddit "tester swap" subs give engaged users; they are often other developers.

## Q3. Trivia and quiz communities

**Czechia (strongest lead)**
- Hospodský kvíz (Brno-based company): weekly pub team trivia in 16 cities; the 8 cities shown list 146 pubs (Prague 45, Brno 20, Olomouc 19, České Budějovice 16, Ostrava 13, Plzeň 12, Hradec Králové 11, Liberec 10); has a national championship weekend; Facebook facebook.com/hospodskykviz.cz, Instagram, TikTok; contact via hospodskykviz.cz/kontakt. Team counts: not published ([site](https://www.hospodskykviz.cz)).
- Chytrý kvíz and Pubquiz: other Brno-origin organizers; Brno is the hub, with leagues in 50+ venues (2019) and "hundreds" of moderators, teams up to 8 ([Novinky 2019](https://www.novinky.cz/muzi/clanek/pro-pivo-s-kamarady-muzete-mit-i-inteligentni-zaminku-40299385), [Newstream 2025](https://www.newstream.cz/zpravy-z-firem/obycejna-prace-chytry-kviz-zmenil-zabavu-v-hospodach-rika-moderatorka-o-soutezi-ktera-prisla-z-brna)). Some teams play semi-professionally in several leagues (Novinky). PubQuiz Prague ran about 13 sessions/week in 2019.
- Fee context: about CZK 60-100 per team member in 2019; CZK 100 typical in Prague 2026 ([expats.cz](https://www.expats.cz/czech-news/article/gaming-together-the-ultimate-guide-to-prague-s-english-friendly-trivia-scene-and-pub-quiz-nights)). Organizers need a Ministry of Finance permit if prizes are involved (Novinky) — relevant if you ever sponsor prizes.
- English-friendly Prague nights (13 venues listed, e.g. Beckett's, Sally O'Brien's 12-week league, Nerd Alert geek/TV trivia, Bohemia Boards and Brews also Czech quizzes) ([expats.cz, Sept 2026](https://www.expats.cz/czech-news/article/gaming-together-the-ultimate-guide-to-prague-s-english-friendly-trivia-scene-and-pub-quiz-nights)). That article names no Facebook/Meetup groups.
- Student pub quizzes (NEWTON Pub Quiz Brno, CZK 250/team, Feb 2026) ([page](https://newton.university/en/newton-pub-quiz-brno/)).

**Slovakia (thin)**
- No national league, quizzing association or large FB group found. Found: ESN Bratislava Erasmus pub quizzes (one 2024 Slovakia-themed edition had 118 participants) ([ESN activity](https://activities.esn.org/activity/esn-cu-ww-pubquiz-slovakia-21531)); Košice IT Valley / FPT IT Pub Quiz ([page](https://www.kosiceitvalley.sk/?p=8737)); an organizer in northern Slovakia (Michal Vojtek) quoted in 2017 saying quizzes are a weekly routine for some groups ([Slovak Spectator](https://spectator.sme.sk/culture-and-lifestyle/c/pub-quiz-take-your-friends-order-drinks-and-put-your-heads-together)). Whether Hospodský kvíz or Chytrý kvíz operate in Slovakia: **unverified**.
- Facebook groups for Slovak quizzers, "Riskuj" / AZ-kvíz fan groups, and a Czech/Slovak quizzing association: **not found / unverified** (searches returned nothing). Needs manual Facebook search by the founder.

**English-speaking**
- LearnedLeague: over 35,800 members (March 2026, Wikipedia), invite-only, very hardcore ([Wikipedia](https://en.wikipedia.org/wiki/LearnedLeague)).
- r/PubQuiz about 756 members (GummySearch, possibly stale; the tool shut down Nov 2025); r/quiz about 21k; r/triviaoftheday about 6k ([GummySearch r/PubQuiz](https://gummysearch.com/r/PubQuiz), [r/quiz](https://gummysearch.com/r/quiz)). r/trivia size and self-promo rules: **unverified** (Reddit blocked fetching).
- Sporcle community and Discord trivia servers: no sizes found (search only returned bot listings on top.gg). **Unverified.**
- European Quizzing Championships exist ([Wikipedia mirror](https://bafybeiemxf5abjwjbikoz4mc3a3dla6ual3jsgpdr4cjr3oz3evfyavhwq.ipfs.4everland.io/wiki/European_Quizzing_Championships.html)); no Czech/Slovak link found.

**Adjacent use cases (road-trip, camping, parents, board-game/party-game groups):** I did not find sizable SK/CZ groups via search; Facebook groups are not indexed. **Unverified; manual FB search needed** (suggested search terms: "deskové hry", "stolní hry", "cestování s dětmi", "kempování", "chata").

## Q4. Are hardcore quizzers the right users?

No source studies this; this section is my reasoning, flagged as such.
- Pub-quiz players are a **social, group-ritual** segment: a team, a host, a drink. Trubbo's "hosts itself" promise maps directly onto their missing piece (a quizmaster) — good fit for evenings, parties, cottage. Organizers/moderators are different: they sell questions as a business and may see Trubbo as competition — approach as a content/partner angle, not as testers.
- LearnedLeague-type quizzers want hard, verified, deep questions; they will find factual errors fast. Valuable for accuracy QA, but their taste skews away from casual/family difficulty. Mom Test logic: trust what they **do** (sessions per week, completed games, pack purchases), discount what they **say they want** (harder questions).
- Weighting suggestion: use the Superhuman lens inside each cohort. Count "very disappointed" answers by cohort (pub-quiz regulars, parents, drivers) and build for the cohort that clears the bar, not the loudest one.

## Q5. Practical mechanics

- **TestFlight:** up to 10,000 external testers; public link with device/OS criteria; App Store Connect shows views/installs/criteria-met; in-app screenshot feedback and crash reports; 100 internal testers; 30 devices per tester ([Apple](https://developer.apple.com/testflight/)). Builds expire after 90 days ([9to5Mac coverage of public links](https://9to5mac.com/2018/09/26/testflight-public-links/), older; Apple's page did not state it — verify in current docs). Public-link testers are anonymous unless they email feedback, so you cannot tell who is who ([secondary summary](https://abhimuralidharan.medium.com/testflight-public-beta-invite-links-ios-beta-testing-made-simple-97d2023791d0)). Practical fix: a form (name, contact, why) before sharing the link, and an in-app tester code or Sentry user tag.
- **Perks commonly used:** early access, free or lifetime pro, direct developer contact ([skillselion](https://skillselion.com/skills/rshankras/claude-code-apple-skills/beta-testing)). For Trubbo: free Plus for the beta window, a founding-member Plus discount (not lifetime free — keep the willingness-to-pay test), a named-credit or "tester" badge, and a private WhatsApp/Discord channel (SK/CZ users favor WhatsApp/Messenger — assumption).
- **Size:** 20-50 per wave is the common starting guidance (games-oriented, [Bugnet](https://bugnet.io/blog/building-a-community-beta-testing-program)). Trubbo needs about 30 well-screened testers, not 300.
- **Quality metrics:** use your own telemetry. Suggested: D7 return, sessions per week, games completed, share of sessions that are voice vs. tapped, feedback items per tester, plus a Superhuman-style question after 3 sessions ("How would you feel if you could no longer use Trubbo?"). The 40% bar applies to the screened cohort, not to all testers.
- **Marketplaces:** BetaList positions itself as an early-adopter audience of "a few tens of thousands" ([G2 profile](https://www.g2.com/sellers/betalist)). No source found on whether those testers are freebie seekers; Betafy-type tools are cited for "variable quality and depth of feedback" ([SaaSHub comparison](https://www.saashub.com/compare-betafy-vs-betaforbeta)). My read: low expected value for a SK/CZ-language voice app (audience is startup-minded English speakers); test only as a cheap side channel.

## Concrete community list

| Name | Platform | Language | Approx size | Fit | How to approach |
|---|---|---|---|---|---|
| Hospodský kvíz (facebook.com/hospodskykviz.cz) | Facebook page + IG + TikTok + pubs | CS | 146 pubs in 8 of 16 cities; followers unverified | High: weekly team players, quiz-night ritual | Write via hospodskykviz.cz/kontakt; offer organizers/moderators a free Plus code and a "quiz night off-day" angle; do not pitch as competitor |
| Chytrý kvíz / Pubquiz (Brno, Prague) | Pubs + own sites/FB (unverified) | CS | 25 venues in 2019 (Brno); "thousands of regular participants" per page title | High, same as above | Ask a moderator (often students) to try it; moderators are plugged into regulars |
| Prague English-friendly quiz nights (Sally O'Brien's, Beckett's, Nerd Alert, Bohemia Boards and Brews) | Venue FB pages | EN (Bohemia also CS) | 4-10 teams per night | Medium-high: expat players, EN second market, geek/TV trivia | Ask the host; leave a QR/TestFlight card at the venue only with permission |
| Brno league players and student pub quizzes (NEWTON, university groups) | Pubs, university FB groups | CS | Unverified | Medium: young, social, heavy users | Student ambassador or a one-off "try the self-hosted round" slot |
| ESN Bratislava / Erasmus pub quizzes | Pub nights, FB | EN/SK | 118 participants at one 2024 event | Medium (EN, short-term residents) | Ask ESN organizers to include a Trubbo round |
| Košice IT Valley IT Pub Quiz | Event | SK/EN | Unverified | Low-medium: tech crowd, good for feedback | Contact organizers; offer a demo round |
| Slovak quiz / Riskuj / AZ-kvíz fan groups | Facebook | SK/CS | **Unverified** | Possibly high | Founder searches Facebook manually; read rules, message admins first |
| Board-game / party-game, camping, parent groups (SK/CZ) | Facebook groups | SK/CS | **Unverified** | High for non-pub use cases | Same: search, admin permission, post as a person with a small ask for a few families |
| r/PubQuiz, r/quiz, r/triviaoftheday | Reddit | EN | about 0.8k / 21k / 6k (GummySearch, may be stale) | Medium | Reddit self-promo limits apply (see your own notes); contribute first |
| LearnedLeague | Invite-only site | EN | over 35,800 | Accuracy QA only (see Q4) | Do not recruit via promotion; only a genuine member's referral |
| r/TestFlight, r/BetaTestersNeeded, r/iOSBeta | Reddit | EN | **Unverified** | Low quality likely (developers) | Quick test; measure retention before trusting |

## Implications for Trubbo

1. Reframe the goal: recruit about 30 screened testers in 3 cohorts of about 10 (pub-quiz regulars, parents/families/road-trippers, board/party-game hosts), SK/CZ first, a few EN.
2. Add a screener form before giving the TestFlight public link (or invite directly): last time they played a quiz, with whom, how often; what they'd use Trubbo for; willing to do a 15-minute call. This is the "commitment" signal. Offer: free Plus during beta, founding-member price on Plus afterward.
3. Measure with real behavior: Ellis question after 3 sessions, per-cohort; D7 return; sessions per week. Decide the cohort to build for from the "very disappointed" share (40% bar), not volume.
4. First outreach order: Hospodský kvíz / Chytrý kvíz organizers and moderators (CZ), then 2-3 Prague English quiz hosts, then manual Facebook search for SK/CZ quiz, board-game, camping, parents groups, asking admins first.
5. Treat hardcore-quizzer feedback as QA on question accuracy; do not let it drive difficulty or taste.
6. Practical gaps to close by hand: Facebook group sizes and rules, Slovak scene, r/trivia rules, TestFlight 90-day expiry confirmation.
7. Unrelated optimization (Rule 11): public-link testers are anonymous, so add a lightweight in-app tester tag (e.g. a code entered on first launch) so telemetry can be segmented by cohort.

## Sources

- Superhuman, PMF engine (2018): https://blog.superhuman.com/how-superhuman-built-an-engine-to-find-product-market-fit/
- Superhuman summary: https://pshimanshu.substack.com/p/heres-what-i-learned-about-product
- 1,000 True Fans summary: https://www.gigazine.net/gsc_news/en/20230107-1000-true-fans
- Mom Test: https://booksite-5ed.pages.dev/en/books/the-mom-test/ · https://mtlynch.io/book-reports/the-mom-test/
- Centercode feedback quality: https://centercode.com/blog/the-definition-of-high-quality-feedback
- Paid beta: https://siliconfilter.com/want-to-join-our-private-beta-pay-up · https://onepage-research.sliplane.app/lessons/validation/val-p229 · https://redlib.cypherpunktools.com/r/indiehackers/comments/1kal7e8/should_users_pay_during_beta_testing
- Tester recruiting: https://www.indiehackers.com/post/where-do-you-find-your-first-beta-testers-these-days-109c73ee25 · https://growthsnippets.substack.com/p/20-steps-to-get-your-first-10000 · https://www.producthunt.com/discussions/finding-retaining-early-beta-testers · https://bugnet.io/blog/building-a-community-beta-testing-program · https://skillselion.com/skills/rshankras/claude-code-apple-skills/beta-testing
- Tester quality platforms: https://help.betatesting.com/en/articles/1907214-how-we-measure-quality-tester-participation-tips-for-success · https://www.g2.com/sellers/betalist · https://www.saashub.com/compare-betafy-vs-betaforbeta
- TestFlight: https://developer.apple.com/testflight/ · https://9to5mac.com/2018/09/26/testflight-public-links/ · https://abhimuralidharan.medium.com/testflight-public-beta-invite-links-ios-beta-testing-made-simple-97d2023791d0
- Czech pub quiz scene: https://www.hospodskykviz.cz · https://www.novinky.cz/muzi/clanek/pro-pivo-s-kamarady-muzete-mit-i-inteligentni-zaminku-40299385 · https://www.newstream.cz/zpravy-z-firem/obycejna-prace-chytry-kviz-zmenil-zabavu-v-hospodach-rika-moderatorka-o-soutezi-ktera-prisla-z-brna · https://www.expats.cz/czech-news/article/gaming-together-the-ultimate-guide-to-prague-s-english-friendly-trivia-scene-and-pub-quiz-nights · https://newton.university/en/newton-pub-quiz-brno/
- Slovak scene: https://spectator.sme.sk/culture-and-lifestyle/c/pub-quiz-take-your-friends-order-drinks-and-put-your-heads-together · https://activities.esn.org/activity/esn-cu-ww-pubquiz-slovakia-21531 · https://www.kosiceitvalley.sk/?p=8737
- EN communities: https://en.wikipedia.org/wiki/LearnedLeague · https://gummysearch.com/r/PubQuiz · https://gummysearch.com/r/quiz · https://bafybeiemxf5abjwjbikoz4mc3a3dla6ual3jsgpdr4cjr3oz3evfyavhwq.ipfs.4everland.io/wiki/European_Quizzing_Championships.html
