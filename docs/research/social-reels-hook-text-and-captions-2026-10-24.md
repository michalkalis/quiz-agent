# Reels hook text and on-screen captions (2026-10-24)

Builds on `social-reels-hook-rate-2026-10-23.md` (hook rate, Skip Rate, templates; not repeated here).
Grades: **[P]** platform/official page · **[I]** industry/vendor blog or survey (secondary, mostly unaudited) · **[A]** anecdotal/creator. "Gap" = nothing found. No numbers invented; vendor numbers are quoted as claims.

## 1. TL;DR

**Topic A (first 0-3 s)**
- **Fuse, don't prepend.** Frame 1 shows the question card with a short hook line (<= 5 words) on it; voice starts the question immediately. A separate 1-1.5 s hook card has no supporting evidence and only anecdotal evidence against (title cards / logo intros cost retention). Control arm = question only. [A/I]
- **Same hook every time: not penalised by any rule we found, but it's an untested tradeoff, not a proven good.** YouTube's own policy explicitly allows a repeated intro/outro. Instagram's 2026 originality rules target other people's content. A fixed line cannot be specific to the question, and specificity is what separates hooks. [P for the rules; reasoning is ours]
- **Recommended structure:** fixed brand frame (monkey, countdown, sound, a short series tag) + rotating hook line from a pool of 6-8. Test fixed-line vs rotating as one arm (section 5).
- **Gap:** zero controlled data on hook-line-with-question vs question-only for trivia. Our own A/B is the only real answer.

**Topic B (captions)**
- **Captions are table stakes for accessibility and sound-off, but the retention uplift is unproven.** Meta says > 75% of Reels views are sound ON [P], so the "85% watch muted" stat is a Facebook-feed-era claim, not Reels. Vendor "20-40% more watch time" has no method behind it. [I]
- **Do not duplicate the question in captions.** The question card (full text, current word highlighted) already is the caption, and viewers need the whole question visible while the countdown runs. Add phrase-by-phrase captions only where no text is on screen: the **explanation phase**. [reasoning; evidence for captions in general is weak, see 3.2]
- **Layout:** captions in the vertical middle-to-slightly-below-center, 3-6 words per chunk, bold, high contrast, keep out of Meta's bottom 35% / top 14% / sides 6% safe-zone margins. [P for margins, I for the rest]
- **Gap:** no controlled study of word-highlight captions vs none on Reels/Shorts. Test explanation: paragraph vs phrase captions.

## 2. Topic A evidence

### 2.1 Hook line before / with / none
| Claim | Grade | Source |
|---|---|---|
| Meta: "invite your audience in with a hook" inside the Reels safe zone; hook is part of the first frames, not a separate pre-roll | P (ads guidance) | [1] |
| TikTok: state the proposition in the first 3 s, build the hook within 6 s, use text overlays | P (ads guidance, from prior doc) | prior doc |
| First text overlay should land within ~0.5 s ("the single most important element") | I (ad-creative agency, no data shown) | [2] |
| Removing a logo/title-card intro and opening on a direct question "tripled views"; slow title card = visible retention drop | A (single case, blog) | [3] |
| 50-60% of Shorts drop-offs happen in the first 3 s | I (vendor claim, also in prior doc) | [3] |
| No A/B comparing text-overlay-from-frame-1 vs none | **Gap** (a search for exactly this returned only recommendations) | [2] |
| Instagram's Skip Rate = share of views that left in first 3 s; Trial Reels give a 24 h read | P/I | [4][5] |

Read: everything points the same way (put the hook in the first frame, no pre-roll), but it is all recommendation-grade, not measured. Our fused design is the low-regret option; the separate card is the one to test against, not to default to.

### 2.2 What quiz accounts do in frame 1
I could not view TikTok/IG pages (not fetchable), so **first frames are NOT verified**. What secondary sources say:
- Large quiz accounts (follower counts per Typito [I]): @quizxtreme 1.6M (speed trivia, guess-the-flag/logo), @quiz__pro 456K (7.3M-view memory-test series), @laughhumor11 319K (750+ post quiz series, 9.1% engagement claimed). [6]
- Common mechanics: visible load-bar timer, ticking sound near the end, 3 s timers in shorts, confetti/emoji on reveal, **a mascot-as-timer ("Monkey Quiz": timer drains as Coco the monkey moves)**, the same format over and over. [I] [7]
- Note for brand risk: a monkey-timer quiz channel already exists on YouTube. Our mascot is not unique in the niche.
- **Action (10 min, founder or agent with a real browser):** open the 6 accounts above plus Quiz Blitz (913K YT), screenshot the first frame of 5 recent videos each, and note: question visible at 0.0 s? hook text? voice? Without this, claims about what "the big accounts do" stay inference.

