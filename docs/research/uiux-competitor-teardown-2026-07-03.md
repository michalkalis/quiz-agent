# Competitor UI Teardown — Screen-Level Patterns for the UI/UX Review

**Product:** Quiz Agent / Hangs — voice-first, hands-free trivia while driving
**Date:** 2026-07-03
**Scope:** The screen-level UI layer that `competitive-analysis-voice-driving-trivia-2026-06-27.md` deliberately did not cover. That doc owns market/positioning; this one documents concrete screens: home/setup, quiz top bar, answer input, results/feedback, settings & sign-in, audio controls — per app, then cross-app synthesis.
**Method:** Web-sourced (App Store/Play listings, official blogs, teardown articles, UX case studies, reviews, forum evidence). Every claim cited; screenshot-derived or dated claims flagged inline.

**Apps:** Trivia Crack (1+2) · Kahoot! (mobile) · Duolingo · Sporcle (mobile) · Drive.fm/Drivetime · CarTrivia · VoicePlay Trivia · HQ Trivia (legacy reference)

---

## Duolingo

*The reference app for audio-exercise affordances (replay, slow-replay, "can't listen now") and per-question feedback. Strongest-sourced section in this doc — the audio controls trace to an official, dated (Jan 2026) Duolingo accessibility post.*

### 1. Home screen

