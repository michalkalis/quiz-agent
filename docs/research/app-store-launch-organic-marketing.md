# Research: Organic & Low-Budget App Store Launch Marketing

**Date:** 2026-09-13 | **Query:** Organic / sub-5 000 CZK (~200 EUR) playbook for launching Hangs — a voice-first, hands-free trivia app for road trips (freemium, 30 free answers/month + €4.99 sub + packs, EN/SK/CS) — as a solo indie in Slovakia targeting SK/CZ first.

## Executive Summary

- **ASO is the only channel that compounds.** ~60 % of App Store downloads come from search, ~50 % of those from generic rankable terms [1]. Everything else on this list is a spike; search is the annuity.
- **Apple featuring is a queue, not luck — and almost no indie applies.** The App Store Connect *Featuring Nominations* form is the single formal channel; submit 6–8 weeks before launch. Reported impact for a niche app featured as App of the Day: 5 000–20 000 downloads in 24 h [2] (single-source figure, treat as indicative). Localization quality and a "signature capability" are explicit scoring criteria — Hangs has both (SK/CS + voice-first/CarPlay).
- **Product Hunt has decayed hard for iOS.** Only ~10 % of launches get featured; non-featured launches see 100–500 visitors and 1–15 signups total [3]. It converts to *web clicks*, not App Store installs [4]. Worth one shot for the backlink and badge; not worth building a campaign around.
- **Community seeding is the highest-leverage free channel, but it is slow and rule-bound.** r/iosapps permits one self-promo post per dev per 30 days; Reddit-wide the norm is 90/10 participation-to-promo, and posting a link in 5 subs in one day is the fastest route to a sitewide shadowban [5][6].
- **SK/CZ is a cheap, under-contested market.** Eastern-European cost-per-tap is reported 80–90 % below US levels [7], and CZ/SK App Store locales have far less keyword competition than EN [8]. A 200 EUR Apple Ads test buys real signal here in a way it never would in the US.
- **Barter with nano-influencers is the realistic paid-adjacent play.** CZ nano tier (1–10 k followers): ~500–3 000 CZK per IG post, 1 000–5 000 CZK per TikTok video, and they routinely accept product-only barter [9] — a lifetime sub + packs costs Hangs nothing but is a plausible trade.
- **Calibrate expectations down.** Global median D30 retention is 5.4 %; 8 in 10 new apps never pass $10 K lifetime revenue; indie CPI $0.10–$0.80 [1]. Freemium free→paid at 30 days sits at 2–8 % for well-run subscription apps [10].

## Key Findings

### 1. App Store Optimization

- **Field budget:** title 30 chars, subtitle 30 chars, keyword field 100 chars (iOS-only, not indexed on Google Play), description 4 000 chars (not indexed on iOS) [11][12]. No spaces after commas in the keyword field, never repeat a word already in title/subtitle — each is indexed once [12].
- **Keyword shape:** two-word phrases are the sweet spot, ~half of top App Store keywords [12]. Group into primary / secondary / long-tail rather than chasing one head term. Mine your own reviews for the phrases users naturally use [12].
- **Screenshots:** decision happens in ~3–7 seconds; the first two carry the bulk of conversion lift [1][12]. Lead with the benefit ("Play trivia with your hands on the wheel"), not a UI tour. Screenshot caption text is OCR-indexed by Apple, so captions are keyword surface too [4].
- **Custom Product Pages (CPP):** reported average lift of +2.5 pp over a 1.6 % baseline (~156 % relative) [1]. CPPs are free and unlimited-ish — map one per audience: *road trip / driving*, *party & cabin*, *kids & family*. Each CPP's first screenshot must answer the intent that produced the visit [12].
- **Product Page Optimization (A/B):** Apple allows 3 concurrent treatments per test; quarterly testing is reported to lift conversion 20–30 % vs. annual-only updates [1][12].
- **Localization (SK/CS):** Czech and Slovak locales are low-competition and let you index a whole extra keyword set per locale; each locale must be semantically independent [8][13]. Slovakia's App Store storefront also indexes Czech metadata via cross-localization in several CEE territories — worth verifying per-territory before relying on it [13]. Practical upshot: fill SK + CS + EN(UK/US) metadata fully; do not machine-translate — localization *quality* is an Apple featuring criterion [2].
- **Rating prompt timing:** `SKStoreReviewController` is capped at 3 prompts per user per 365 days [14]. Fire it after a *satisfaction moment* — a completed quiz with a good score, or a finished road-trip session — never on launch, never after a wrong answer, never on the paywall [14]. Common gates: user installed >7 days ago, opened ≥3 sessions [14]. Each extra half-star correlates with roughly 20 % higher download rate [15] (correlational, not causal).
- **Timeline:** ASO changes show meaningful movement in 4–8 weeks [1] — so metadata must be right *before* any traffic push.