### 2.3 Same hook text every time vs rotating
- **YouTube [P]:** the inauthentic-content policy (monetisation only) names as acceptable "same intro and outro for your videos, but the bulk of your content is different" and "similar content, like a series ... in which each video has a distinct storyline, focus, or concept". The test is "materially varied" substance per video. Non-monetised channels are outside this policy. [8] Risk for us: a fully templated pipeline (same layout, voice, structure) is closer to "templated with little variation" than any single opener is. Distinct question + explanation per reel is the defence; fixed hook text is not the issue.
- **Instagram [P-ish]:** 2026-04-30 update. Account becomes non-recommendable if most of what it posts is someone else's content (rolling 30 days); original = created or materially altered. Mosseri quote: "If most of what you post to Instagram is someone else's content, your account is no longer going to be recommendable." Sources describe repost/near-identical detection, not repeated openers by the same creator. [9] Facebook's July 2025 rule similarly targets duplicate videos and reposts. [10]
- **Not found:** any statement that Instagram or Shorts demotes identical opening lines on different videos. Treat as "no evidence of penalty", not "proven safe".
- **Recognisability:** only anecdote ("Hello everyone, this is your daily dose of internet" is on every Daily Dose of Internet video [A] [11]). TikTok series-hook article recommends varying framing across episodes while keeping a recurring "thread" (phrase, motif or question). [I] [12] Instagram has a Series feature linking parts; each part should still stand alone for non-followers. [I] [13]
- **Our tradeoff (reasoning):** discovery goal means most viewers are strangers who see a reel once; recognisability pays off only for repeat viewers, while a specific hook pays off on every first view. So: keep the recognisable elements non-textual and constant (monkey, countdown look, sounds, a 1-2 word tag like "Kvíz #12" or difficulty label) and rotate the hook line.
- Series numbering ("Part 12 of ...") only makes sense if reels are ordered/sequential; ours are independent. A number on an independent reel invites "where is part 1?" friction. Hypothesis, untested.

## 3. Topic B evidence

