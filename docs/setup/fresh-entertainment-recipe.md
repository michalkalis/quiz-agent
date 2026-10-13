# Fresh entertainment top-up recipe

The default way to generate fresh entertainment questions (#199 — question stock top-ups, #195 — fresh entertainment boost). It comes from the #201 blind comparison of 2026-10-13: `docs/issues/issue-201-gettable-entertainment.md`.

What the founder's ratings showed:
- The player's own country matters most. Slovak questions averaged 9.0, English ones 7.8.
- Awards, film crew and US-only niche topics scored lowest.
- Famous things seen from a surprising angle scored highest.

The casual-player check (`CASUAL_PLAYER_GATE`) did not predict those ratings, so it stays **off**.

## Seeds

Collect ~25 seed facts per language with web research on the day of the run. Each seed is one line: the thing people talked about, one surprising angle and a source URL.

- **Sources of ideas:** the most-read Wikipedia articles of the last 30 days in the player's language (`apps/quiz-pack-api/scripts/entity_fame.py top`), Google Year in Search for SK/CZ, IFPI SK/CZ charts, TV ratings (MediaGuru) for reality shows, and Reddit top posts read by hand as ideas. Reddit is never scraped, and its facts are never used as the source.
- **Fame first:** check the subject's monthly pageviews with `entity_fame.py views`. Drop seeds from the bottom third.
- **sk / cs:** about 7 in 10 seeds come from the domestic scene: Slovak or Czech celebrities, reality and TV shows, domestic hits and moments. The rest are world mega-hits known there.
- **Skip:** award categories ("who won X"), directors, producers, puppeteers and other crew, and US-only or fan-only topics.
- Every fact still needs a trusted `source_url`: Wikipedia, then domain authorities, then reputable media. No aggregators or tabloids.

## Brief (`--prompt`)

Build the brief the way `docs/testing/runs/gettable-entertainment-2026-10-13/run_arm.sh` builds arm B. It has the same anchor, freshness and covered-answers parts. Replace its focus and player paragraphs with the ones below.

Focus:
- **en:** "Every question is about global entertainment (film, TV and streaming, music, video games, viral pop-culture moments) that a casual fan anywhere in the world, not only in the US, would recognise."
- **sk:** "Most questions (about 7 in 10) are about the Slovak entertainment scene: Slovak celebrities, reality and TV shows, domestic hits, films and moments people in Slovakia talked about; the rest are world mega-hits well known in Slovakia. Do not ask about the Czech scene unless it is genuinely shared."
- **cs:** the same as sk, with Czech and Czechia in place of Slovak and Slovakia.

Player:
> Who must be able to answer: an ordinary adult who follows film, TV, music and celebrities only loosely. Pick a famous thing first, then a surprising angle. Both the subject and the detail you ask for must be something such a player could have caught, half-remembers or can reason their way to. Do not build questions around awards (who won, what was won) or around people behind the camera (directors, producers, puppeteers and other crew; famous singers and songwriters are fine), not even by asking it the other way round, and skip topics only US audiences or fans would know. If a seed is about these, skip it. Never ask an open question whose answer is a number: make it a multiple-choice question with 3 clearly different options, or pick another fact. No giveaways: the wording must not name or uniquely describe the answer.

## Run

- Generator: a frontier model (currently Opus 5.5). Any model change needs a comparison and the founder's approval.
- sk and cs: the blind answerability proxy runs on Sonnet (`LLM_SESSION_MAP=…,deepseek-v4-flash=sonnet`, as in #195).
- Import, translate and check stock as in `docs/testing/runs/fresh-entertainment-2026-10-12/` (`run_import.sh`, `stock.sh`).
