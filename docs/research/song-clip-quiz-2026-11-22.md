# Research: "guess the song" from a short clip (Honk! inspiration)

**Question:** How do "guess the song from a short clip" games work (audio source, licensing, UX)? What do players praise and resent, and what do they pay for? How could Trubbo add this? Trigger: the new competitor **Honk! Road Trip Quiz** plays 10 s song clips in its "Name That Song" mode.
**Date:** 2026-11-22 · **Session:** song clips, Honk! inspiration (mass research) · **Plan:** `docs/research/plans/song-clip-quiz.json`

| Corpus | Count |
|---|---|
| Raw inputs harvested | **11 436** (App Store 3 272 from 19 apps in 7 countries · Google Play 5 507 from 16 apps · Reddit 2 007 from 11 communities · Hacker News 727) |
| Matched topic keywords | 7 692 |
| After dropping off-topic apps the search pulled in (Shazam, Spotify, Deezer, Wordle, Hearthstone, Gwent, bingo, K-pop rhythm games) | 5 197 |
| Coded one by one | **1 500**, a stratified random sample (App Store 600 · Play 450 · Reddit 350 · HN 100) |
| On topic after reading | **1 186** (stores 1 050 · Reddit 122 · HN 14) |
| Secondary sources (rules, licensing, Honk! itself) | 40+ pages, linked inline |

Honk! itself has **0 ratings** (launched 2026-11-10), so the player evidence comes from analog apps: SongPop (4 apps), Bandle, Hitster, Volley's Song Quiz ("Weekend Games"), Jingle Quiz, Songless, Tapzz and smaller clones. Shares below are shares of the on-topic set, not of players.

## Answer in five lines