- Duolingo replaced its old branching "skill tree" with a single-file, winding **path** of circular lesson nodes completed in fixed order — "The home screen is now designed as a path that you'll follow step by step" ([Duolingo blog, May 2022](https://blog.duolingo.com/new-duolingo-home-screen-design/)). The path is broken into **units** with descriptive header banners (e.g. "get directions") rather than generic skill names (same source).
- There is **no category/difficulty picker on the home screen** — the path is auto-sequenced. On-demand topic/skill selection lives in a separate **Practice Hub** where users target specific exercise types (e.g. "Listen") ([Duolingo Practice Hub guide](https://blog.duolingo.com/guide-to-duolingo-practice-hub/); [duoplanet.com](https://duoplanet.com/duolingo-practice-hub/)).
- Persistent top-of-screen status icons: **flame/streak counter** (top-left), **gems** currency, **hearts** (lives) ([TechWiser icon guide](https://techwiser.com/all-duolingo-icons-and-symbols-meaning-including-status-icons/)). Lessons requiring listening are flagged on the path with a **headphone icon** ([TechWiser](https://techwiser.com/all-duolingo-icons-and-symbols-meaning-including-status-icons/); [DuoRadio post](https://blog.duolingo.com/duoradio-listening-practice/)).
- Primary action = tapping the next active path node; no separate "start" CTA (inferred from path-node descriptions; not independently screenshot-verified).
- *Evidence note:* the redesign post is from 2022; visuals may have iterated, but the node/path/unit structure is corroborated by later secondary sources ([Medium/Bootcamp gamification piece](https://medium.com/design-bootcamp/duolingo-the-product-that-gamified-learning-and-made-it-addictive-6733f2b56307)).

### 2. Lesson screen top bar

- A **thin progress bar spans the top** and fills green left-to-right as the learner answers correctly: "The grey line at the top of the screen is a progress bar, as a splash of green appears on the left-hand side" ([Usability Geek case study, 2017](https://usabilitygeek.com/ux-case-study-duolingo/) — old but this is a long-stable mechanic, still assumed current by 2025 sources).
- A **heart icon sits top-right** showing remaining lives for the session ([Usability Geek](https://usabilitygeek.com/ux-case-study-duolingo/); [TechWiser](https://techwiser.com/all-duolingo-icons-and-symbols-meaning-including-status-icons/)).
- A **close/X** control to exit the lesson sits in the top bar — widely referenced in community content but its exact corner is weakly sourced in this pass; treat "top-left X" as commonly-known, not verified.
- **Streak count and XP are NOT in the in-lesson top bar** — they surface only at lesson end (no source places them in-lesson; end-of-lesson sources below show them post-lesson). The in-exercise bar is deliberately minimal: progress + lives + exit.

### 3. Answer input

- Many exercise types (per the [Duolingo Fandom exercise catalog](https://duolingo.fandom.com/wiki/Exercise) and [duolingoguides.com](https://duolingoguides.com/duolingo-listening-skills-improvement/)): translation (typed), **type what you hear**, **multiple choice** ("What do you hear?" — audio plays, pick the transcription), **tap the pairs**, **arrange the words** (word-bank tiles), fill-in-the-blank, speaking (read aloud into mic).
- Selection is **two-step: pick, then confirm with a "Check" button** — "When I select my answer and tap the 'Check' button, I am rewarded with a cheerful 'ding'" ([Usability Geek, 2017](https://usabilitygeek.com/ux-case-study-duolingo/); manual-confirm still assumed current by a [2025 UX critique](https://jackbellis.medium.com/user-interface-improvements-to-duo-lingo-06bf125fad49)).
- DuoRadio word-selection UI: "a blue speaker button and audio wave and a list of 5 Spanish word tiles," prompt "Select 3 words that you hear" ([Duolingo blog](https://blog.duolingo.com/duoradio-listening-practice/)).

### 4. Results / feedback

- **Per-question feedback, immediately:** correct → "ding" + green "you are correct" banner ([Usability Geek](https://usabilitygeek.com/ux-case-study-duolingo/)); incorrect → **red pop-up/banner at the bottom of the screen** showing the correct answer, with a flag-an-error affordance and a discussion/"speech bubble" button ([Medium — "Decoding Duolingo", Nov 2023](https://medium.com/@flordaniele/decoding-duolingo-a-case-study-on-the-impact-of-gamification-on-user-experience-90b5bac3ada0)).
- Advancement after feedback is **manual, not auto-advance** — a March 2025 UX critique explicitly proposes *adding* auto-advance, implying shipped behavior requires tapping "Continue" ([jackbellis.medium.com, Mar 2025](https://jackbellis.medium.com/user-interface-improvements-to-duo-lingo-06bf125fad49)).
- **End-of-lesson summary:** XP earned (10 XP regular lesson, 20 for last-in-skill) ([duoplanet XP guide](https://duoplanet.com/duolingo-xp-guide/)); on the first lesson of the day, a **separate full-screen streak-increment screen** with animated flame and counter tick-up, with bigger celebrations reserved for milestones (day 50 vs. plain day 47) ([duoplanet](https://duoplanet.com/duolingo-score/); [Deconstructor of Fun streaks teardown](https://duolingo.deconstructoroffun.com/mechanics/streaks)). Key pattern: **streak is celebrated once per day at session end — it is not a per-question element.**

### 5. Settings & sign-in

- **First launch:** two choices — "Get Started" (new user) vs. "I Already Have An Account" ([lingoly.io login guide, Jan 2026](https://lingoly.io/duolingo-login/)). New users pick a language and do a placement flow first; account creation ("Create A Profile", age/name/email/password) is **deferred until after the first lesson/streak** — play first, profile second ([lingoly.io](https://lingoly.io/duolingo-login/); the deferred-signup pattern noted as far back as the [2017 Usability Geek study](https://usabilitygeek.com/ux-case-study-duolingo/)). Social sign-in (Google/Facebook) is offered ([lingoly.io](https://lingoly.io/duolingo-login/)).
- **Settings path:** profile icon → **gear icon top-right** ([Duolingo hearing-aids post, Jan 2026](https://blog.duolingo.com/learning-with-hearing-aids/)). Sections include Account, Notifications, Preferences and a lesson-experience grouping containing the **"Listening exercises" toggle** — "tap the switch next to 'Listening exercises' to turn them off" (same official source).
- **Sound toggles** ("Sound effects", music) live in the same settings screen's sound section ([duolingoguides.com](https://duolingoguides.com/how-to-turn-off-sound-effects-on-duolingo/)).

### 6. Audio controls — the reference pattern set

All verbatim from Duolingo's official accessibility post ([blog.duolingo.com/learning-with-hearing-aids, Jan 2026](https://blog.duolingo.com/learning-with-hearing-aids/)) unless noted:

- **Play/replay:** a **blue speaker button** plays the audio; tappable repeatedly to replay as many times as needed ([Duolingo listening-skills post](https://blog.duolingo.com/covering-all-the-bases-duolingos-approach-to-listening-skills/); [duolingoguides](https://duolingoguides.com/duolingo-listening-skills-improvement/)).
- **Turtle / slow replay:** a distinct turtle-icon button next to the speaker — "Still not sure? Tap the turtle button and hear the sentence again more slowly, with pauses between words." One secondary source says the turtle appears only after the first full-speed playback ([duolingoguides](https://duolingoguides.com/duolingo-listening-skills-improvement/) — unofficial, lower confidence).
- **"Can't listen now" — the type-instead/skip fallback:** an **inline tappable link/button under the listening exercise** (not a settings toggle, not a timed cooldown): "Tap 'Can't listen now' and skip all listening exercises for that lesson." Scope is **the current lesson only**. Duolingo frames it explicitly around situational inability ("if it's 11:58 p.m. and you're trying to save your streak"). Community threads corroborate existence and user appreciation: ["Thanks for the Can't Listen Now button"](https://duolingo.hobune.stream/comment/34036301/Thanks-for-the-Can-t-Listen-Now-button), ["Can't Listen Now"](https://duolingo.hobune.stream/comment/40665451/Can-t-Listen-Now) (forum-archive mirrors; JS-rendered pages — existence-corroborating only).
- **Permanent opt-out:** durable Settings toggle ("Listening exercises" off; "You can always turn them on again later!") — a *separate* mechanism from the inline per-lesson skip. Speaking exercises have an equivalent toggle ([hardreset.info](https://www.hardreset.info/devices/apps/apps-duolingo/disable-listening-exercises/)).
- **DuoRadio bypass:** audio-only episodes offer "Do this later" rather than blocking progress ([hearing-aids post](https://blog.duolingo.com/learning-with-hearing-aids/)).
- **The three-layer takeaway:** Duolingo handles "user can't do audio right now" at three distinct scopes — per-exercise (replay/turtle), per-lesson ("Can't listen now"), and global (Settings toggle) — each surfaced where the need arises, not buried.

---

## Sporcle (mobile)

*Evidence caveat up front: Sporcle's native-app UI is thinly documented — most public write-ups describe sporcle.com, several official support pages 403'd automated fetch, and no design gallery indexes the app. Claims below are lower-confidence than the Duolingo section; website-sourced claims applied to the app by inference are flagged.*

### 1. Home screen

- Category-browsing home: "hundreds of categories" (sports, movies, geography, music…) and multiple **quiz formats** — "maps, multiple choice, crosswords, clickable, fill in the blank, and more" ([App Store listing](https://apps.apple.com/us/app/sporcle/id1572007006); [Google Play](https://play.google.com/store/apps/details?id=com.sporcle.geneva&hl=en_US); [sporcle.com/apps](https://www.sporcle.com/apps/)). Solo, vs-friends, and live-multiplayer modes are selectable from the home area ([App Store listing](https://apps.apple.com/us/app/sporcle/id1572007006)).
- Concrete visual layout (grid vs. list, search-bar placement) — **evidence gap**; no screenshot-level source found.

### 2. Quiz screen top bar

- Default: a **countdown timer** plus an answer counter. A **gear icon next to the timer** (pre-start) switches it to **"Stopwatch" mode** counting up — which disqualifies the play from official challenges ([Sporcle blog, 2016](https://www.sporcle.com/blog/2016/11/stopwatch-on-sporcle/)).
- A newer "Quiz Play Enhancements" support article describes "a real-time progress indicator that shows the number of answers entered and percentage complete, alongside a visible timer counting down" ([support.sporcle.com — Quiz Play Enhancements](https://support.sporcle.com/hc/en-us/articles/36975920240269-Quiz-Play-Enhancements); search-snippet synthesis, page 403'd direct fetch).
- No source shows a streak counter, XP, or Duolingo-style X button in the quiz screen. Most Sporcle quizzes are **one continuous timed sheet of blanks**, not single-question-per-screen, so a per-question top bar largely doesn't apply — unconfirmed at screenshot level.

### 3. Answer input

- Official formats: **Classic** (type answers), **Clickable**, **Multiple Choice**, Grid, Map, Order, Picture Click, Slideshow ([support.sporcle.com — quiz types](https://support.sporcle.com/hc/en-us/articles/33897795822989-Understanding-different-quiz-types-and-formats); search-snippet synthesis, 403'd).
- Classic typed format: "as soon as you type the right answer, it pops into the right spot" — persistent keyboard field, correct answers auto-populate in real time, **no per-item submit step** ([Google Play listing](https://play.google.com/store/apps/details?id=com.sporcle.geneva&hl=en_US), search synthesis).
- Typed input has known mobile friction: "Answer input via keyboard has occasional input lag or duplication issues, which can disrupt timed quizzes" ([appviewable.com review, May 2026](https://appviewable.com/apps/app-sporcle/)); "Typing in longer answers is sometimes difficult with the iPhone's smaller keyboard" ([Common Sense Media, 2020](https://www.commonsensemedia.org/app-reviews/sporcle)). A 2024-era review notes a shift toward "heavy reliance on multiple choice format" away from typing ([sporcle.com multiple-choice type page, via search synthesis](https://www.sporcle.com/type/multiplechoice)).

### 4. Results / feedback

- **End-of-quiz, not per-question:** "The overall score is displayed as both a numerical total and a percentage of completion at the end of the quiz or upon timer expiration," with personal best and friends' scores below ([support.sporcle.com — track results](https://support.sporcle.com/hc/en-us/articles/34071500816141-How-do-I-track-my-quiz-results), search synthesis; [Hidden Features blog, 2018](https://www.sporcle.com/blog/2018/06/hidden-features-of-sporcle/)). **Best score lives on the end screen / quiz page — not shown per-question.**
- A "snark" message (witty result-dependent one-liner) appends to the end screen; toggleable under Settings → Gameplay **on the website** — mobile parity unconfirmed ([Hidden Features blog](https://www.sporcle.com/blog/2018/06/hidden-features-of-sporcle/)).
- No auto-advance/manual-continue distinction exists for the dominant one-sheet format; per-screen MCQ advance behavior unconfirmed.

### 5. Settings & sign-in

- **Sign-in is optional, not gated:** "Players can choose to create an account to track their games played and scores" ([Common Sense Media, 2020](https://www.commonsensemedia.org/app-reviews/sporcle)); listings frame login value as stats/badges/playlists/streaks, not access ([App Store listing](https://apps.apple.com/us/app/sporcle/id1572007006)). Guest-by-default model implied; literal first-launch screen not evidenced.
- Premium tier removes ads/unlocks stats — pricing reported inconsistently ("Sporcle Orange" $5.99/mo–$59.99/yr per App-Store-derived data vs. "Sporcle Plus" $3.99/mo–$29.99/yr per a 2026 review) — **unresolved conflict, flagged not averaged** ([App Store](https://apps.apple.com/us/app/sporcle/id1572007006) vs. [appviewable.com](https://appviewable.com/apps/app-sporcle/)). Ads described as intrusive post-game ([appviewable.com, 2026](https://appviewable.com/apps/app-sporcle/)).
- **No source documents a sound/mute toggle location in the app** — evidence gap; community threads ("Can't disable showdown sounds" — [sporcle groups](https://www.sporcle.com/groups/topics/763643a1d0f7)) suggest at least some sound categories have **no** user-facing toggle.

### 6. Audio controls

- Thin by nature — Sporcle is not audio-first. Some quizzes embed audio as *content* (mystery songs, SoundCloud clips), evidenced via bug-report threads ([groups thread 1](https://www.sporcle.com/groups/topics/7684d1b98c77), [thread 2](https://www.sporcle.com/groups/topics/767005029c5d)). No replay/skip affordance documented; audio is quiz *topic*, never the exclusive channel for receiving a question, so no "can't listen" bypass exists or is needed.

---

## Trivia Crack (Etermax)

*Evidence tiers used: text sources (support docs/reviews; several official help-center pages cited "via search index" where the domain blocks fetchers), current store marketing screenshots inspected 2026-07-03 ([Google Play listing](https://play.google.com/store/apps/details?id=com.etermax.preguntados.lite); [App Store, v3.376.0, 2026-06-30](https://apps.apple.com/us/app/trivia-crack/id651510680)), and flagged inferences. **Trivia Crack 2 appears gone from the US App Store** (iTunes Lookup of its former ID returns zero results, 2026-07-03); its mechanics are folded back into the flagship. TC2-era claims below are labeled.*

### 1. Home screen & game setup

- **Match flow:** "New game" → game mode (Classic vs Challenge) + opponent (Friends vs Random) → "Play now"; random matchmaking auto-starts ([GameFAQs FAQ, via search index](https://gamefaqs.gamespot.com/android/205239-trivia-crack/faqs/74422); [triviacrack.com/challengers](https://triviacrack.com/challengers)).
- **Top resource bar on home:** avatar top-left; counters for **hearts (lives), spins, diamonds, coins** across the top ([etermax support, via search index](https://triviacrack.help.etermax.com/hc/en-us/articles/360024644573-How-do-I-add-a-profile-picture); [GameFAQs](https://gamefaqs.gamespot.com/android/205239-trivia-crack/faqs/74422)). Hearts gate starting games.
- **Spin wheel (category selection is randomized, not picked):** per current Play screenshot #0 (2026-07-03): both players' avatars top corners with a large **"3 vs 5" score** between them; below, a **3-segment arced crown-meter**; then a huge **7-segment wheel** filling the lower half with a white circular **"SPIN"** hub. 7 segments = 6 categories + a Crown segment ([Android Police TC2 hands-on, 2018 — dated](https://www.androidpolice.com/2018/10/16/trivia-crack-2-hands-prettier-package/); [148Apps review](https://www.148apps.com/reviews/trivia-crack-review/); [Trivia Bliss](https://triviabliss.com/trivia-crack-categories/)). Spins currency lets you re-spin an unwanted category ([tipsandtricksfor.com, via search index](https://tipsandtricksfor.com/trivia-crack-tips-and-hints-guide/)).
- **Category characters** (Science/green test tube, Geography/blue globe, Entertainment/pink popcorn, History/yellow knight, Art/red paintbrush, Sports/orange football, + purple Crown) — triangulated across [Wikipedia](https://en.wikipedia.org/wiki/Trivia_Crack) and [Trivia Bliss](https://triviabliss.com/trivia-crack-character-names/), icon set confirmed in the current screenshots.
- **The current app is a multi-mode hub** (Play screenshots, 2026-07-03): a **Topics** screen of photo card tiles (Jazz, NFL, Zombies…) each with a white "Play" pill; a **"Live Trivia"** mode with host video bubble + "Join Game" + QR icon; a TikTok-style **swipe true/false mode**; a fun-park builder meta-game; a **5-tab bottom bar** (home, trophy, build, shop, profile). Marketing shots — may idealize.
- Async turn-based: unlimited simultaneous matches; a turn ends and returns you home ([AppleVis, via search index](https://www.applevis.com/comment/36717)). The ongoing-games list UI itself: **not evidenced** — gap.

### 2. Question-screen top bar

- **Hard timer:** originally 30 s, cut to **20 s**; no answer = wrong ([AppleVis "Reduced Timer" thread, via search index](https://www.applevis.com/forum/ios-ipados-gaming/reduced-timer-trivia-crack); [player forum on the 30→20 s change](http://gamersunite.coolchaser.com/topics/187175-trivia-crack-timer-shortened-to-20-seconds-from-30-why)). The "Extra Time" power-up (+15 s) is offered **at the moment time expires** ([Trivia Bliss power-ups](https://triviabliss.com/everything-about-power-ups-in-trivia-crack/)).
- **Timer visual form: unverified for classic mode** — no text source states ring vs bar vs digits; the Live Trivia screenshot (#9, 2026-07-03) shows a **horizontal progress bar near the bottom** of the question screen (inferred from one undated marketing shot).
- Opponents' crown tallies are reachable by swipe, not persistently shown ([AppleVis, via search index](https://www.applevis.com/forum/ios-ipados-gaming/question-about-reading-player-scores-trivia-crack)). No literal "3/10" question-counter widget evidenced.

### 3. Answer input

- **4 options, one correct** ([triviacrackanswers.org, via search index](https://triviacrackanswers.org/)). **Layout: vertical stack of 4 full-width rounded pill buttons** under the question; correct/selected pill fills green (current screenshots #1/#9, 2026-07-03 — Live mode; classic-mode layout very likely identical but not directly evidenced — flagged).
- **Tap = commit, no confirm step;** the correct answer is pre-downloaded so feedback is instant ([Medium teardown of the TC API, via search index](https://medium.com/@kylestev/cracking-trivia-crack-30476f9bfca4)).
- **Power-ups at the bottom of the question screen** ([Trivia Bliss](https://triviabliss.com/everything-about-power-ups-in-trivia-crack/); [etermax support, via search index](https://triviacrack.help.etermax.com/hc/en-us/articles/360024775733-Power-ups)): Double Chance, Bomb (removes 2 wrong options), Extra Time, Right Answer.

### 4. Results / feedback

- **Per-question:** immediate binary correct/incorrect; correct fills the crown meter 1/3 and grants another spin; incorrect ends your turn ([Trivia Bliss](https://triviabliss.com/trivia-crack-win/)). **No explanation/fun-fact panel evidenced** (absence-of-mention, flagged).
- Crown loop: 3 corrects → win/steal a character via a category question or a 5–6 question gauntlet — sources differ 5 ([148Apps](https://www.148apps.com/reviews/trivia-crack-review/)) vs 6 ([HubPages, via search index](https://discover.hubpages.com/games-hobbies/Trivia-Crack-Review)); unresolved, flagged.
- Win = all 6 crowns; ~25-round cap then most-crowns/tiebreak ([HubPages, via search index](https://discover.hubpages.com/games-hobbies/Trivia-Crack-Review)). Cumulative stats live in a profile/Rankings area, not per-question ([Corona Insights, via search index](https://www.coronainsights.com/2015/05/measuring-trivia-crack-scores-the-fourth-in-a-series-of-posts-analyzing-trivia-crack/)). **No streak mechanic and no best-score display per question found.**
- Auto-advance vs manual: **unresolved**; post-answer question rating/reporting exists ([AppleVis, via search index](https://www.applevis.com/apps/ios/games/trivia-crack)), implying an interactive interstitial.

### 5. Settings & sign-in

- **Hard login gate at launch — no guest mode:** email/Facebook (also Apple and Google per [playbite.com, via search index](https://www.playbite.com/q/can-you-play-trivia-crack-without-facebook)) required before playing ([etermax support, via search index](https://triviacrack.help.etermax.com/hc/en-us/articles/360024644853-How-do-I-create-a-new-account); "requires an email address or Facebook integration to play" — [Common Sense Media](https://www.commonsensemedia.org/app-reviews/trivia-crack)). The outlier of the whole set.
- **Settings:** avatar → Menu → Settings (TC2: gear top-right of home — [TC2 support, via search index](https://triviacrack2.help.etermax.com/hc/en-001/articles/360051583334-What-can-I-find-in-Settings)). Contents: **Sound, Music, Vibration** toggles, notification sound, email updates, "questions with images" on/off, Facebook privacy toggles ([etermax preferences, via search index](https://triviacrack.help.etermax.com/hc/en-us/articles/1500002715002-How-do-I-change-my-preferences)).

### 6. Audio

- **No native read-aloud.** Question audio exists only via OS screen readers (VoiceOver/TalkBack), which the app supports ([etermax accessibility, via search index](https://triviacrack.help.etermax.com/hc/en-us/articles/43425976776851-Accessibility-in-the-game)); blind users report focus loss and that the 20 s timer punishes screen-reader use ([AppleVis](https://www.applevis.com/forum/ios-ipados-gaming/reduced-timer-trivia-crack)).
- Sound/Music are Settings toggles only; **no in-question mute icon found** (unverified/likely absent). **Zero voice affordances in either direction.**

---

## Kahoot! (mobile)

*Sources: official support docs (several via search index where the help center blocks fetchers), kahoot.com blog posts, and current App Store screenshots (v6.7.1, updated 2026-06-23, inspected 2026-07-03 — [listing](https://apps.apple.com/us/app/kahoot-play-create-quizzes/id1131203560)).*

### 1. Home screen & join flow

- **Player join = 6-digit PIN → nickname, nothing else** ([support join article, via search index](https://support.kahoot.com/hc/en-us/articles/360039890713-Kahoot-join-How-to-join-a-Kahoot-game); [kahoot.it](https://kahoot.it/) is a single "Game PIN" field). Built-in **nickname generator** (spin for a random name, 3 tries) ([kahoot.com blog, 2017](https://kahoot.com/blog/2017/11/09/generate-funny-nicknames-players-live-kahoots/)).
- **Players make no category/difficulty/language choices** — all content decisions are host-side (omission across join docs; [Common Sense Media](https://www.commonsensemedia.org/app-reviews/kahoot-play-create-quizzes)).
- The app is a **two-persona shell** with a **5-tab bottom bar — Home, Discover, Join (center tab), Create, Library** (App Store screenshots, 2026-07-03). Discover has a search bar with a globe/EN **language selector**, partner collections, and quiz cards showing **question counts**. Host-side: templates, public question bank, Classic vs Team mode plus newer "experiences" ([support — experiences](https://support.kahoot.com/hc/en-us/articles/35636870654867-Kahoot-experiences)), self-paced "Challenges" ([kahoot.com blog](https://kahoot.com/blog/2020/02/06/what-is-student-paced-challenge/)).

### 2. Question-screen top bar

- **Key split: in live Classic mode the question + answer TEXT live on the shared/host screen; the player's phone shows only colored shape buttons.** A setting ("Show questions & answers on participants' devices") exists precisely to change that default ([support, via search index](https://support.kahoot.com/hc/en-us/articles/115003197928-How-to-enable-See-questions-on-participant-s-screen-in-Kahoot-live-games); [kahoot.com single-screen blog, 2022](https://kahoot.com/blog/2022/08/08/tech-tip-single-screen/); [instruction.uh.edu, via search index](https://www.instruction.uh.edu/knowledgebase/how-to-play-kahoot-in-class/)).
- **Host-screen timer** is "always visible… on the left side of the host's screen" ([support Live-game-settings, via search index](https://support.kahoot.com/hc/en-us/articles/115016055107-Live-game-settings)); its glyph (circular badge with numeral) is widely seen but **not text-cited — inferred**. Reading time is **dynamic** (min 5 s, scaled to question length) ([Inside Kahoot!, Medium](https://medium.com/inside-kahoot/kahoot-dynamic-question-times-1ef1facead4e)).
- **On-device (self-paced/solo) quiz screen** per current App Store screenshots (2026-07-03): a small **"Quiz" pill label top-center**, question on a white card mid-screen, answers below, a **horizontal timer bar across the bottom with a numeric seconds counter at its right end**, and a **bottom status bar: player nickname (left) + running score in a dark chip (right)**. Marketing shots — may idealize.
- Timer settable 5 s–4 min per question; can be **off entirely** in self-paced Challenges ([support question types](https://support.kahoot.com/hc/en-us/articles/115002308428-Kahoot-question-types)). A "Question X of Y" counter is **unverified**.

### 3. Answer input — the 4 colored shapes

- **2x2 grid of large color+shape buttons:** red/triangle top-left, blue/diamond top-right, yellow/circle bottom-left, green/square bottom-right — confirmed both from a reverse-engineered client script ([GitHub gist](https://gist.github.com/wlib/bfb90b1c7d243780aac708160d83b808)) and first-hand in the current App Store screenshot (2026-07-03).
- Shapes-not-letters is a **deliberate accessibility choice** (colorblind/low-vision) ([kahoot.com/accessibility](https://kahoot.com/accessibility/)). The color+shape scheme decouples the button from answer text — effectively "answer by position/color," a useful analogue for voice answering by letter.
- **Single tap = locked submission, no undo** — inferred from a user feature request to allow changing answers ([support community post](https://support.kahoot.com/hc/en-us/community/posts/115001072948-Let-players-change-answer-before-time-is-over)); flagged as inferred.
- Other input types ([support](https://support.kahoot.com/hc/en-us/articles/115002308428-Kahoot-question-types)): True/False; **Puzzle** (drag-to-order, the one type with an explicit **Submit** button — current screenshot); **Type answer** (free text ≤20 chars, up to 4 accepted spellings, paid tier); Slider; Poll; Word cloud; a **"Quiz + Audio"** question type visible in the current creator sheet (screenshot, 2026-07-03).

### 4. Results / feedback

- **Player-device per-question feedback:** an animated sequence — base points → speed bonus → new total, **alongside streak and rank**, deliberately tuned so players "see their points, streak and rank more quickly" ([Inside Kahoot! product-design post](https://medium.com/inside-kahoot/developing-new-game-mechanics-at-kahoot-be7ddb52f6df)). The **Answer Streak** is a within-game consecutive-corrects counter with "a snappy Answer Streak animation" on the player's device; broken streaks reset ([Inside Kahoot! answer-streaks post](https://medium.com/inside-kahoot/experimenting-with-answer-streaks-to-help-make-learning-awesome-3b3357e42595)). Note: this is a **within-session answer streak — not a daily streak and not a best score.**
- Scoring: speed-scaled to 1000 points ([support How-points-work, via search index](https://support.kahoot.com/hc/en-us/articles/115002303908-How-points-work)); Accuracy mode removes the speed bonus ([support](https://support.kahoot.com/hc/en-us/articles/39818967108627-Accuracy-experience-How-to-host-a-kahoot)); Confidence mode adds flame-icon confidence streaks ([support](https://support.kahoot.com/hc/en-us/articles/32200674639261-Confidence-experience-How-to-host-a-kahoot)).
- **Between-question leaderboard:** top-5 scoreboard on the **host screen** after every question, shown ~5 s; players below 5th see only their own score ([support community thread, via search index](https://support.kahoot.com/hc/en-us/community/posts/115001072628-Option-to-show-hide-leaderboards-between-questions)).
- **Advance control:** host taps **Next**, or an optional "Automatically move through questions" setting auto-advances after the 5 s leaderboard ([support playbook, via search index](https://support.kahoot.com/hc/en-us/articles/42321615442707); [presentation hosting](https://support.kahoot.com/hc/en-us/articles/33774933800595-Presentation-the-interactive-presentation-tool-for-hosting)) — i.e. **both modes exist, host-chosen**.
- **End-of-game podium:** top-3 (1st center, 2nd left, 3rd right) with confetti; automatic in Classic ([support community, via search index](https://support.kahoot.com/hc/en-us/community/posts/40636423376147-Podium-Celebration); [launch post, 2016](https://kahoot.com/blog/2016/09/06/kahoot-podium-rewarding-top-3-players/)); visible in the current App Store screenshot (2026-07-03).

### 5. Settings & sign-in

- **Players: guest by default** — nickname only, no account ([support join article, via search index](https://support.kahoot.com/hc/en-us/articles/360039890713-Kahoot-join-How-to-join-a-Kahoot-game)). **Hosts: account required** — email or Google/Microsoft/Apple/Clever SSO ([support login, via search index](https://support.kahoot.com/hc/en-us/articles/11064559523731-How-to-log-in-to-your-Kahoot-account)).
- Settings: notifications under Profile → Privacy; subscription under Profile → "Manage Subscription" ([support](https://support.kahoot.com/hc/en-us/articles/360040719294-How-to-update-Kahoot-notification-settings), [mobile subscription](https://support.kahoot.com/hc/en-us/articles/360011673594-How-to-manage-my-mobile-subscription), via search index).
- **Sound toggle: top-right of the host screen during a live game**; deeper audio settings behind the gear icon bottom-right of the host screen ([support community sound threads + Live-game-settings, via search index](https://support.kahoot.com/hc/en-us/articles/115016055107-Live-game-settings)).

### 6. Audio — Kahoot's read-aloud is the key prior art

- **Native question read-aloud exists.** "Read Aloud" launched 2021-05-05 in the mobile app for Study mode and self-paced Challenges: the app "first reads aloud the question and then switches to the screen with answer alternatives and reads them aloud," **visually highlighting each option as it is spoken**; triggered by a **read-aloud icon in the top-right corner** once gameplay starts; Microsoft Azure TTS, 37 languages, free on all plans ([kahoot.com blog announcement](https://kahoot.com/blog/2021/05/05/read-aloud-game-option-kahoot-app/); now listed under [trust.kahoot.com AI features](https://trust.kahoot.com/ai-powered-features-in-kahoot/)). **Scope caveat:** documented for on-device/self-paced play, not the live shared-screen mode. The question-then-options sequencing with highlight-as-spoken is directly relevant prior art for a hands-free flow.
- Signature soundtrack: lobby music (host-selectable with preview), countdown tension track, correct/incorrect stingers ([kahoot.fandom.com Soundtracks wiki, via search index](https://kahoot.fandom.com/wiki/Soundtracks) — page itself 402'd direct fetch). Global sound on/off per live game via host settings, persists across games ([support community, via search index](https://support.kahoot.com/hc/en-us/community/posts/360035202773-Option-to-toggle-Kahoot-sound-off-on)).
- **No voice input found in any source.**

---

## Drive.fm / Drivetime (voice driving trivia — the direct-competitor benchmark)

*Availability caveat first: the app appears **delisted as of 2026-07-03** — iTunes Lookup of its App Store ID 1357342274 returns zero results across US/CA/GB/AU/DE; the Play URL 404s; founder pivoted to Web3 in Nov 2022 ([LinkedIn](https://il.linkedin.com/posts/nikovuori_drivetime-pivots-to-blockstars-with-web3-activity-6994700924271153152-uMg2)), though drive.fm was archived live as late as April 2025 ([Wayback](https://web.archive.org/web/20250419011410/https://drive.fm/)). Everything below is reconstructed from 2018–2020 press/reviews and cached listing text — not an installable app.*

### 1. Home screen / setup

- **Not fully hands-free at launch:** "it's billed as hands-free, but it's not completely true as you of course still have to press play to start a game" ([roadtripsforfamilies.com hands-on, Aug 2020](https://www.roadtripsforfamilies.com/the-drivetime-app-eliminates-car-time-boredom/)); "Once you've opened the app and pressed play, you don't have to look at or touch the screen again" ([Yahoo Finance, via search snippet](https://finance.yahoo.com/news/drivetime-trivia-app-turns-daily-220713821.html)).
- Home = a **channel lineup** (Jeopardy! launched as "the eighth channel" — [PR Newswire, 2019](https://www.prnewswire.com/news-releases/drivetime-launches-jeopardy-on-drivetime-announces-11m-series-a-funding-led-by-makers-fund-with-participation-from-amazons-alexa-fund-and-google-300913535.html)); trivia across 7 categories plus modes (TuneTime, Superfan Showdown, Would You Rather) ([cached App Store listing text](https://apps.apple.com/us/app/drivetime/id1357342274); [cafebazaar mirror](https://cafebazaar.ir/app/fm.drivetime.original?l=en)). Category/mode selection voice-driven once in-app ([cafebazaar mirror](https://cafebazaar.ir/app/fm.drivetime.original?l=en)). No home-screen screenshot survives — structure inferred from press text.

### 2. In-round screen

- **Not blank/audio-only** — a reviewer criticized on-screen "MOTION DRAWS ATTENTION" during play ([Product Hunt](https://www.producthunt.com/products/drivetime)). Rounds: "three trivia segments of about 10 minutes each," 7-question segments ([Voicebot.ai, 2018](https://voicebot.ai/2018/11/10/drivetime-closes-4-million-seed-round-launches-voice-trivia-game-for-commuters/)).
- Standing/progress delivered **audibly by a synthetic narrator** ("Miles… indicates whether you're winning, losing or in a tie" — [thecorporatecounsel.net, 2019](https://www.thecorporatecounsel.net/blog/2019/03/cool-stuff-drivetime-for-when-youre-commuting.html)); human hosts read content, synthetic voice reads game stats between questions ([Voicebot.ai, 2019](https://voicebot.ai/2019/09/09/drivetime-closes-11-million-series-a-round-with-investment-from-makers-fund-amazons-alexa-fund-and-google/)).
- No mid-round voice mode-switching ([roadtripsforfamilies.com](https://www.roadtripsforfamilies.com/the-drivetime-app-eliminates-car-time-boredom/)). **No native CarPlay template** — the only data point is negative ("doesn't work as harmoniously with Apple CarPlay as you would hope" — [AppGrooves review summary, via search snippet](https://appgrooves.com/app/drivetime-by-drivetime-inc-1)); it ran as background audio. No screenshot-level evidence of question card/timer/progress visuals survives — gap.

### 3. Answer input

- **Shouted/spoken answers via the phone mic; anyone in the car can play** ([roadtripsforfamilies.com](https://www.roadtripsforfamilies.com/the-drivetime-app-eliminates-car-time-boredom/)). Options read aloud, answered by letter: "responding vocally with answers like 'A, B or C'" ([Product Hunt](https://www.producthunt.com/products/drivetime)). Mostly MCQ with occasional open-ended ([thecorporatecounsel.net](https://www.thecorporatecounsel.net/blog/2019/03/cool-stuff-drivetime-for-when-youre-commuting.html)).
- Recognition reported unreliable in practice ("even when users say the correct answer, it will hear something else" — [AppGrooves](https://appgrooves.com/app/drivetime-by-drivetime-inc-1)), contradicting the listing's "near 100% accuracy" claim. **No "type instead" fallback confirmed or denied** — gap.

### 4. Results / feedback

- In-round standing spoken by narrator; difficulty-weighted points ([thecorporatecounsel.net](https://www.thecorporatecounsel.net/blog/2019/03/cool-stuff-drivetime-for-when-youre-commuting.html)). **Leaderboards** vs all players or contacts ([Voicebot.ai, 2018](https://voicebot.ai/2018/11/10/drivetime-closes-4-million-seed-round-launches-voice-trivia-game-for-commuters/)); Jeopardy! mode had post-round rankings + fun facts ([Jeopardy.com](https://www.jeopardy.com/jbuzz/news-events/play-jeopardy-hands-free-car)). No end-of-round summary-screen layout or streak mechanic evidenced.

### 5. Settings & sign-in

- Opponent choice (random commuter vs friends) configured in settings ([Yahoo Finance](https://finance.yahoo.com/news/drivetime-trivia-app-turns-daily-220713821.html)). Monetization: free daily tier + subscription (free 2018 → $9.99/mo 2019 ([TechCrunch](https://techcrunch.com/2019/09/09/drivetime-nabs-11m-from-makers-fund-amazon-and-google-to-build-voice-based-games-for-drivers/)) → $4.99/mo later ([cached listing](https://apps.apple.com/us/app/drivetime/id1357342274))) — **no login-gate evidence**; sign-in/account screen undocumented — gap.

### 6. Audio controls

- Designed to run **backgrounded behind a map app** ([Product Hunt](https://www.producthunt.com/products/drivetime)). **Thinnest dimension: no surviving source documents a repeat/replay command, mute toggle, voice on/off, or read-options toggle.** Options-read-aloud appears to be default behavior, not a setting.

---

## CarTrivia (Good Question Labs) — the only active direct competitor

*Best-documented voice competitor: live App Store listing (ID 6757024865, released 2026-03-06, v1.1.1070 of 2026-05-18, $2.99 paid + credit IAPs, iOS 15.1+, English only — [iTunes Lookup, fetched 2026-07-03](https://apps.apple.com/us/app/car-trivia-any-topic/id6757024865)); four actual app screenshots inspected first-hand on [cartrivia.app](https://cartrivia.app/) (2026-07-03; marketing shots, may not exactly match the shipping build). **No Google Play listing exists** despite the site's Android Auto claim — likely audio-over-Bluetooth, not an Android app.*

### 1. Home screen / setup

- **Tab-bar app: Home, Settings, History, Account, Store** (screenshot 4, [cartrivia.app](https://cartrivia.app/images/screenshots/screen-4.png), 2026-07-03).
- **Round setup = typed-topic screen:** a "TOPIC" card ("Type any trivia topic and start the round…"), free-text field with a **150-char counter** ("Longer topics will be summarized automatically"), a large cyan **"Start Round"** button, and a footer pointing to a **"Pick from menu"** curated-topics screen one step back (screenshots 1–3, [cartrivia.app](https://cartrivia.app/images/screenshots/screen-1.png), 2026-07-03). **Topic selection is typed/tapped, not spoken.**
- Launch can be hands-free via Siri ("Siri, start CarTrivia" — [cartrivia.app FAQ](https://cartrivia.app/)); v1.1.1070 made "One-tap AI Voice trivia… the default experience" with a cleaner home screen ([release notes](https://apps.apple.com/us/app/car-trivia-any-topic/id6757024865)). Guest play with starter credits — no sign-in to start (same source).

### 2. In-round screen

- Observed layout (screenshots 1–3, 2026-07-03): dark navy theme; **current player's name as screen title**; a row of **player chips** with turn-indicator dots; a **"Score: 0" pill**; a large **question card**; below it **stacked full-width answer rows, each with a circled letter badge (A, B, …) + answer text**.
- **No visible timer and no round-progress indicator ("3/10") in any screenshot** — absence noted, not proven for the live build.
- **CarPlay/Android Auto is audio-only** ("The audio routes through your car's speakers automatically" — [cartrivia.app FAQ](https://cartrivia.app/)); no dedicated car-screen UI claimed anywhere. Questions are AI-generated per round **with cited sources** ([App Store description](https://apps.apple.com/us/app/car-trivia-any-topic/id6757024865)); where citations surface in the UI is undocumented.

### 3. Answer input

- **Spoken letters:** "just speak the letter of your answer (A, B, C, or D)"; "Answer questions by speaking — no touching your phone while driving" ([cartrivia.app FAQ](https://cartrivia.app/)).
- Credit copy distinguishes **"voice or text-based questions"** ("125 voice or 250 text-based questions" per 500-credit pack — screenshot 4, 2026-07-03), implying a cheaper **text/tap mode**; the on-screen A/B/C/D rows look tappable but tap-to-answer is **unconfirmed**. Voice recognition is server-side; internet required ([FAQ](https://cartrivia.app/)).

### 4. Results / feedback

- Immediate per-question correctness feedback ([cartrivia.app](https://cartrivia.app/)); running **score pill** in-round (screenshots). End-of-round **voice prompts** + **round history with resume** ([release notes/description](https://apps.apple.com/us/app/car-trivia-any-topic/id6757024865)); History tab in the tab bar. Local turn-taking multiplayer with per-player scores ([FAQ](https://cartrivia.app/)). **No explanations, streaks, or leaderboards evidenced.**

### 5. Settings & sign-in

- **Guest-first; sign-in lives in the Account tab, not a launch gate** ([App Store description](https://apps.apple.com/us/app/car-trivia-any-topic/id6757024865); screenshot 4). Monetization: $2.99 paid app + consumable credit packs in a **Store tab** (voice questions cost ~2x text questions). Voice setup lives on/near Home; voice list is server-managed with **multiple AI voice characters** ([release notes](https://apps.apple.com/us/app/car-trivia-any-topic/id6757024865)).
- Safety posture: "CarTrivia is not recommended for the driver… works best when a passenger facilitates play" ([cartrivia.app FAQ](https://cartrivia.app/)).

### 6. Audio controls

- Voice-character selection; audio auto-routes to car speakers ([release notes](https://apps.apple.com/us/app/car-trivia-any-topic/id6757024865); [FAQ](https://cartrivia.app/)). **Explicit gap: no repeat/replay command, mute toggle, or read-options toggle documented anywhere.**

---

## VoicePlay Trivia (Studio Bäsch) — delisted; UI unknown

**Near-total evidence gap.** The App Store listing 404s in US and DE storefronts and iTunes Lookup returns zero results (verified 2026-07-03, [former listing URL](https://apps.apple.com/us/app/voiceplay-trivia/id6741584985)); no Wayback snapshot, press, or video demo exists; the developer's site ([studiobasch.de](https://studiobasch.de)) has no trivia product page (their live product is the different ["VoicePlay: Zero-Screen Kids"](https://apps.apple.com/us/app/voiceplay-zero-screen-kids/id6751637339)). Only cached listing-snippet marketing copy survives — **unverified, not observed UI**: name-any-topic AI quizzes; play "using either your voice or touch" with the ability to "seamlessly switch to classic touch controls"; difficulty + question-format options (MCQ/True-False); badges; "integrates perfectly with AirPods, car infotainment systems" (cached copy for id6741584985, retrieved via search snippet 2026-07-03). Mark it in the review as **"delisted; marketing claims only."** Its claimed voice↔touch seamless switching is nonetheless a second independent signal (with Duolingo and CarTrivia) that voice-first products ship a touch fallback.

---

## HQ Trivia — legacy layout reference (brief)

Live video host filled the screen; at question time the host video **shrank into a small circle that doubled as the countdown timer** above the question card, and the phone gave **haptic ticks, one vibration per remaining second** ([Big Human design case study](https://www.bighuman.com/work/hq-trivia)). Questions were MCQ with **exactly 3 answers as stacked full-width tappable options** below the question, on a **10-second limit**; wrong/timeout = immediate elimination ([Wikipedia](https://en.wikipedia.org/wiki/HQ_(video_game)); [iMore guide](https://www.imore.com/hq-trivia-game-guide)). ~12 questions/15 minutes, live player count on screen. Legacy takeaways: the fused host-avatar+timer element, and full-width stacked answer buttons as the "broadcast trivia" archetype.

---

# Cross-App Synthesis — patterns the UI/UX review can lean on

### (a) What a standard quiz top bar contains

The consistent pattern across all screen-based incumbents is **minimal chrome during a question: a progress/timer element + at most one status element + an exit**, with everything else deferred:

- Duolingo: thin **progress bar** (fills green) + hearts + X — no streak, no XP in-lesson ([Usability Geek](https://usabilitygeek.com/ux-case-study-duolingo/)).
- Kahoot on-device: "Quiz" pill top-center; **timer as a bottom horizontal bar with numeric seconds**; nickname + running score in a bottom status bar (App Store screenshots, 2026-07-03). Host screen: timer left side ([support](https://support.kahoot.com/hc/en-us/articles/115016055107-Live-game-settings)).
- Sporcle: countdown timer + answers-entered counter/percent ([Sporcle blog](https://www.sporcle.com/blog/2016/11/stopwatch-on-sporcle/); [Quiz Play Enhancements support article](https://support.sporcle.com/hc/en-us/articles/36975920240269-Quiz-Play-Enhancements)).
- Trivia Crack: match score + crown meter on the wheel screen; in-question chrome is thin (timer + power-ups at bottom).
- HQ: the timer WAS the host avatar ring ([Big Human](https://www.bighuman.com/work/hq-trivia)).

**Standard set: progress indicator (bar or counter), timer, one identity/score element. Not standard in the top bar: streaks, best scores, XP, category labels as persistent chrome.** Notably, both voice/driving apps show *no* timer and *no* progress indicator on the in-round screen at all (CarTrivia screenshots, 2026-07-03; Drive.fm delivered standing audibly) — in the driving context, competitors moved progress/score to the **audio channel**.

### (b) Streak + best score on a per-question result screen — is it standard?

**The founder's doubt is substantially supported, with one precise nuance:**

- A **within-round answer streak** (consecutive corrects in THIS game) on per-question feedback **has strong precedent**: Kahoot deliberately shows points + streak + rank on the player's device after every answer, with a "snappy Answer Streak animation" ([Inside Kahoot! game-mechanics post](https://medium.com/inside-kahoot/developing-new-game-mechanics-at-kahoot-be7ddb52f6df); [answer-streaks post](https://medium.com/inside-kahoot/experimenting-with-answer-streaks-to-help-make-learning-awesome-3b3357e42595)).
- A **cross-session daily streak or "best score" on a per-question result screen is NOT standard anywhere in the set.** Duolingo — the streak-obsessed reference app — shows the daily streak **once per day, as a dedicated full-screen celebration at lesson end**, never per-question ([duoplanet](https://duoplanet.com/duolingo-xp-guide/); [Deconstructor of Fun](https://duolingo.deconstructoroffun.com/mechanics/streaks)). Sporcle shows best score **on the end-of-quiz screen** ([support, via search index](https://support.sporcle.com/hc/en-us/articles/34071500816141-How-do-I-track-my-quiz-results)). Trivia Crack keeps cumulative stats in a profile/Rankings area ([Corona Insights](https://www.coronainsights.com/2015/05/measuring-trivia-crack-scores-the-fourth-in-a-series-of-posts-analyzing-trivia-crack/)). No competitor shows "best score" per-question.
- **What the evidence supports:** per-question feedback = correctness + points (+ optionally a within-round streak animation); daily streak and best score = end-of-session summary or a dedicated once-a-day moment. Putting persistent stats on every question screen has no prior art in this set.

### (c) Standard sign-in placement

**Guest-first with deferred, value-framed sign-in is the dominant pattern; a hard launch gate is the outlier:**

- Duolingo: play the first lesson before "Create a Profile" is offered ([lingoly.io](https://lingoly.io/duolingo-login/); pattern dates to [2017](https://usabilitygeek.com/ux-case-study-duolingo/)).
- Kahoot players: nickname only, no account ([support](https://support.kahoot.com/hc/en-us/articles/360039890713-Kahoot-join-How-to-join-a-Kahoot-game)).
- Sporcle: optional account "to track games played and scores" ([Common Sense Media](https://www.commonsensemedia.org/app-reviews/sporcle)).
- CarTrivia: guest play with starter credits; sign-in lives in an **Account tab** ([App Store](https://apps.apple.com/us/app/car-trivia-any-topic/id6757024865)).
- The one hard gate: Trivia Crack (email/social required before playing — [Common Sense Media](https://www.commonsensemedia.org/app-reviews/trivia-crack)) — justified by its friend-graph async model, which a driving app doesn't share.

**Standard: let the user play immediately; surface sign-in in a settings/account row or as a deferred prompt framed by what it saves (stats, streaks, credits).**

### (d) Standard "type/tap instead" fallbacks in voice-first / audio contexts

Every product that makes audio load-bearing ships an escape hatch, typically at **multiple scopes**:

- **Duolingo is the reference implementation — three layers:** per-exercise (speaker replay + turtle slow-replay), per-lesson (inline **"Can't listen now"** button that "skip[s] all listening exercises for that lesson"), and global (Settings toggle for Listening/Speaking exercises, reversible) ([Duolingo hearing-aids post, Jan 2026](https://blog.duolingo.com/learning-with-hearing-aids/)). The inline skip is situational and surfaced **at the moment of need**, not buried in settings.
- CarTrivia sells **"voice or text-based questions"** as parallel modes (text at half the credit cost) (screenshot 4, [cartrivia.app](https://cartrivia.app/images/screenshots/screen-4.png), 2026-07-03).
- VoicePlay Trivia marketed "seamlessly switch to classic touch controls" (cached listing copy — unverified).
- Kahoot's read-aloud is itself an opt-in **icon toggle top-right** on an otherwise-visual quiz ([kahoot.com blog](https://kahoot.com/blog/2021/05/05/read-aloud-game-option-kahoot-app/)) — the same pattern inverted.

**Standard: an inline, single-tap modality switch at the point of friction + a durable settings toggle. A voice-first quiz app should mirror Duolingo: on-screen tappable answers always available, a "can't talk now"-style per-round switch, and a global voice on/off setting.**

### (e) Standard replay / mute patterns

- **Replay is a first-class, always-visible button in audio-led apps:** Duolingo's blue **speaker button** (unlimited replays) + **turtle button** for slow replay with word pauses ([Duolingo blog](https://blog.duolingo.com/learning-with-hearing-aids/); [listening-skills post](https://blog.duolingo.com/covering-all-the-bases-duolingos-approach-to-listening-skills/)). The best-rated Alexa trivia skills support a spoken **"repeat"** command (per the companion competitive analysis, table-stakes section — Question of the Day supports "Repeat").
- **Kahoot's read-aloud sequencing** (question first, then options, highlighting each option as spoken, behind a top-right icon toggle) is the closest mobile-native read-aloud prior art ([kahoot.com blog](https://kahoot.com/blog/2021/05/05/read-aloud-game-option-kahoot-app/)).
- **Mute/sound toggles live in settings, not on the question screen,** in screen-first apps: Trivia Crack (Sound/Music/Vibration in Settings — [etermax, via search index](https://triviacrack.help.etermax.com/hc/en-us/articles/1500002715002-How-do-I-change-my-preferences)); Kahoot puts the sound toggle on the **host screen top-right** during a game ([support community, via search index](https://support.kahoot.com/hc/en-us/community/posts/360035202773-Option-to-toggle-Kahoot-sound-off-on)); Sporcle has no documented toggle at all.
- **Gap = opportunity:** neither recent voice-driving competitor (Drive.fm, CarTrivia) documents ANY repeat-question command, mute, or read-options toggle. A discoverable "repeat" voice command + a visible replay button would exceed every direct competitor's demonstrated UI, and matches what the Alexa gold-standard skills already trained users to expect.

---

### Evidence-quality summary

- **Strongest:** Duolingo audio controls (official Jan 2026 blog, verbatim quotes); Kahoot read-aloud + streak/feedback design (official blog + Inside Kahoot! design posts); CarTrivia (live listing + first-hand screenshot inspection 2026-07-03).
- **Moderate:** Trivia Crack (support docs via search index + current marketing screenshots; classic-mode in-question visuals partly inferred from Live-mode shots); Kahoot host-screen glyphs (timer form inferred); Sporcle (mostly website-sourced, applied to the app by inference).
- **Weak / reconstructed:** Drive.fm (delisted; 2018–2020 press only); VoicePlay Trivia (delisted; cached marketing copy only).
- **Unresolved conflicts flagged, not averaged:** Sporcle premium pricing (two figures); Trivia Crack crown-gauntlet length (5 vs 6).