### 3.1 Sound-off share, and what captions buy
| Claim | Grade | Source |
|---|---|---|
| Over 75% of Reels views on Instagram are sound on | P (Meta developer blog, 2024-11) | [14] |
| Reels audio is on by default; Meta advises building with audio (voiceover, music) | P | [1][14] |
| 93% of TikTok users spend time with sound on; 88% say sound is essential | P (TikTok/Kantar marketing study; methodology not given) | [15] |
| Facebook 2016 internal tests: captions raised video-ad view time by 12% on average | P-secondary, old, Facebook feed ads, not Reels | [16] |
| Verizon Media/Publicis 2019 survey, n = 5,616 US adults 18-54: 80% say more likely to watch whole video with captions; 69% watch muted in public places | I (self-reported survey) | [17] |
| "85% of Facebook video plays are muted" | I (circulating stat, Facebook-feed era; conflicts with Meta's own Reels 75%+ sound-on) | [2] |
| Captioned Reels get "20-40%" / "23-40%" more watch time | I (Krumzi: author's own tests; Opus: no methodology) | [18][19] |
| Animated vs static captions: "does not have evidence sufficient to claim a general uplift"; a good example does not isolate the caption effect | I (honest vendor note) | [20] |
| Word-by-word highlight "highest retention", 70% of top creators use it | I (Opus, unsourced) | [19] |

Conflict flagged: vendors say "majority muted"; Meta says > 75% of Reels views are sound on. **Prefer Meta for Reels**. Our voice carries the content, so captions mostly serve the muted minority, accessibility and attention, not a majority. Gap: no figure for Shorts sound-on share found; no figure for a trivia audience.

### 3.2 Best practices (convergent vendor guidance, [I] unless noted)
- **Words per chunk:** sources disagree: 3-6 words per caption [18]; 5-8 ideal, 8-12 max [19]; 5-8 per overlay, max 2 lines [21]. Your 1-4 word style is common but not supported by any test found. Practical read: 3-6 words, 1-2 lines.
- **Position:** Meta [P]: keep 14% top, 35% bottom, 6% sides clear for Reels ads (about 269 px / 672 px / 65 px on 1080x1920). [1][22] Creator guides: vertical middle, slightly below center [18]; some say avoid bottom 20% / use upper third [19]. For us: caption band centered at about 55-60% of height, ending above y ~ 1240. Organic Reels have a smaller bottom overlay (about 450-500 px per [18]); the ad margin is the safe superset.
- **Size/contrast:** >= 48-60 px, bold [18][21]; contrast >= 4.5:1 [19] or a solid box/heavy outline [18]. 
- **Highlight:** current-word colour pop vs whole-phrase: no test found [20]. Emphasising 1 key word per chunk (colour/scale) is the common convention [I].
- **Timing:** appear 0.1-0.3 s before the word [19][21]. We have exact TTS word timestamps, so sync to those; a small lead is unmeasured.
- **Duplicating on-screen text:** [A/I] no source addresses it for trivia. Theory: the multimedia **redundancy principle** (Mayer) says narration + pictures beats narration + pictures + identical on-screen text; the exceptions are keywords/technical terms and non-native listeners. [23] That is a learning-lab finding, not a retention measurement, and one vendor reads it the other way (matched text and audio "improves retention") [21]. Contradictory, so we treat it as: don't triple-stack the same words, do reinforce selectively.
- **What quiz makers do:** sources describe timers, emoji/confetti reveals, answer highlight boxes; none mention burning in captions of the question. [7] 

### 3.3 Instagram's own captions
- Instagram generates closed captions from speech for Reels; creator can switch them on; viewers see them if they use the Accessibility > Captions setting or toggle per reel, text sits at the bottom. [24][25] The Meta help page and RNID page did not render for me, so **whether viewers see them by default is unverified**. Third-party text suggests closed captions "only show if the viewer has them on" [18].
- Burned-in and closed captions can coexist ("they sit alongside") [18] but, for viewers with CC on, you get two text layers (ours mid-frame, Instagram's at the bottom). Not harmful, just redundant.
- Unverified for us: accuracy of Instagram ASR for Slovak/Czech, and whether our posting path (manual app vs API) can attach captions. Check one real post on a phone before deciding.

## 4. Variants for our reel

| Variant | Question phase | Explanation phase | Pros | Cons |
|---|---|---|---|---|
| **V0 current** | Question card, current word highlighted | Paragraph card | Baseline; question fully readable during countdown | Paragraph is the likeliest late-drop point; no hook line |
| **V1 (recommended)** | Same card + hook line (<= 5 words) on frame 1; keep word highlight | Phrase-by-phrase captions, 3-6 words, mid-frame, 1 key word emphasised, synced to TTS | No duplicated text; captions exactly where no text exists; keeps whole question visible while thinking | Needs a caption renderer for the explanation; word-highlight effect on the question is unmeasured |
| **V2 minimal** | Static question card, no highlight, + hook line | Phrase captions | Cleanest frame; fewest moving parts | Loses the read-along highlight (might help sound-off viewers follow) |
| **V3 captions everywhere** | Question as big phrase captions over a smaller card, plus options | Phrase captions | Most "native" look; strong for muted viewers | Duplicates the question (redundancy); more motion competes with the countdown; fastest to look generic |

Hook line in all variants: fused on frame 1 and held 1.5-2 s; no voiced pre-roll.

## 5. A/B test plan (Instagram Insights, Trial Reels)

**Metrics:** hook = Skip Rate (lower is better) and 3-s views; tail = average watch time and (if shown) watch-through; reach from non-followers; sends per reach. Calibrate on our own first ~20 posts (benchmarks in prior doc are vendor only).
**Instruments:** Trial Reels show only to non-followers, give a read after ~24 h, can auto-share on strength within 72 h. [5] Eligibility is reported as 200 followers (professional) in one source and 1,000 in another: **verify in app**. Whether Trial insights include Skip Rate is unverified (one summary lists views/likes/comments/shares only). Shorts: YouTube Studio's "viewed vs swiped away" and per-second retention graph are the best instrument for the explanation phase. [A/I]
**Design rules:** change one variable per test; same voice, music, length; randomise which question gets which arm and balance category/difficulty; run EN and SK/CZ separately, never pooled. Per-reel noise from question quality will dominate, so judge by arm medians over >= 10 reels per arm (our rule of thumb, not a power calculation); a gap under ~5 pp of Skip Rate is likely noise.

| Test | Arms | Primary metric | Decision rule |
|---|---|---|---|
| T1 hook placement | A question only (control) · B hook line fused on frame 1 · C separate 1.2 s hook card | Skip Rate, 3-s views | Keep B only if median Skip Rate beats A; drop C unless it beats both |
| T2 fixed vs rotating hook | B-fixed (one line, all reels) · B-rotating (pool of 6-8) | Skip Rate, sends per reach | Run after T1; rotating wins ties (more specific, no fatigue risk) |
| T3 explanation captions | Paragraph card (V0) · phrase captions (V1) | Average watch time, retention at explanation start-to-end | Keep phrase captions if watch-through improves with no Skip Rate harm |
| T4 question highlight | Karaoke highlight on card · static card | Skip Rate, watch time | Run last; low expected effect |

Guardrails: hook must match content (no unverifiable "only 3% know this"); keep captions out of the safe-zone margins; spot-check one post per account on a real phone before scaling.

## 6. Sources
1. Meta, Reels ads creative best practices (sound on by default, safe zone, hook): https://www.facebook.com/business/ads/facebook-instagram-reels-ads
2. RocketShip HQ, text overlays in video ads: https://www.rocketshiphq.com/text-overlays-video-ads-mobile/
3. GoFaceless, Shorts retention (logo-intro anecdote, 50-60% first-3-s claim): https://www.gofaceless.ai/tr/blog/youtube-shorts-retention-strategy
4. Metricool, Instagram Reels analytics / Skip Rate: https://metricool.com/instagram-reel-analytics/
5. Metricool, Trial Reels: https://metricool.com/instagram-trial-reels/ · Publer: https://publer.com/blog/instagram-trial-reels-guide/
6. Typito, top TikTok quiz channels: https://typito.com/blog/tiktok-quiz/
7. Typito, quiz channel timers/mascot/series: https://typito.com/blog/quiz-channel
8. YouTube Help, inauthentic content: https://support.google.com/youtube/answer/1311392
9. Planoly on Instagram's 2026-04-30 originality update (links Mosseri's reel): https://planoly.com/blog/instagram-updates-its-original-content-policy · PetaPixel: https://petapixel.com/2026/04/30/new-instagram-policies-target-reposted-content/ (not fetched, 403)
10. TechCrunch, Meta unoriginal content crackdown 2025-07: https://techcrunch.com/2025/07/14/following-youtube-meta-announces-crackdown-on-unoriginal-facebook-content
11. Daily Dose of Internet catchphrase: https://www.pluggedin.com/youtube-reviews/daily-dose-of-internet/
12. Influencers-Time, TikTok series hook sequences: https://www.influencers-time.com/tiktok-creator-series-hook-sequences-and-watch-time/
13. Techloy, Instagram Series: https://www.techloy.com/multi-part-reels-just-got-easier-to-follow-as-instagram-rolls-out-series-feature/
14. Meta for Developers, Reels ads (> 75% sound on): https://developers.facebook.com/blog/post/2024/11/07/unlock-the-power-of-reel-ads/
15. TikTok x Kantar sound study: https://ads.tiktok.com/business/en/blog/kantar-report-how-brands-are-making-noise-and-driving-impact-with-sound-on-tiktok · 93% figure via https://ppc.land/the-power-of-sound-in-tiktok-ads/
16. 3Play on Facebook 2016 captions test (12%): https://3playmedia.com/blog/captions-increase-viewership-for-facebook-video-ads
17. Verizon Media/Publicis 2019 survey via 3Play: https://www.3playmedia.com/blog/verizon-media-and-publicis-media-find-viewers-want-captions/
18. Krumzi, Reels captions and safe zones: https://www.krumzi.com/blog/add-captions-to-instagram-reels
19. Opus, caption presets: https://www.opus.pro/blog/best-caption-presets-styles-boost-retention · Opus, Reels captions: https://www.opus.pro/blog/instagram-reels-caption-subtitle-best-practices
20. BlitzCut, animated vs static captions: https://blitzcutai.com/blog/animated-captions-vs-static-captions
21. RocketShip HQ (see 2)
22. Safe-zone pixel conversion: https://adnova.ai/blogs/meta-ad-safe-zones-guide
23. Mayer redundancy principle overview: https://pressbooks.pub/elearning2020/?p=57
24. Instagram Help, closed captions for Reels (page did not render): https://help.instagram.com/7487270478066359/
25. RNID, Instagram captions: https://developer.rnid.org.uk/information-and-support/technology-and-products/social-media-captions/instagram/ (did not render)
