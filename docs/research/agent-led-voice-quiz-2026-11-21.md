# Research: The quiz led by a voice agent

**Date:** 2026-11-21 | **Session:** research subagent run (session name not available to it) | **Query:** Should the Trubbo quiz (and its settings) be led by a conversational voice agent instead of today's scripted flow plus on-device voice commands? What exists, does it work in Slovak, Czech and Ukrainian, what does it cost, and what should we try first?

Builds on [voice commands hands-free (2026-07-02)](voice-commands-handsfree-research-2026-07-02.md), [speech recognition in car noise (2026-09-21)](stt-car-noise-research-2026-09-21.md), [cost model for issue #93 — subscription and packs (2026-07-08)](issue-93-cost-model-2026-07-08.md), [what makes a quiz fun (2026-10-14)](quiz-game-fun-2026-10-14.md), [CarPlay support (2026-07-16)](carplay-support-research-2026-07-16.md). Not repeated here.

**How to read the labels.** [first-hand] = measured in this project. [vendor] = the vendor's own page, fetched 2026-11-21. [independent] = third-party benchmark or paper. [unverified] = search snippet, secondary source or my inference. All prices and model names are as of 2026-11-21; this field changes monthly. Nothing was built, bought or signed up for.

## Executive summary

- **A full live agent host is possible today, but it is the wrong first step.** It costs roughly 15 to 90 times more per question than today, the evidence that it understands Slovak and Czech well is vendor-only, real-time voice models call tools far less reliably than text models, and two of the three big vendors have terms that clash with a family product.
- **The founder's instinct about "not listening while the player thinks" is exactly right, and it is the key design decision.** No turn-detection model on the market is trained for Slovak or Czech. Every stack that can guarantee silent thinking does it the same way: the app, not the model, decides when the microphone is open. A quiz knows precisely when an answer is expected, so this is easy for us and hard for a general assistant.
- **The agent does not need a real-time voice model.** The parts that would make the game feel led (natural commands in any wording, "wait", "again", "hint", "I don't know", a short reaction to the answer, setting up a quiz by talking) can run on the pieces we already have in production: cloud transcription that works for Slovak and Czech [first-hand], the small Claude model that already judges answers, and the ElevenLabs voice the player already knows.
- **Recommendation: Direction 2, "the hosted answer turn", built on our own chain, with pre-written host lines (Direction 3) as its cost lever.** It replaces the weak on-device command layer, removes most of the quiz screen's states and hints, keeps questions, verdicts and score on our server, and costs about 1 to 5 cents per ten-question round instead of 25 to 60 cents.
- **Does an agent host differentiate?** Unproven either way. No public study compares an agent host with a scripted one, and no AI-host trivia app with visible traction was found. General assistants already run free voice quizzes, badly (invented questions, wrong verdicts). Our edge is verified questions, honest scoring and good Slovak and Czech voices; a host should narrate that, not replace it.
- **Smallest experiment:** a no-cost replay test of our recorded answers through live-listening candidates, then a flagged prototype of the hosted turn, with pass/fail thresholds below. Proposed cash cap: $10 (needs founder approval).

## 1. What exists now

Two families of technology, and a layer of glue around them.

**Speech-to-speech models.** One model hears audio and speaks audio. Fast and natural, can be interrupted, but you cannot choose the voice freely, cannot pin the language everywhere, and it is the most expensive family.

**Chained pipelines.** Speech recognition, then a text language model, then speech synthesis. Each part is replaceable (we could keep our current voice and our current recogniser), text models follow rules and call tools more reliably, but there are more moving parts and a little more delay.

**Orchestration layers.** Frameworks and hosted platforms that wire either family to a phone app and handle turn-taking, interruptions and tool calls.

| Option | Family | Price [vendor unless noted] | iOS path | Notes |
|---|---|---|---|---|
| OpenAI GPT-Live 1.1 | speech-to-speech, listens while speaking | $0.05/min active, $0.02/min standby; tools billed extra | WebRTC or WebSocket, no Swift SDK | Standby is not defined on the pricing page. No language list published. |
| OpenAI gpt-realtime-2.1-mini / 2.1 | speech-to-speech | audio $10 in / $20 out per 1M tokens (mini); $32 / $64 (full). About $0.07 and $0.38 per minute per a third party [unverified] | same | Manual turn mode documented. 60-minute session cap. |
| Google Gemini 3.8 Live | speech-to-speech | about $0.005/min heard + $0.018/min spoken | Swift SDK via Firebase [unverified] | Cheapest. Language cannot be pinned. Terms forbid apps "likely to be accessed by individuals under the age of 18" (terms effective 2026-03-23, read today). |
| ElevenLabs Agents | chained platform (plus new own real-time models) | $0.08 per call minute, language model billed on top; silence over 10 s billed at 5% | native Swift SDK | Same voices we use. Has a "skip turn" tool and a turn timeout of 1 to 30 s. |
| LiveKit Agents / Pipecat | open-source orchestration, hosted variants | hosting $0.01/min plus parts; LiveKit's own example totals $0.048/min | Swift client SDKs | Most control (manual turns, mute rules, per-step tool limits). Most work. |
| Vapi, Retell, Deepgram Voice Agent, Cartesia Line | hosted chained platforms | $0.03 to $0.13 per minute all-in | varies | Built for phone support lines; nothing they add helps a quiz. |
| Hume EVI | speech-to-speech | n/a | n/a | No Slovak, Czech or Ukrainian. A shutdown notice for 2026-11-13 was reported [unverified]. Out. |
| xAI Grok Voice | speech-to-speech | $0.08/min via a reseller page | WebSocket | Interrupted users in 84% of turns in one benchmark [independent]. Out. |
| **Anthropic** | no real-time voice API for developers (docs list text and image in, text out) | Claude Haiku 5.5: $0.10 in / $0.50 out per 1M tokens | n/a | Claude can only be the thinking part of a chain. That is what we already do for answer judging. |
| Apple on-device | recognition only | free | native | Apple's newer recogniser has no Slovak or Czech [first-hand, iOS 26.5 SDK and macOS 26.7.1]; the older dictation one does, and is what feels unreliable today. |

Latency: no vendor publishes an end-to-end figure. Independent benchmarks of turns that include a tool call measured about 4 s (Gemini Live), 7 s (OpenAI real-time) and 10 s (a chained system) on multi-step tasks [independent, Full-Duplex-Bench v3]; a quiz turn has one simple call and should be faster, but this is unmeasured for us. Today our judge answers within 1.2 to 1.8 s nine times out of ten [first-hand, 2026-10].

## 2. Slovak, Czech and Ukrainian

This is the weakest part of the whole field. **No independent comparison of commercial engines on Slovak, Czech or Ukrainian was found.** Every cross-vendor number comes from a vendor, often about a competitor.

| Option | Understands sk / cs / uk | Speaks sk / cs / uk | Evidence |
|---|---|---|---|
| Our current cloud transcription (OpenAI gpt-transcribe, primed with the question) | works in production for sk and cs, including car recordings | n/a | **first-hand**, but never scored as a percentage |
| ElevenLabs live recognition (Scribe v2 Realtime) | vendor rates the non-live model "excellent, 5% errors or fewer" for all three; no rating published for the live one | n/a | **first-hand negative:** on our car recordings of 2026-10-16 it "heard nothing or nonsense" and was removed from the answer path (issue #208 — TestFlight voice feedback). A successor, Scribe v3 Live, exists and is untested. |
| ElevenLabs voices (Flash v2.5, v4 Turbo, v3) | n/a | all three listed; our blind test of 28 clips found the voices acceptable; Czech now uses a native Czech voice | **first-hand** for sk and cs |
| OpenAI real-time models | all three "listed", but the bar for being listed is under 50% word errors [vendor, relayed by Microsoft] | voices "optimized for English" [vendor] | thin; forum reports of wrong-language transcripts and foreign accents in other languages |
| Gemini Live | all three in a 99-language table | same; language is chosen automatically and cannot be forced | thin; older reports of garbled Ukrainian and wrong Czech grammar gender |
| Whisper large-v2 (reference point) | 11.7% / 13.3% / 8.6% word errors on a read-speech benchmark | n/a | independent (paper) |
| Turn-end detectors (LiveKit, Pipecat, Deepgram Flux) | LiveKit: none of the three. Pipecat: Ukrainian only. Flux: none. | n/a | vendor docs |

What follows from this:

1. Anything that relies on a model guessing when a Slovak or Czech speaker has finished is unsupported. Use fixed listening windows and plain silence detection.
2. ElevenLabs Agents, the option the grant points to, listens with the same family of live recogniser that failed for us in the car. It must be re-tested before it is considered.
3. Short answers and proper names ("Dunaj", "Nirvana", a footballer's surname) are the hardest case and no one publishes numbers for them. We have our own recorded answers (issue #197 — voice replay corpus); they are the only evidence worth trusting.
4. No evidence was found, either way, of Slovak drifting into Czech or Ukrainian into Russian in live voice models. Anecdotes exist for Ukrainian to Russian in recognition and in one synthetic voice.

## 3. Turn-taking for a quiz

**Silent thinking.** Automatic turn detection cannot give a player 5 to 30 quiet seconds. OpenAI's most patient setting waits at most 8 s; Google recommends under 1 s; ElevenLabs waits at most 30 s and then speaks. What does work, on every stack, is manual control: the app opens and closes the microphone and tells the model when to answer (OpenAI: turn detection off; Google: activity detection off; LiveKit: manual turns; Pipecat: mute rules) [vendor]. ElevenLabs also has a "skip turn" tool the agent can call when the player says "give me a second" [vendor]. Our game already has a think-time countdown and a visible mic state; the hosted turn keeps that and simply lets the player say more things inside the window.

**Background talk.** In an independent test OpenAI's real-time model answered almost everything it heard, including speech not meant for it (6% selectivity) [independent, tau-Voice]. Voice-isolation filters exist (Krisp, ai-coustics) but work best with one near speaker and are not tested against a television or car radio. A closed microphone outside the answer window is the reliable fix.

**Interrupting the host (barge-in)** needs echo cancellation, which on iPhone means the phone-call audio mode. Side effects: other audio is ducked, playback quality drops, and over Bluetooth the link switches from music quality to hands-free call quality. One developer measured a 20 to 36 s stall on such a switch with AirPods [one forum report].

**Car.** An Apple engineer confirmed on the developer forum that using the car's microphone over CarPlay puts the head unit in its speech mode and pauses the car's own radio, with no setting to avoid it [independent]. Apple added a CarPlay category for voice conversation apps in iOS 26.4 (voice first, at most three screens, approval per app); whether a trivia game qualifies is not stated anywhere (see issue #97 — CarPlay support). A permanently open conversational mic makes every one of these worse; short listening windows are what we do today.

**Several people shouting answers.** No real-time stack offers live "who said that". Research models can separate up to four voices but give anonymous labels and struggle with overlap. For same-room play the own-phone design in issue #212 — multiplayer same room remains the right answer; a shared host can accept "the first answer heard" at most.

## 4. Keeping the game honest and ours

**Tool calling in live voice is markedly weaker than in text.** Independent results: a text model solved 85% of tool tasks while voice agents solved 31 to 51% in clean audio and 26 to 38% in realistic audio (tau-Voice); another benchmark put the best voice model at 60% on chained tool tasks; a third found speech-to-speech models less faithful to tool results than chained systems (EVA-Bench). OpenAI's own figure for its real-time model on a function-calling benchmark is 66.5% [vendor, 2025-08]. Documented failures: claiming an action that was never called, acting before the user finished correcting, wrong argument values, speaking over a tool call.

**The answer must never be in the model's head.** Security guidance (OWASP) is blunt: a hidden instruction is not a secret. If the host model knows the correct answer, a player (or a child) can talk it out of it. The pattern that follows:

- The server owns questions, verdict, score, quota and purchases. The model has no tool that sets a score, so "mark that as correct" cannot work.
- The verdict comes from our existing evaluation (rules first, small Claude model second). The host only receives "correct / close / wrong" plus the text it may say, after the verdict.
- The question is played from our pre-made recording, not re-read by a model, so it cannot be misread or paraphrased.
- Each step exposes only the tools valid at that step (the approach of Pipecat Flows, LiveKit tasks, ElevenLabs workflows). Negative rules in a prompt ("never reveal") break under pressure [vendor experience, Deepgram].
- Sessions are short and context is reset per question, which removes long-session drift.

Teams that publish on this converge on "ordinary code for the mechanics, the model for the fuzzy parts" (AssemblyAI, SignalWire, DevRev, which dropped speech-to-speech for reliability) [vendor write-ups, no measured before/after found]. That is the shape recommended below.

## 5. Cost and latency

Assumptions (mine): a round is 10 questions and about 7 minutes of connection (the host speaks about half, the player thinks or speaks the rest). A free user plays 30 questions a month (3 rounds). A subscriber example is 300 questions (30 rounds). Net subscription revenue is about $4.58 a month after Apple's cut (cost doc).

| Option | Per round | Free user / month | Subscriber example / month | Against "keep language models off the hot path" |
|---|---|---|---|---|
| Today (cached question audio, cloud transcription, rules then small model judge) | about $0.006 | $0.02 | $0.18 | Already bent: an intent call and sometimes a judge call per spoken answer |
| Direction 1, agent at the edges | $0.015 to $0.02 | $0.05 | $0.5 | One short setup conversation per quiz; round unchanged |
| Direction 2, hosted answer turn on our chain | $0.01 to $0.05 | $0.03 to $0.15 | $0.3 to $1.5 | One more small call per question; live speech only for the reaction line |
| Direction 3, pre-written host | about $0.006 | $0.02 | $0.2 | Fully respects it: all host lines are curated data |
| Direction 4 on Gemini Live | $0.10 to $0.20 | $0.3 to $0.6 | $3 to $6 | Model is the hot path. Blocked by terms for a family app |
| Direction 4 on OpenAI GPT-Live | $0.26 to $0.35 | about $1 | about $10 | Model is the hot path |
| Direction 4 on ElevenLabs Agents | $0.40 to $0.56 list | about $1.7 | about $17 | Model is the hot path |

Plainly: any full live host makes a free user cost 15 to 90 times more than today and makes an active subscriber cost more than they pay, unless the mode is capped or sold separately. Directions 1 to 3 leave unit economics intact.

**What the ElevenLabs grant buys.** The grant page states 33,000,000 characters for 12 months and "over 680 hours of Agents usage" [vendor]. That is about 40,800 agent minutes, or roughly 5,800 seven-minute rounds, about 16 rounds a day for a year, if nothing else used the grant. It already pays for our question audio. Spread evenly it is about 90,000 credits a day, and our configured service-wide budget is 20,000 a day, so a live ElevenLabs host would use up the configured budget after 3 to 4 rounds across all players, and the whole day's share of the grant after about 16. The same grant spent as plain speech buys 33 to 66 million characters of the fast voice [vendor], or 165 million at the rate we measured for our current voice (0.2 credit per character) [first-hand]. An 80-character reaction line costs 16 to 40 credits: the configured daily budget covers 500 to 1,250 live reactions. The agents page also says agent plans "are billed by call minutes, not by the shared credit pool", which conflicts with the grant page; ask ElevenLabs before relying on either reading.

## 6. Prior art and competition

- **Smart speakers.** Trivia was the genre that worked best on Alexa (daily fresh questions, short sessions; one daily-question skill claimed hundreds of thousands of monthly users [vendor blog]), but early voice apps kept about 3% of users into week two [press, 2017], and Google removed third-party voice games entirely in June 2023 [primary]. Usability studies of that generation found rigid phrasing and recall-heavy commands [Nielsen Norman Group]. Why the genre faded is not documented; discovery and retention are the usual explanations [unverified].
- **Volley**, the largest voice-games studio, started on Alexa, moved to TV, raised $55M in 2024 and reported a game with a fully language-model-powered host [press]. No engagement numbers were found.
- **Drivetime**, in-car voice trivia with a licensed Jeopardy! game and about $10 a month, raised $15M by 2019 [press]. Its fate could not be established.
- **Cars.** Volkswagen's ChatGPT assistant and Tesla's Grok advertise spontaneous trivia [press]. No usage data.
- **General assistants as quiz hosts.** Reports are few but point the same way: invented content mixed into a quiz, a looping answer, confidently wrong claims, interrupting the user [user reports]. No assistant has an official voice quiz mode.
- **Duolingo's video call with a character** is the nearest app-led voice conversation in a consumer app. It sits only in the most expensive tier and calls are kept to one to three minutes [reviews]; the likely reason is cost [unverified].
- **AI-host trivia apps** (several small listings on iOS, Roku and the web) exist; no traction numbers, reviews of substance or shutdowns were found.
- **Research** on voiced game characters reports novelty at first, then broken immersion from odd timing, wrong answers and empty talk [academic]. Nothing was found on host fatigue over repeated play. Our own research on fun names "a host who reacts" as one of four missing levers, alongside stakes, other people and reveals.

**Verdict.** A host that reacts is a plausible differentiator; a model that improvises the quiz is not, because that is what free assistants already do poorly. Evidence that players pay for or return to an agent host: none found.

## 7. Privacy, App Store and platform rules

- **App Review guideline 5.1.2(i)** (read today): personal data shared with third parties, "including with third-party AI", needs clear disclosure and explicit permission. A new voice vendor means a consent step and a privacy-policy update. **2.5.14** requires consent and a clear indication while recording. A mic that is open only in visible windows is the easy case.
- **Kids Category:** already declined for the family section (issue #236 — family section) because it forbids sending voice to third parties. A live agent does not change that decision, but it raises the stakes of "not directed at children".
- **Vendor terms on minors.** Google: no apps likely to be accessed by under-18s [vendor, read today]. OpenAI: do not process personal data of children under 13 or the local digital-consent age without zero data retention, which needs approval [vendor, via search summary]. ElevenLabs: service not for users under 18; zero retention and EU hosting are enterprise-only [vendor]. The digital-consent ages for Slovakia (16) and Czechia (15) are from background knowledge [unverified].
- **Data handling.** OpenAI's real-time endpoint: not used for training, 30-day abuse-monitoring retention, EU processing available if chosen when the project is created [vendor]. Gemini Live paid tier: not used for training, short abuse logging [vendor summary].
- **EU AI Act, Article 50:** people must be told they are talking to an AI; reported as applying from 2026-08-02, with only the content-marking part delayed [press, check the legal text]. A named AI host needs a visible "AI host" label either way.
- **Screen off and interruptions.** A voice conversation can continue in the background with the audio mode enabled, but developers report sessions failing to resume after a phone call [forum reports]. Needs device testing.
- **Housekeeping found on the way:** the privacy policy lists OpenAI for "backup evaluation" and does not appear to list Anthropic, whose model is now the primary judge [recon of the repo, not verified against the live site].

## 8. Proposals

All four keep typing and tapping as equal ways to play. Effort is relative, in phases.

### Direction 1: Agent at the edges
The round stays scripted. The player sets up a quiz by talking, and commands are understood in any wording by the cloud instead of the on-device recogniser.

> **Hráč:** „Daj mi desať otázok o filmoch, nie príliš ťažké."
> **Trubbo:** „Desať filmových, stredná obtiažnosť. Ideme?"
> **Hráč:** „Ideme."

- **Simpler UI:** the settings screens become optional; command hint chips can go.
- **How:** one recorded utterance, our current transcription, the small Claude model picks from a fixed list of actions (category, count, difficulty, language, start), a spoken confirmation in our voice. Not real-time.
- **Cost:** about $0.015 to $0.02 per round. **Poor signal:** setup needs a connection, as the quiz does today. Buttons remain.
- **Risks:** low. Small visible change; the answer turn stays as cluttered as it is.
- **Effort:** 2 phases (command routing in the cloud; setup conversation).

### Direction 2: The hosted answer turn (recommended)
Each question becomes a short conversation the app controls. The question is our recording. Then the mic is closed while the player thinks; when it opens, the player can say anything natural, and the host answers briefly.

> **Trubbo:** „Ktorá rieka preteká cez Budapešť?"
> *(ticho, mikrofón je zatvorený, beží čas na rozmyslenie)*
> **Hráč:** „Ešte raz otázku."
> **Trubbo:** *(zopakuje otázku)*
> **Hráč:** „Hm… Visla?"
> **Trubbo:** „Tesne vedľa. Visla tečie cez Varšavu, Budapešť delí Dunaj. Stále vedieš, štyri zo šiestich."

- **Simpler UI:** one screen state instead of many: the question, a clear "listening / not listening" signal, the score. The confirmation sheet, command hints and most error states fold into speech ("Nerozumel som, povedz to ešte raz").
- **How:** the server keeps the round as a fixed sequence of steps. One utterance goes to our current transcription; one small-model call decides what the player meant (answer, repeat, hint, skip, wait, something else) from a fixed list; the existing evaluation gives the verdict; the reaction is either a pre-written line (Direction 3) or one short sentence written by the small model and spoken in our voice. The model never sees the answer before the verdict and cannot change the score.
- **Cost:** $0.01 per round with pre-written reactions, up to $0.05 with live ones (or grant credits). **Latency target:** host starts speaking within 1.5 s of the player finishing, typically.
- **Poor signal:** same as today; on a timeout it falls back to the plain verdict clip and buttons.
- **Risks:** each extra spoken exchange adds delay; reactions can get repetitive or chatty; live Slovak recognition of short commands in a car is unmeasured. All three are measurable in the experiment.
- **Effort:** 3 phases (server step sequence and intent routing; the app's single-state turn; host lines and tuning). Direction 1's command routing falls out of phase one.

### Direction 3: The pre-written host
No live model at all. For every question we generate, offline and reviewed like questions are, a few short host lines: a reaction to a correct answer, to a near miss, to a wrong one, and a one-line fact. They are recorded once in our voice and cached.

> **Trubbo:** „Kto namaľoval Guernicu?"
> **Hráč:** „Picasso."
> **Trubbo:** „Presne tak. Picasso ju namaľoval približne za päť týždňov."

- **Simpler UI:** little change; the result screen can shrink because the host says it.
- **How:** content pipeline only (written on the subscription, checked, synthesised once: roughly 1.1 million characters for the current corpus, under 2% of the grant).
- **Cost:** as today. **Poor signal:** best of all options; lines can be fetched ahead with the question.
- **Risks:** it reacts to the verdict, not to what the player actually said; facts need the same source discipline as questions; by itself it does not fix commands.
- **Effort:** 1 to 2 phases. It is also the cheapest honest test of whether a reacting host makes the game more fun.

### Direction 4: The full live host
One continuous voice session runs the round. The host greets, proposes topics, reads questions, waits, reacts and chats, calling our server for each question, verdict and score.

> **Trubbo:** „Vitaj späť. Minule to bolo sedem z desiatich. Pokračujeme zemepisom, alebo niečo iné?"
> **Hráč:** „Niečo iné, prekvap ma."
> **Trubbo:** „Dobre, hudba deväťdesiatych rokov. Ktorá kapela vydala album Nevermind?"
> **Hráč:** „Počkaj, premýšľam." *(Trubbo mlčí)* „Nirvana?"
> **Trubbo:** „Nirvana, správne. A to bolo váhania."

- **Simpler UI:** the most: a start button, a mic state, a score.
- **How:** OpenAI's real-time models with manual turn control, or ElevenLabs Agents if its live recognition passes our car recordings. Tools: next question, judge this transcript, read score, check quota. Purchases stay on screen.
- **Cost:** $0.26 to $0.56 per round; needs a cap or its own price. **Poor signal:** worst; a dropped stream ends the conversation mid-question.
- **Risks:** thin language evidence, a different voice from the rest of the app (speech-to-speech), weak tool reliability, answer leaks unless the model is kept ignorant, phone-call audio mode in the car, vendor terms on minors, session resume after calls.
- **Effort:** 4 to 5 phases, plus consent, privacy and review work.

## 9. Recommendation and first experiment

**Go with Direction 2, using Direction 3's pre-written lines where they fit, and treat Direction 4 as a later, capped premium idea to revisit when independent Slovak and Czech evidence exists.** Reasons: it delivers the three things the founder asked for (the app leads, it waits while the player thinks, verdicts go through our flow); it replaces the unreliable command layer with the recognition that already works; it keeps cost within a few cents a round; it fails back to today's game; and everything learned (step sequence, intent routing, host lines, honest-verdict pattern) is reused if we ever move to a live host.

**Experiment, in three steps. Stop at the first failed gate.**

| Step | What | Measure | Pass | Spend |
|---|---|---|---|---|
| 0. Taste test, nothing built | The founder plays ten Slovak questions with a general assistant's voice mode, once at home and once in the car over Bluetooth | Notes: interruptions, wrong verdicts, language slips, audio switching | Not a gate; calibrates what a full live host feels like | $0 |
| 1. Replay test, no app change | Our recorded Slovak and Czech answers (issue #197 — voice replay corpus), plus about 30 newly recorded command phrases ("ešte raz", "neviem", "počkaj", "nápoveda", "ďalej") at home and in the car, run through today's transcription and two or three live-listening candidates | Share of answers heard correctly; share of commands understood correctly | Today's transcription understands at least 95% of commands at home and 85% in the car. A live candidate is "viable" only if within 3 points of today's on answers | up to $3 |
| 2. Flagged prototype of the hosted turn (Slovak and Czech, TestFlight only) | At least 20 rounds by the founder and three to five testers, each also playing the current flow | See below | All of the below | up to $7 and 150,000 grant credits |

Step 2 thresholds:
- Hands-free: at least 90% of questions completed without touching the screen, and better than the current flow in the same sessions.
- Honesty: wrong verdicts at most 2%; zero score changes obtained by talking; zero answer leaks in 50 scripted attempts.
- Background: at most one false reaction per round with other people talking nearby.
- Speed: host starts speaking within 1.5 s of the end of speech in half the turns, within 3 s in nine of ten.
- Cost: at most $0.02 cash per round.
- Fun: at least two thirds of players prefer the hosted round and say they would play it again.

Kill: if step 1 fails for commands in the car, keep buttons primary in the car and ship only Direction 3. If step 2 fails on preference, the idea is not a differentiator for our players; keep the command routing and drop the rest.

## 10. Questions only the founder can answer

1. Is the host a character (name, humour, opinions) or a neutral voice, and how much may it talk per question?
2. Is the hosted mode for everyone, or a subscriber benefit with a free taste?
3. Does voice become the default way to play, or stay one of three equal ways?
4. Microphone policy: open only in visible answer windows (recommended) or a continuously listening host?
5. Is a live AI host acceptable in the family section, given vendor terms on minors?
6. Which setting matters first for the experiment: home or car?
7. Is a paid, capped "live host" (Direction 4) worth keeping on the roadmap?
8. Approve the $10 cash cap and 150,000 grant credits for the experiment?

## 11. Where the evidence is thin

- Slovak, Czech and Ukrainian quality of every live voice option: vendor claims only. Our own first-hand data is one positive (current transcription) and one negative (ElevenLabs live recognition in the car), neither scored as a percentage.
- All latency figures: no vendor numbers; independent ones are for harder tasks than a quiz turn.
- Cost per round for token-priced models depends on my 7-minute assumption and on a third party's per-minute conversion.
- The grant's conversion to agent minutes: two ElevenLabs pages disagree.
- Prior art: no retention or revenue data for any agent-hosted game; Reddit and App Store reviews could not be searched.
- CarPlay eligibility for a quiz, the AI Act date, the national consent ages and the Hume shutdown were not confirmed from the primary text.

## Sources

Pricing and capabilities (all fetched 2026-11-21): [OpenAI pricing](https://developers.openai.com/api/docs/pricing) · [OpenAI real-time turn detection](https://developers.openai.com/api/docs/guides/realtime-vad) · [OpenAI real-time conversations](https://developers.openai.com/api/docs/guides/realtime-conversations) · [OpenAI data controls](https://developers.openai.com/api/docs/guides/your-data) · [Gemini Live capabilities](https://aistudio.google.com/docs/live-api/capabilities) · [Gemini pricing](https://aistudio.google.com/docs/pricing) · [Gemini API terms](https://aistudio.google.com/docs/terms) · [ElevenLabs agents pricing](https://elevenlabs.io/pricing/agents) · [ElevenLabs agents billing help](https://elevenlabs.io/docs/help-center/product/eleven-agents/how-much-does-eleven-agents-cost.md) · [ElevenLabs startup grant](https://elevenlabs.io/startup-grants) · [ElevenLabs conversation flow](https://elevenlabs.io/docs/eleven-agents/customization/conversation-flow.md) · [ElevenLabs skip turn](https://elevenlabs.io/docs/agents-platform/customization/tools/system-tools/skip-turn) · [ElevenLabs models](https://elevenlabs.io/docs/overview/models.md) · [ElevenLabs speech-to-text accuracy tiers](https://elevenlabs.io/docs/overview/capabilities/speech-to-text) · [ElevenLabs zero retention](https://elevenlabs.io/docs/eleven-api/resources/zero-retention-mode) · [LiveKit pricing](https://livekit.com/pricing) · [LiveKit turns](https://docs.livekit.io/agents/build/turns/) · [LiveKit turn detector languages](https://docs.livekit.io/agents/build/turns/turn-detector/) · [LiveKit noise cancellation](https://docs.livekit.io/transport/media/noise-cancellation.md) · [Pipecat turn strategies](https://docs.pipecat.ai/server/utilities/turn-management/user-turn-strategies) · [Pipecat mute strategies](https://docs.pipecat.ai/server/utilities/turn-management/user-mute-strategies) · [Pipecat Flows](https://docs.pipecat.ai/server/frameworks/flows/pipecat-flows) · [Pipecat Smart Turn languages](https://github.com/pipecat-ai/smart-turn) · [Claude pricing](https://platform.claude.com/docs/en/about-claude/pricing) · [Claude models](https://platform.claude.com/docs/en/models/overview) · [Deepgram pricing](https://deepgram.com/pricing) · [Vapi pricing](https://vapi.ai/pricing) · [Retell pricing](https://retellai.com/pricing)

Languages: [OpenAI language list as relayed by Microsoft](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/voice-live-language-support) · [OpenAI text-to-speech guide](https://developers.openai.com/api/docs/guides/text-to-speech) · [OpenAI forum, languages in the real-time API](https://community.openai.com/t/languages-in-realtime-api/980149) · [ElevenLabs Slovak page](https://elevenlabs.io/speech-to-text/slovak) · [Whisper paper](https://arxiv.org/abs/2212.04356) · [SloPal, Slovak speech corpus](https://arxiv.org/abs/2509.19270) · [Google forum, Czech and Ukrainian reports](https://discuss.ai.google.dev/t/gemini-2-5-flash-audio-not-reliable-the-official-demo-agent-dropping-dead-50-of-time-within-minutes/87016) · [Apple forum, recogniser locales](https://developer.apple.com/forums/thread/790108)

Benchmarks and guardrails: [tau-Voice](https://arxiv.org/html/2603.13686v1) · [Full-Duplex-Bench v3](https://arxiv.org/html/2604.04847v1) · [EVA-Bench](https://arxiv.org/html/2605.13841) · [OpenAI gpt-realtime announcement](https://openai.com/index/introducing-gpt-realtime/) · [OWASP, system prompt leakage](https://genai.owasp.org/llmrisk/llm07:2025-system-prompt-leakage/) · [Deepgram on prompt rules under pressure](https://deepgram.com/blog/ai-call-center-voice-agent-production-orchestration) · [DevRev on dropping speech-to-speech](https://devrev.ai/blog/experiments-with-voice-part1) · [AssemblyAI on code for mechanics](https://www.assemblyai.com/blog/voice-ai-prescription-agent) · [SignalWire, why voice AI fails](https://signalwire.com/blog/why-voice-ai-fails)

iOS, car and platform: [Apple voice chat mode](https://developer.apple.com/documentation/avfaudio/avaudiosession/mode-swift.struct/voicechat.md) · [Apple forum, CarPlay vehicle mic pauses radio](https://developer.apple.com/forums/thread/839130) · [Apple forum, Bluetooth switch stall](https://developer.apple.com/forums/thread/853278) · [CarPlay voice conversation entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.carplay-voice-based-conversation.md) · [9to5Mac on the CarPlay category](https://9to5mac.com/2026/02/18/ios-26-4-adds-support-for-voice-based-ai-apps-to-carplay/) · [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) · [Apple age ratings update](https://developer.apple.com/news/?id=ks775ehf) · [OpenAI under-18 API guidance](https://developers.openai.com/api/docs/guides/safety-checks/under-18-api-guidance) · [AI Act omnibus summary](https://www.whitecase.com/insight-alert/eu-ai-omnibus-enters-force-amending-ai-act)

Prior art: [Google conversational actions sunset](https://developers.google.com/assistant/ca-sunset) · [Voice app retention, 2017](https://fortune.com/2017/01/23/amazon-echo-google-home-voice-app/) · [Amazon on a daily question skill](https://developer.amazon.com/en-US/blogs/alexa/alexa-skills-kit/2022/03/Alexa-innovators-matchbox-question-of-the-day) · [Nielsen Norman Group on voice assistants](https://www.nngroup.com/articles/intelligent-assistant-usability/) · [Volley profile](https://builtin.com/articles/volley-fun-serious-business-1) · [Volley funding](https://www.pocketgamer.biz/voice-enabled-volley-secures-55-million-in-series-c-funding-round) · [Drivetime funding and Jeopardy!](https://voicebot.ai/2019/09/09/drivetime-adds-jeopardy-to-its-voice-game-lineup-for-commuters/) · [Volkswagen and ChatGPT](https://techcrunch.com/2024/01/08/volkswagen-is-bringing-chatgpt-into-its-cars-and-suvs) · [Tesla and Grok](https://spectrum.ieee.org/ai-enabled-vehicle-assistant) · [Assistant quiz gone wrong](https://0x4d44.substack.com/p/losing-the-plot) · [Voice mode repeating itself](https://community.openai.com/t/bug-in-advanced-voice-mode-it-repeats-the-same-response/1111396) · [Duolingo Max review](https://storylearning.com/duolingo-max-review) · [Voiced game characters study](https://arxiv.org/pdf/2510.25820) · [Response delays and fillers study](https://arxiv.org/html/2507.22352v1)