### 2. Apple featuring

- **Where:** App Store Connect → Apps → [App] → Featuring → Nominations. Requires Account Holder / Admin / App Manager / Marketing role; a Developer-only role cannot see the form [2].
- **Fields:** internal nomination name, nomination type (*App Launch* / *App Enhancements* / *New Content*), description, publication date or window, and optional related apps (≤10), platforms, target regions, In-App Events, supplemental URLs (≤5) [2].
- **Timing:** 3 weeks is the hard minimum; 6–8 weeks recommended for App Launch, 3–4 for Enhancements, up to 3 months for broad consideration [2][16].
- **Apple's stated scoring dimensions:** user experience, UI design, innovation (meaningful use of new iOS APIs), uniqueness, accessibility, localization quality, product page quality [2]. Generic updates and bug fixes essentially never get featured [2].
- **What Hangs can claim credibly:** a signature capability (fully hands-free voice quiz — a genuine safety/UX argument), multi-language localization done properly (EN/SK/CS), a human story (solo Slovak dev building for his own road trips), and a seasonal hook.
- **Seasonal hooks worth targeting:** summer road-trip season (Apple and Apple-adjacent media reliably run "road trip" audio/CarPlay angles in May–June [17][18]), plus the Christmas/New Year travel window and school holidays. Target regions: nominate **SK and CZ explicitly** — a small-territory feature is far more attainable than a US one, and it is exactly the kind of local story editors in small storefronts look for.
- **CarPlay/voice:** voice-first interaction fits CarPlay's safety model natively [17]. If Hangs ships a CarPlay target, that is an "innovation / meaningful use of a platform API" hook to lead the nomination with. Note as an unverified assumption: CarPlay entitlements for a non-navigation/non-audio category may require Apple approval — confirm against Apple's CarPlay developer docs before promising it in a nomination [19].
- Reported featuring impact for a niche app: 5 000–20 000 downloads in 24 h [2]. Single source; treat as an order-of-magnitude estimate.

### 3. Launch platforms

- **Product Hunt (2025–26 reality):** ~10 % of launches get featured (down from 60–98 % in 2020–2023). Featured: 1 000–5 000 visitors and 10–150 signups per day. Non-featured: 100–500 visitors, 1–15 signups [3]. Typical visitor→signup conversion is 1–3 %, not the folklore 5–10 % [3]. 89 % of surveyed founders said they would not launch again — while still valuing the DA-91 backlink and badge [4]. Mechanics that still matter: self-hunt (the third-party hunter edge is gone), launch 00:01 PT Tue/Wed, strong maker first comment, bring your own audience [4].
- **Verdict for Hangs:** one launch, ~half a day of prep, treat the outcome as a backlink + social proof asset. Do not build the launch week around it. **0 CZK.**
- **Hacker News (Show HN):** one measured indie attempt reported ~120 views and 0 conversions [20]. Consumer trivia is off-audience for HN unless the post is a *technical* story (e.g. "how I built a fully hands-free voice quiz with on-device speech + LLM"). That framing is the only version worth posting.
- **Reddit as launch platform:** see §4.
- **Other directories:** BetaList, AppRaven, Indie Hackers, Indie App Santa. Indie Hackers reportedly converts far better than PH (23.1 % vs 3.1 % visitor→signup in one dataset [3]) but with tiny absolute volume. Indie App Santa is *paid* ($300–800 iOS) and out of budget [15] — noted only so it is not mistaken for free.
- **Skip:** press-release wire services and TechCrunch/Verge pitching — reported near-impossible without warm intros [20].

### 4. Community seeding