1. **Honk! uses Apple Music's free 30 s previews** (MusicKit permission, no subscription needed) and plays the first 10 s ([privacy](https://honkquiz.com/privacy), [support](https://honkquiz.com/support)).
2. **Apple's App Review rules forbid exactly that.** Guideline 5.2.5: previews "may not be used for their entertainment value (such as … the soundtrack to a game)". Guideline 4.5.2(ii): playing "a specific song at a particular moment" needs the rights holders' permission. I verified both in the [current text](https://developer.apple.com/app-store/review/guidelines/). Spotify's policy bans "a game, including trivia quizzes". Honk! is either unreviewed on this point or at risk, so copying it is a takedown risk, not a shortcut.
3. **Bandle, the best-loved paid model in this data, plays no original recordings.** It plays its own MIDI-style re-arrangements, layered instrument by instrument. It sells $1.99 genre and decade packs, and those buyers are the happiest payers in the corpus (18 of 24 happy-payer items).
4. **Players come for social play and a daily habit** (n=177 and n=73, mostly positive). They leave over ads, paywalls and currency grinds (n=238 + 282 + 58, almost all negative), which mostly means SongPop.
5. **Voice answering a song title is hard.** Volley's voice-only Song Quiz draws most of the voice complaints: slow and spotty recognition (n=19 voice + n=30 answer-input items, anecdotal-to-small). "Close enough counts" matching and aliases are mandatory.

## Findings, ranked by count (n = on-topic coded items, of 1 186)

| # | Finding | n | Share | Sentiment | Mostly from |
|---|---|---|---|---|---|
| 1 | Bugs, crashes, lost progress, sound not playing | 330 | 28 % | 88 % neg | SongPop family, Hitster |
| 2 | Paywall / subscription resentment | 282 | 24 % | 94 % neg | SongPop (174), Bandle (24), Tapzz |
| 3 | Ads | 238 | 20 % | 92 % neg | SongPop (185) |
| 4 | Playing together (party, family, couples) | 177 | 15 % | 53 % pos | SongPop Party, Bandle |
| 5 | Daily puzzle / ritual | 73 | 6 % | 52 % pos | Bandle (48), Heardle |
| 6 | Song library too narrow / missing artists, genres | 66 | 6 % | 59 % neg | SongPop, Heardle |
| 7 | Requests a genre, decade, artist or language | 62 | 5 % | mixed | long tail |
| 8 | Coins, tickets, energy, pay-to-win | 58 | 5 % | 93 % neg | SongPop |
| 9 | Needs a Spotify / streaming account | 57 | 5 % | 84 % neg | **Hitster (45)** |
| 10 | Praises variety / discovering music / nostalgia | 56 | 5 % | pos | SongPop, Bandle |
| 11 | Same songs repeat | 44 | 4 % | 61 % neg | SongPop, Weekend Games |
| 12 | Audio wrong or poor (soundalikes, robot voice, wrong answer key, explicit lyrics) | 38 | 3 % | neg | Bandle, Heardle, clones |
| 13 | Answer input (typing strictness, voice misses, spelling variants) | 30 | 3 % | neg | Weekend Games (15) |
| 14 | Happy payer | 24 | 2 % | pos | **Bandle (18)** |
| 15 | Voice / hands-free play | 19 | 2 % | mixed | Weekend Games (14) *(small n)* |
| 16 | Kids / explicit content | 17 | 1 % | mixed | *(small n)* |
| 17 | Clip length / wrong part of the song | 16 | 1 % | neg | Hitster, Bandle *(small n)* |

Quotes (verbatim, one or two per finding):

- **Paywall:** "app allows you to play only 5 quizzes in 24 hours and then a message pops out that you need to pay for premium" ([Tapzz](https://apps.apple.com/sk/app/id6754511325)). "the £9.99 monthly subscription fee is ridiculous" ([SongPop](https://play.google.com/store/apps/details?id=com.freshplanet.games.SongPop3)).
- **Happy payer (Bandle):** "I also love that the song packs are extremely reasonably priced" and "we have bought almost every pack, we are obsessed" ([Play](https://play.google.com/store/apps/details?id=com.bandlegame.bandleguessasong), [App Store](https://apps.apple.com/au/app/id6471419531)).
- **Not real recordings, and accepted:** "the songs aren't 'real', I think they're just midi recreations … which makes some rather hard to guess" and "Wish it had the actual songs, but obviously that would be much more complicated with licensing concerns" ([Bandle, Play](https://play.google.com/store/apps/details?id=com.bandlegame.bandleguessasong)). The flip side: "they sound like reproductions made with a children's toy" (same link).
- **Social / daily:** "been playing the daily with friends and family for 3 months … we sometimes play together on family dinners" (Bandle, same link).
- **Streaming account:** "sehr schade, dass man zwangsläufig Spotify Premium braucht" ([Hitster](https://apps.apple.com/de/app/id1621483628)).
- **Voice:** "the voice recognition, recording your voice to get an answer, is very spotty" and "Alexa doesn't recognize" ([Weekend Games](https://apps.apple.com/us/app/id1345558380)). The wish runs the other way too: "have the option of speaking the answer instead of typing it" ([Jingle Quiz](https://apps.apple.com/us/app/id1552362023)).
- **Clip part:** "the portion played is not the recognizable part" ([Hitster](https://apps.apple.com/us/app/id1621483628)). "Wish that the song clips were longer and were of a very recognizable part of the song" (Weekend Games).
- **Repeats:** "you just play the same 30 songs over and over again" ([SongPop](https://play.google.com/store/apps/details?id=com.freshplanet.games.SongPop3)).
- **Kids:** "Devs, please give us a way to prevent explicit content" ([Soundle](https://play.google.com/store/apps/details?id=com.c2m.songquiz)).

Requested themes (n=62, long tail, no cluster above 2): rock and metal, classic rock, country, hip hop, K-pop, video game soundtracks, children's songs, Latin, Arabic and German-language songs, "pick which decades".

## How Honk! does it (from its own pages)

- **Audio:** 30 s Apple Music previews, the first 10 s played. Needs internet and the Apple Music permission; songs not available in the player's country are skipped. The catalog sits on Firebase. No Apple Music attribution was found on its site or store page, although 5.2.5 requires a link to Apple Music. ([privacy](https://honkquiz.com/privacy), [guide](https://honkquiz.com/guides/music-trivia-questions))
- **Money:** "fuel" that refills daily, a top-up of 10 games for $2.99, and a one-time Honk! Pass for $9.99 (no subscription, no ads). The Daily Honk and Name That Song are always free. Fuel arrived in v1.2 on 2026-11-21. ([App Store](https://apps.apple.com/us/app/honk-road-trip-quiz/id6831106244))
- **Other ideas:** Beat the Car (the whole car is one team against the app), Endless Road, Clue Rush (easier and easier clues, faster answers score more), Daily Honk (7 questions, resets at 06:00, shareable card), kids/adults/family mix, CarPlay, a Siri phrase per game ("Hey Siri, Honk a song"), offline play except songs, and SEO guides on the website with tap-to-reveal answers.
- **Who:** one developer (Luka Šimunec) shipping a new app almost every week (Clue Rush! 11-16, Beep! 11-18), English only, iOS 18+, Firebase plus Apple speech recognition.

## Audio sources and their rules

| Source | Clip for a quiz allowed? | Notes |
|---|---|---|
| Apple Music / iTunes previews | **No by the rule text** (5.2.5, 4.5.2(ii)) | The rule is stated plainly. Two developer-forum threads asking about trivia use got no answer ([1](https://developer.apple.com/forums/thread/848839), [2](https://developer.apple.com/forums/thread/836910)). Downloading MusicKit audio is also banned, so Honk!'s "previews from Firebase" line is a second risk. |
| Spotify | **No** ("Do not create a game, including trivia quizzes", [policy](https://developer.spotify.com/policy/)) | Previews were removed for new apps in Nov 2024. Hitster works around it with the player's own Premium account, the top complaint against it (n=45). |
| Deezer | Unclear, written agreement needed | 30 s extracts; storing audio is forbidden ([guidelines](https://developers.deezer.com/guidelines)). |
| YouTube | No | Audio separation and background play break its terms; Musi was sued by Universal and Sony. |
| Licensed clip API (Songclip, Feed Clips) | **Yes, by design** | Songclip has UMG/UMPG, Warner and Hipgnosis deals ([Music Week](https://www.musicweek.com/digital/read/songclip-signs-strategic-partnership-with-umg-and-umpg/085990)). Price, EU coverage and SK/CZ repertoire unknown *(unverified)*. |
| Own re-arrangements (the Bandle way) | No label master needed | The composition still belongs to its publisher. Whether Bandle holds a publishing licence is **not found** *(unverified)*. Lower risk than originals, but not zero. |
| Public domain / folk / classical | Yes | EU recordings expire 70 years after release. Few players can name them, so it suits a "which composer / which folk song" round, not hit-guessing. |
| AI soundalikes | Legally murky, and not "the real song" | Suno and Udio are still settling with the labels. |

Technical notes: duck other audio during the clip and keep TTS out of the clip. Pick the clip start by hand (hook or chorus, not the intro). Match answers fuzzily: strip "feat.", brackets and remaster tags, accept artist or title, keep aliases per language.

## What the evidence does NOT show, and limits

- **No Honk! player reviews exist yet.** Its approach is unproven with players and with App Review over time.
- **No price for licensed clips** was found. Songclip's terms for an EU subscription app need a direct inquiry.
- **Mostly English-language US stores.** German reviews come mainly from Hitster. No Slovak or Czech song-quiz reviews turned up, so local-repertoire demand is not measured.
- **SongPop dominates the counts** (4 apps, half the on-topic items). Ads, paywall and currency findings are largely about one company.
- **Reddit comment search failed** (90 of 103 queries returned an error from the archive); Reddit posts came through. HN was mostly off-topic (14 of 100 sampled).
- **This is a 1 500-item random sample** of 5 197 relevant items, not all of them. Spot check: about 2 of 20 items coded loosely, within tolerance.
- Nothing here is legal advice. Every licensing path needs written confirmation before launch.

## Options for Trubbo (no decision made)

1. **Copy Honk! (Apple previews).** Cheap: we already have an `audio` question type and media links in the question model. It breaks the plain text of Apple guideline 5.2.5 and could get the app rejected or pulled, which would hit the whole app, not one mode.
2. **Music round with no recordings.** Voice-read music trivia: lyrics read aloud, "which band sang…", decades, artist facts, plus the existing silhouette and image approach (album-cover style). No licence needed, low effort, fits voice-first play. Weaker than hearing the actual song.
3. **The Bandle way: own instrumental re-arrangements.** Hits stay recognisable without label recordings; players accept the "MIDI" sound and pay for $1.99 packs. Needs per-song production work and a publisher-licensing check (SOZA/OSA for local songs). Medium effort, low-to-medium legal risk.
4. **Licensed clips (Songclip or a local label).** Real songs, legally clean. Costs unknown and probably minimum guarantees. Slovak/Czech hits likely need a separate local deal. High business effort.
5. **Wait and watch Honk!** Re-run this plan (same slug) in a month or two and see whether Honk! keeps Name That Song through App Review and how players rate it.

Independent of music, ideas from Honk! worth weighing: the whole car as one team against the app; a clue-rush mode (easier clues, faster answer scores more); a Siri phrase per mode; a one-time family pass next to the subscription.