- **The rule that governs everything:** ~90 % genuine participation / ≤10 % self-promotion; some subs enforce closer to 99/1. Build 2–4 weeks of real comment history in a sub *before* posting anything of your own [6].
- **r/iosapps:** self-promo allowed but **once per developer per 30 days**; violations → removal, repeats → permanent ban and possible sitewide spam enforcement [5].
- **r/SideProject:** friendly to self-promo, but the post must tell a story — what you built, why, what stack, what feedback you want [5][6].
- **Instant-ban behaviour:** same link in 5 subs on one day with no prior history; sockpuppet upvoting; identical crossposts [6].
- **Target subs for Hangs** (verify each sub's current rules at post time — they change): r/iosapps, r/iOSProgramming (technical story), r/SideProject, r/apple (very strict, effectively no self-promo), r/CarPlay, r/roadtrip, r/roadtrippers, r/trivia, r/quiz, r/Parenting, r/FamilyTravel, r/Slovakia, r/czech. Note as unverified: I could not confirm current self-promo policy for the road-trip/trivia/parenting subs from sources — read the sidebar and ask a mod before posting.
- **Tactic that works:** find existing threads ("what do you do with kids on a 6-hour drive?") and answer the question first, disclose "full disclosure: I built this", link second [6]. This is slower but essentially ban-proof.
- **Facebook groups (SK/CZ):** the realistic local equivalent — caravan/camping groups, "Cestujeme s deťmi", regional road-trip groups, Apple/iPhone SK+CZ user groups. Admin permission first; a genuine "I built this, here are 20 free lifetime codes for this group" post reads as a gift, not spam. **0 CZK.**
- **Discord:** iOS indie dev servers and trivia/quiz communities for feedback and early testers, not for volume.
- **Parenting portals (CZ/SK):** Modrý koník and eMimino are the two large Czech family communities, with forum-based discussion and classifieds [21]. Both are community-moderated; treat them as participation channels, not ad channels. Unverified: neither publishes an obvious "promote your app" path — contacting the site's editorial/commercial address is the clean route.

### 5. Short-form video (TikTok / Reels / Shorts)

- **Faceless works.** In one 2025–26 dataset faceless videos averaged 1.5 M views vs 1.3 M for face-led [22]. Formats that scale: screen recordings, B-roll + text overlay, slideshows, story-based edits [22].
- **Reach has compressed.** Average organic reach fell from ~15–20 % (2024) to a reported 4–8 % for many gaming accounts by early 2026 [22]. Plan for a long tail of near-zero videos punctuated by occasional hits — not steady reach.
- **Cadence:** ≥1 video/day, batch-produced, is the common recommendation [22]. For a solo founder, 3–5/week batched in one session is the realistic version.
- **Caveat for utility apps:** one indie survey found TikTok/IG demos work for *visually demonstrable* apps and largely fail for utilities [20]. Hangs is fortunate here: the demo-able artifact is not the UI, it is **the moment in the car** — phone face-down, four people shouting answers. That is native short-form content.
- **Formats to test for Hangs:** (a) POV car footage with the quiz audio as the soundtrack and captions as subtitles; (b) "answer this before the car in front changes lanes" hook; (c) kids-vs-parents round; (d) build-in-public shorts on the voice pipeline (targets devs, not users — different account or at least different series).
- **SK/CZ specifics:** Slovak/Czech-language content has a tiny creator pool in this niche, so local-language videos face much less competition than English — but the total addressable audience is also small. Note as an estimate, not a sourced figure. Run EN and SK/CS as separate accounts; mixed-language accounts confuse the recommendation algorithm.

### 6. Local SK/CZ channels

- **Slovak/Czech Apple media is the single best-fit press target.** Svetapple.sk explicitly states it occasionally receives apps from Slovak developers; Letem světem Applem, Jablíčkář.cz and MacBlog.sk are the CZ/SK Apple-ecosystem equivalents [23][24]. A polished Slovak-made, Slovak-localized voice app is exactly their beat, and they have far lower pitch volume than any English outlet.
- **General tech media:** Živé.sk is the most-read Slovak technology outlet (since 1999) [25]; Fontech (Startitup group) publishes at redakcia@fontech.sk, Startitup at redakcia@startitup.sk [26]. CzechCrunch covers the Czech startup/tech scene and runs Startup Awards [27]. Lupa.cz, Techbox.sk, SME Tech and Refresher round out the list.
- **Angle that gets a Slovak outlet to write:** not "new quiz app" — write "Slovak developer built a trivia app you play entirely by voice, so you can play while driving", ideally pegged to the summer holiday travel wave. Local-founder + safety + AI voice is three hooks in one.
- **Realistic outcome estimate (unsourced, flag as estimate):** a Živé.sk or CzechCrunch piece plausibly drives hundreds to low thousands of page visits and a much smaller number of installs; Apple-niche sites drive fewer visits but far better-qualified ones.
- **Podcasts:** SK/CZ tech podcasts (e.g. the Letem světem Applem podcast, Slovak tech shows) are an under-pitched channel — a solo-founder story is podcast-shaped and a 30-minute conversation outlives an article.
- **Cost: 0 CZK** for all of the above. Press outreach costs only time.

### 7. Micro-influencers and barter

- **CZ nano tier (1–10 k followers):** ~500–3 000 CZK per Instagram post, 1 000–5 000 CZK per TikTok video, and they **often accept pure barter** (product for review) [9].
- **CZ micro tier (10–100 k):** 3 000–15 000 CZK per IG post, 5 000–20 000 CZK per TikTok video, 8 000–25 000 CZK per YouTube video; stories package (3–5 stories) 2 000–8 000 CZK [9]. This tier is out of the 5 000 CZK budget except at its very bottom edge.
- **Rule of thumb cited in CZ market:** price ≈ 5–40 % of follower count in CZK (a 20 k-follower creator → 2 000–10 000 CZK plus product) [28]. Higher-value product reduces the cash component [28].
- **Engagement:** nano tier runs ~5–8 % engagement, the highest of any tier [9].
- **Realistic outcome:** one indie survey estimates micro-influencer partnerships cost 20–40 hours of work for 500–2 000 total installs [15] — good value at 0 CZK cash, poor value at 15 000 CZK.
- **Barter offer for Hangs:** lifetime Pro + all packs + a personalised "Hangs x <creator>" quiz pack (their own questions / their audience's in-jokes). The custom pack is the differentiator — it gives the creator a piece of content, not just a code. **Cost: ~0 CZK, high effort.**
- **Target creator types in SK/CZ:** family travel and caravan/camping accounts, "cestujeme s deťmi" parenting creators, and Apple/iPhone tip accounts. Nano tier only.

### 8. Paid with a tiny budget

- **Apple Ads, not Meta, for 200 EUR.** Apple Search Ads captures *intent* at the point of install; Meta needs volume and creative iteration that 200 EUR cannot fund. Apple Ads Basic (CPI-billed, near-zero management) is the right entry for a solo dev; Advanced gives keyword control but needs more attention.
- **Benchmarks:** global median CPT ~$0.92 [7]; median country CPA ~$0.51 with a spend-weighted blended CPA of $1.34 and European markets broadly $0.84–$1.34 [29]. CPI by country: US $4.06, JP $2.57, UK $2.60, DE $2.14, FR $1.78 [30]. CZ/SK are **not broken out** in the sources found — treat any specific SK/CZ CPI as unknown. What *is* sourced: CEE (incl. CZ and SK) has quality users, minimal competition, and cost-per-tap reported 80–90 % below the US [7].
- **Estimate (flag as estimate):** at a CPT in the low tens of eurocents and a plausible 40–60 % tap-to-install rate in a low-competition locale, 200 EUR could buy roughly 300–1 500 installs in SK+CZ. This is an extrapolation, not a measured figure — validate with a 20 EUR/day capped test before committing the rest.
- **Install→paid:** Games converts at 3.19 %, Education at 5.87 % [29]. Hangs sits between the two; Apple's own category choice matters here — Education/Trivia positioning attracts higher-intent taps than pure Games.
- **Discipline:** do not run ads until the product page converts. Paid traffic onto an untested page burns the whole budget learning what a free CPP A/B test would have told you [1].
- **Worth noting:** paid campaigns need ~50 conversions in 7 days to stabilize algorithmically [1] — 200 EUR in a cheap locale can actually clear that bar, which it could not in the US.

### 9. Referral & word-of-mouth mechanics

- **Frame sharing as a gift, not a commission.** The best-performing referral mechanic gives the *recipient* a complete experience rather than a discount; gift subscriptions convert notably better than "earn 10 % off" [31][32].
- **Referral programs amplify existing word-of-mouth; they do not create it** [32]. One indie source suggests ~1 000+ active users before a referral program gains traction [15] — so do not build this for launch week.
- **Placement:** the referral CTA must be reachable in ≤2 taps and above the fold, not buried in settings [32].
- **Mechanics that fit Hangs specifically:**
  - **Passenger capture.** A quiz in a car has 3–4 listeners and 1 installer. End-of-session: "Send this quiz to everyone in the car" → a link that gives each recipient the same pack free. This is the single highest-leverage loop Hangs has and it is native to the use case.
  - **Pack gifting.** Gift a pack (not a discount) — the recipient gets a whole experience [31].
  - **Family mode.** Support Apple Family Sharing on the subscription; it turns one purchase into a household's worth of advocates at zero marginal cost.
  - **Share the score card.** A generated end-of-quiz image (team name, score, funniest wrong answer) is shareable content; the app link rides along.
- **Non-monetary referral incentives** (extra free answers, an unlocked pack) are the standard indie approach and cost nothing [15].

### 10. Pre-launch

- **Landing page + waitlist:** costs 0 CZK (single static page). It exists to (a) capture the Product Hunt / press / social traffic that cannot install yet, and (b) give you an email list to fire on launch day — "bring your own waitlist" is cited as a top PH success factor [4].
- **TestFlight public link as marketing:** a public TestFlight link converts curious visitors into actual testers *before* App Store approval, giving real feedback and a pool of day-one reviewers. Note Apple's 10 000-tester cap on public links (verify current limit). Caution: a public link exposes builds widely — keep it pointed at a stable build.
- **Press kit contents** [33][34]: one-paragraph and one-sentence descriptions; founder/founding story; the app's single signature capability; high-res icon; 5–8 screenshots (device-framed and raw); a 30–60 s demo video; App Store link and a direct TestFlight/promo-code link; pricing; availability and languages; contact + press contact; logo/brand assets. Host it as a single URL, not as an email attachment.
- **PR email structure** [33][34]: subject line = the story, not the app name ("Slovak dev built a quiz you play entirely by voice — for driving"); first line = why *this outlet's readers* care; second para = what it does in one sentence + the one differentiator; third = the founder hook; then links (press kit, promo codes, TestFlight); close with availability for a call. Keep under ~150 words. Personalise per outlet — generic blasts are the reported failure mode.
- **Promo codes:** Apple gives 100 promo codes per app version — reserve a block for SK/CZ journalists and barter creators.
- **Embargo:** standard practice is to pitch ~1–2 weeks out with assets under embargo lifting at launch [33].

### 11. Realistic numbers

- **Downloads.** No source gives a credible "typical first week" for a zero-budget indie app, and any number that claims to should be distrusted. What *is* sourced: 8 in 10 new apps never exceed $10 K lifetime revenue; indie CPI $0.10–$0.80; ASO needs 4–8 weeks to move [1]. Non-featured Product Hunt gives 100–500 total visitors [3]. Featuring, if it lands, is worth more than everything else combined (5 000–20 000 in 24 h [2]).
- **Working estimate (explicitly an estimate):** an unfeatured, unpaid, well-ASO'd SK/CZ launch is a low-hundreds first week, with the trajectory determined by whether ASO starts ranking in weeks 4–8 — not by launch day.
- **Retention.** Global median D30 retention 5.4 % [1]. This is the number that should scare you, not the download count.
- **Free → paid.** 2–8 % at 30 days for well-run freemium subscription apps; >5 % at 30 days is strong with a substantial free tier; 3–5 % good, 6–8 % great for self-serve freemium generally [10]. A quarter of freemium products convert <2.5 % within six months [10]. Note the measurement trap: rates computed on *activated* users look far higher than on all installs [10] — pick one definition and hold it.
- **Paywall structure.** Hard paywalls reportedly convert ~5× better than freemium (10.7 % vs 2.1 %), and trials of 17+ days convert ~70 % better than short ones (42.5 % vs 25.5 %) [1]. This is a real tension with Hangs' 30-free-answers model — worth an explicit product decision, not a default.
- **Revenue concentration.** The top 10 % of apps capture 94.5 % of subscription revenue [1].
- **Common mistakes indie devs report:** spreading thin across many channels instead of concentrating (one dev's 60-day test: only the single best dev.to article broke 1 000 views; everything else was single-digit traffic [20]); treating downloads as the metric; running paid before the product page converts; launching on Product Hunt with no post-launch funnel [4]; never submitting a featuring nomination at all [2].

## Implications for Hangs

- **The voice-first/hands-free angle is the entire marketing asset.** It is simultaneously the featuring hook ("signature capability"), the press hook (safety + local dev), the short-form video hook (the car moment), and the ASO differentiator. Every channel should lead with it; nothing should lead with "trivia app".
- **SK/CZ-first is a genuine structural advantage, not a compromise.** Low ASO competition [8], 80–90 % cheaper taps [7], local Apple media actively receptive to Slovak devs [23], and a small-storefront featuring nomination that is realistically winnable. English is the *second* wave, launched after the SK/CZ funnel is proven.
- **The car is a group setting — build the loop into the product.** One installer, three passengers. The end-of-session "send to everyone in the car" flow is worth more than any external channel and is the one thing on this list a competitor cannot copy for free.
- **Freemium tension is real.** 30 free answers/month is generous relative to the hard-paywall data [1]; the counter-argument is that a hands-free road-trip app needs to be tried *in the car* before anyone pays. Decide this with the founder — it is a product/monetization call, not a marketing one.
- **Seasonality is on your side and should drive the calendar.** Road-trip season (late spring → summer) and the Christmas/New Year travel window are the two natural featuring and press pegs.
- **CarPlay, if shipped, upgrades every pitch.** It turns "another quiz app" into "a platform-native driving experience" — the single strongest featuring argument available. Verify entitlement feasibility before building a campaign on it.

## Recommendations

**Pre-launch**

1. **Full ASO metadata in EN + SK + CS, hand-written per locale.** Title + subtitle + 100-char keyword field, no word repeated across fields. Two-word phrases; separate semantic sets per locale. — *0 CZK* — highest ROI item on this list.
2. **Screenshots: benefit-led, first two carry the load, captions keyword-bearing (OCR-indexed).** Lead frame = the car scene, not the UI. — *0 CZK* (or ~1 000 CZK if outsourcing one template).
3. **Submit the Featuring Nomination 6–8 weeks before launch**, type = App Launch, regions = SK + CZ (+ EN markets as secondary), description built around voice-first/hands-free + localization + solo-Slovak-dev story. Add supplemental URLs (demo video, press kit). — *0 CZK*.
4. **Press kit at a single URL + landing page with waitlist + public TestFlight link.** — *0 CZK*.
5. **Start the Reddit/Facebook warm-up now: 2–4 weeks of genuine participation before any self-promo post.** — *0 CZK*, ~2 h/week.
6. **Build the in-app share loop and the end-of-quiz score card before launch**, plus a gated `SKStoreReviewController` prompt (>7 days installed, ≥3 sessions, fired after a good score). — *0 CZK*, dev time.

**Launch week**

7. **Personalised pitches to ~12 SK/CZ outlets** — Svetapple.sk, Letem světem Applem, Jablíčkář.cz, MacBlog.sk, Živé.sk, Fontech (redakcia@fontech.sk), Startitup (redakcia@startitup.sk), Techbox.sk, SME Tech, Lupa.cz, CzechCrunch, Refresher — each with promo codes, each individually written. — *0 CZK*.
8. **One Product Hunt launch**, self-hunted, 00:01 PT Tue/Wed, strong maker comment, waitlist mobilised. Expect the backlink and badge, not installs. — *0 CZK*.
9. **One Show HN framed as a technical story** about the voice pipeline. Expect ~nothing; the cost is 30 minutes. — *0 CZK*.
10. **r/iosapps + r/SideProject posts (one each, story-shaped)** plus permission-first posts in 3–5 SK/CZ Facebook travel/family groups with free lifetime codes for group members. — *0 CZK*.

**First month**

11. **Short-form video: 3–5 posts/week, faceless, car-POV first.** Separate EN and SK/CS accounts. Test 4 hooks, double down on whichever breaks 10 k views. — *0 CZK*, highest ongoing time cost.
12. **Barter with 5–10 SK/CZ nano-influencers** (family travel, camping, parenting, Apple-tips), offering lifetime Pro + a co-branded custom pack. Cash only if a creator refuses barter and is clearly worth it. — *0–3 000 CZK*.
13. **Apple Ads test: 20 EUR/day capped, SK + CZ only, Basic or a tight Advanced keyword set.** Kill or scale after ~50 conversions. — *~100 EUR / ~2 500 CZK* of the budget; hold the remaining ~100 EUR in reserve.
14. **Three Custom Product Pages** (road trip / party & cabin / kids & family), each with a matched first screenshot, plus one Product Page Optimization test on the icon or first screenshot. — *0 CZK*.
15. **Reply to every review within 48 h; iterate metadata at week 4 and week 8** once search-term data exists in App Store Connect. — *0 CZK*.
16. **Do not** buy press-release distribution, paid directory placements, or micro-tier influencers at CZ list prices. The budget does not stretch and the sourced ROI is poor [15][20].

**Total cash: ~2 500–5 000 CZK, of which ~2 500 CZK is the Apple Ads test.** Everything else is time.

## Suggested launch calendar (phases, not calendar days)

- **Phase 0 — Foundation (before anything is visible).** ASO metadata in 3 locales; screenshots; CPPs drafted; share loop + rating prompt shipped; press kit + landing page live; Reddit/FB account warm-up begins.
- **Phase 1 — Nomination window opens (≥6–8 weeks before launch).** Submit Featuring Nomination. Open public TestFlight; drive the waitlist to it. Collect first testimonials and fix what testers break.
- **Phase 2 — Quiet build-up (2–3 weeks out).** Start posting short-form video *before* launch so the accounts are not cold. Pitch SK/CZ media under embargo. Line up barter creators. Verify CarPlay feasibility.
- **Phase 3 — Launch week.** App Store live → press embargo lifts → Product Hunt → Show HN → Reddit/FB posts → waitlist email. Compress into ~3 days, not one.
- **Phase 4 — Weeks 2–4.** Video cadence at full rate; barter creators publish (stagger them, do not burn them all in one week); reviews replied to; first ASO iteration once search data appears.
- **Phase 5 — Weeks 5–8.** Apple Ads test with a hard cap. CPP/PPO A/B test. Second ASO iteration. Decide from retention and free→paid — not downloads — whether to scale paid, scale video, or fix the product.
- **Phase 6 — Seasonal re-pitch.** Re-nominate for featuring as *App Enhancements* or *New Content* ahead of the next road-trip or holiday-travel wave with a new pack release as the hook.

## Sources

1. [Indie iOS App Marketing Strategy 2026: An Honest Playbook — ScreenFast](https://screenfast.app/blog/indie-ios-app-marketing-strategy-2026) — channel ROI ranking, D30 retention 5.4 %, CPP lift, indie CPI, paywall conversion data.
2. [App Store Featuring Nominations: Apple's 7 Scoring Criteria — AppScreenshotStudio](https://appscreenshotstudio.com/blog/get-featured-on-the-app-store-2026-nominations-guide) — form location, fields, timing, scoring criteria, featuring download impact.
3. [Product Hunt Launch Statistics for 2026 — Shno.co](https://www.shno.co/marketing-statistics/product-hunt-launch-statistics) — featured rate 10 %, traffic per launch, conversion rates, case studies.
4. [How to Launch an iOS App on Product Hunt (2026 Playbook) — ScreenFast](https://screenfast.app/blog/how-to-launch-ios-app-product-hunt) — PH mechanics, 89 % would-not-relaunch stat, iOS-specific friction.
5. [r/iosapps Self-Promotion Rules — LeadsRover](https://leadsrover.io/subreddits/r/iosapps) — one self-promo post per dev per 30 days; ban escalation.
6. [The complete guide to Reddit self-promotion rules in 2026 — Redship](https://redship.io/blog/reddit-self-promotion-rules) — 90/10 rule, per-subreddit table, ban triggers, practical tactics.
7. [Apple Search Ads Benchmarks 2026 — Sparrow Apps](https://sparrowapps.io/articles/apple-ads-benchmarks/) — CEE (incl. CZ/SK) cost-per-tap 80–90 % below US; global median CPT $0.92.
8. [9 App Store Localizations: Ukrainian, Polish, Czech and others — Asodesk](https://asodesk.com/blog/9-app-store-localizations-ukrainian-polish-czech-and-others/) — value of CZ localization, lower competition in smaller locales.
9. [Influencer marketing v Česku 2026: ceny a měření — ads-agency.cz](https://ads-agency.cz/blog/influencer-marketing-cesko-ceny-platformy-mereni/) — CZK price bands per tier and format, barter norms, nano engagement 5–8 %. (Direct fetch returned HTTP 403; figures taken from the indexed search summary — re-verify before relying on exact numbers.)
10. [Freemium Conversion Rate Benchmarks 2026 — Artisan Growth Strategies](https://www.artisangrowthstrategies.com/blog/freemium-conversion-rate-benchmarks) / [iOS free-to-paid conversion benchmarks 2026 — AppsOps](https://appsops.store/blog/ios-free-to-paid-conversion-benchmarks-2026) — 2–8 % at 30 days, measurement-definition caveat.
11. [App Store keyword research for ASO: the 2026 step-by-step guide — AppTweak](https://www.apptweak.com/en/aso-blog/app-store-keyword-research-aso) — field limits, research workflow.
12. [App Store Optimization Best Practices for iOS Apps 2026 — AppLaunchFlow](https://www.applaunchflow.com/blog/aso-best-practices) — keyword field mechanics, two-word sweet spot, screenshot and CPP guidance, PPO 3-treatment limit.
13. [App Store Cross-Localization Guide — aso.dev](https://aso.dev/metadata/cross-localization/) — territory-level indexation, semantic independence per locale.
14. [SKStoreReviewController Guide with Examples — Critical Moments](https://criticalmoments.io/blog/skstorereviewcontroller_guide_with_examples) — 3-prompts/365-days cap, timing and gating best practice.
15. [12 Low Cost App Marketing Strategies That Actually Work in 2025 — Indie App Santa](https://indieappsanta.com/2025/11/21/10349/) — micro-influencer effort/install estimates, referral-program threshold, half-star/download correlation. Vendor blog — treat its own-product figures as marketing.
16. [How to get your app featured on the App Store and Google Play in 2026 — AppTweak](https://www.apptweak.com/en/aso-blog/how-to-get-your-app-featured-on-the-app-store) — nomination timing windows.
17. [CarPlay just gained two new audio apps to keep you entertained on your next trip — 9to5Mac](https://9to5mac.com/2026/05/14/carplay-just-gained-two-new-audio-apps-to-keep-you-entertained-on-your-next-trip/) — evidence of the recurring summer road-trip editorial cycle; voice-first fits CarPlay's safety model.
18. [Autio: Road Trip & Travel App — App Store](https://apps.apple.com/us/app/autio-road-trip-travel-app/id1300494609) — comparable app timing CarPlay improvements to road-trip season.
19. [CarPlay — Apple Developer](https://developer.apple.com/carplay/) — CarPlay app categories and entitlement process (to verify before promising CarPlay in a pitch).
20. [I Researched 10 iOS Distribution Channels for 2026 — DEV Community](https://dev.to/snake_sun/i-researched-10-ios-distribution-channels-for-2026-here-is-what-indie-devs-should-skip-58gj) — 60-day channel experiment: Show HN ~120 views/0 conversions, dev.to concentration, skip-list.
21. [Modrý koník forum](https://www.modrykonik.cz/) — largest CZ parenting community; community-moderated, no published self-promo path found.
22. [2025 TikTok Organic Growth Report — Social Growth Engineers](https://www.socialgrowthengineers.com/2025-tiktok-organic-growth-report-lessons-trends-and-the-road-to-2026) / [TikTok Game Marketing for Indie Devs — Gamosy](https://gamosy.com/blog/tiktok-game-marketing) — faceless vs face-led view averages, organic reach decline 15–20 % → 4–8 %, cadence.
23. [Recenzie — Svetapple.sk](https://svetapple.sk/category/softver/recenzie/) — largest Slovak Apple magazine; states it receives apps from Slovak developers.
24. [Letem světem Applem](https://www.letemsvetemapplem.eu/) / [Jablíčkář.cz](https://jablickar.cz/) — CZ Apple-ecosystem outlets covering apps, reviews and tips.
25. [Živé.sk — Wikipédia](https://sk.wikipedia.org/wiki/%C5%BDiv%C3%A9.sk) — most-read Slovak technology outlet, operating since 1999.
26. [Redakcia — Startitup.sk](https://www.startitup.sk/redakcia-timu-startitup/) / [Redakcia — FonTech.sk](https://fontech.startitup.sk/redakcia/) — editorial contacts (redakcia@startitup.sk, redakcia@fontech.sk).
27. [O nás — CzechCrunch](https://cc.cz/o-nas/) — Czech startup/tech coverage scope and Startup Awards.
28. [Kolik stojí influencer marketing? — Marion Marketing](https://www.marionmarketing.cz/post/kolik-stoji-influencer-marketing) — CZ pricing rule of thumb (5–40 % of follower count in CZK); product value offsets cash fee.
29. [Apple Ads benchmarks 2026: CPT, TTR, CPA across 90 countries — Adapty](https://adapty.io/blog/apple-ads-benchmarks-2026/) — median CPA $0.51, blended $1.34, European range, Games 3.19 % / Education 5.87 % install-to-paid, small-budget advice.
30. [CPI Benchmarks by App Category and Platform: 2026 Data — SEM Nexus](https://semnexus.com/cpi-benchmarks-app-category-platform-2026) — per-country CPI figures (US/JP/UK/DE/FR).
31. [Best Mobile App Referral Program Examples (2026) — GrowSurf](https://growsurf.com/examples/mobile-app-referral-programs/) — gift-subscription mechanic, Calm example.
32. [In-App Referral Programs: The Ultimate Guide — AppSamurai](https://appsamurai.com/blog/building-in-app-referral-program-get-organic-downloads-for-almost-no-cost/) — referrals amplify existing WOM; placement rules (≤2 taps).
33. [How to Pitch Mobile Apps to Journalists — Pressdeck](https://pressdeck.io/blog/how-to-pitch-mobile-apps-to-journalists) — pitch structure, personalisation, embargo practice.
34. [Press Kit Creation Guide and Template (2026) — Shopify](https://www.shopify.com/blog/44447941-how-to-create-a-press-kit-that-gets-publicity-for-your-business) — press kit contents checklist.

**Fetch failures:** ads-agency.cz (HTTP 403 — figures recovered from search index, flagged at source [9]); ehub.cz influencer-earnings article returned a shell page with no body content.
