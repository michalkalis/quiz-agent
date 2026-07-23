# Trubbo — Design Brief for Google Stitch

> **How to use this file:** paste the whole thing into Google Stitch as the project brief, then paste ONE variant prompt (section 6) per generation run. Sections 1–4 describe *what the product does*. They deliberately do **not** describe what the screens should look like or how many there should be.

---

## 1. The product in one paragraph

Trubbo is a **voice-first trivia app for people who are driving**. The phone reads a question out loud, the person answers by speaking, the app judges the answer and reads the result back. The whole loop is meant to work with the phone in a cradle, eyes on the road, hands on the wheel. Touch is the fallback, not the primary input.

Single player today. Slovak and English content. iOS only.

## 2. Who uses it and where

- One person (or a car full of people) on a long drive, 20–90 minutes.
- Phone is mounted, roughly 60–80 cm from the eyes, often in bright daylight or full night.
- Road noise, music, passengers talking.
- The user may glance for **under a second** at a time. Anything that requires reading a paragraph while moving is a design failure.
- Also used stationary sometimes (waiting somewhere, sofa), so a non-driving mode is legitimate.

## 3. Feature list — this is the real input

Design whatever screens, flows, and interaction model best serve these capabilities. Nothing below implies a screen.

**Playing**
- Start a quiz session of N questions
- Question is spoken aloud; a person can interrupt it and start answering early ("barge-in")
- Answer by speaking freely (open answer) or by choosing one of multiple options
- Live transcript of what the app is hearing while the person speaks
- A confirmation step where the person can accept, edit, or re-record their answer; it auto-accepts after ~10 seconds if untouched
- Answer is judged; correct/incorrect plus a short explanation, spoken and shown
- Move to the next question; skip a question; repeat a question
- A per-question countdown / time pressure
- Streaks and running score across a session
- End-of-session summary: score, how it went, what to do next
- Some questions include an image; some include a source link the person can open later
- The quiz can be minimized and running in the background while the person does something else
- Spoken shortcuts for the main actions ("start", "ok", "next", "repeat", "skip")

**Content**
- Question categories and difficulty levels
- Ordering a custom question pack on a topic the user names; the pack is generated in the background, which takes time and needs a progress/waiting experience
- A library of packs the person owns
- History of past sessions

**Account & money**
- Sign in with Apple; also usable without an account
- Free tier: limited number of questions per month
- Paid subscription for unlimited play, plus one-off purchases of custom packs
- A place where the person sees how much of their free allowance is left, and is offered the upgrade

**Setup & preferences**
- First-run introduction that explains the voice loop and asks for microphone/speech permission
- Language, voice, speech rate, question count, difficulty, categories
- Choosing which audio output/input device to use (car speakers vs phone)
- A "hands-free / driving" mode versus a normal mode
- Sending feedback, including spoken feedback

## 4. Non-negotiable constraints

These come from the physical situation, not from taste. Every variant must respect them.

1. **Audio is the primary channel.** The screen supports the audio, never the other way around. A person must be able to complete a full question with the screen face-down.
2. **Glanceable.** Whatever is on screen must be readable in well under a second at arm's length, in sunlight. That means very large type for the one thing that matters right now, and near-nothing else competing with it.
3. **Big touch targets.** Anything tappable must be hittable by a thumb on a bumpy road without looking. Small icons, dense lists, and tiny toggles are unusable while driving.
4. **One decision at a time.** Never present two competing choices while the car is moving.
5. **State must be obvious from across the cabin.** "Is it talking, is it listening, is it thinking, did I get it right" should be answerable from peripheral vision alone — through colour, motion, or shape, not through reading.
6. **Silence is a state too.** The design has to show that the app is waiting for the person to speak, and how much time they have left.
7. Dark and light appearance both matter (night driving vs day driving), and the night version should not be a mere inversion.

## 5. What NOT to assume

The current app happens to have a home screen, a question screen, a result screen and a settings screen. **Treat that as an accident of history, not a requirement.**

You are explicitly invited to:
- collapse the whole thing into two screens, or one continuously morphing surface
- make the question and the result the same surface that transforms
- drop the settings screen entirely in favour of spoken setup or a progressive one
- invent a non-list-based, non-card-based visual language
- design primarily for peripheral vision — huge colour fields, a single glyph, motion as the main signal
- rethink where scoring, streaks, and monetisation appear, or whether they appear at all during play
- treat the phone screen as an instrument cluster, an ambient light, a companion character, or something we haven't thought of

The only things you may not change are the capability list in section 3 and the constraints in section 4.

## 6. Variant prompts — run these one at a time

Generate five distinct directions. Do not blend them; each should be a coherent, committed point of view, and they should be visibly different from each other.

### Variant 1 — Free rethink, no screen assumptions
> Ignore any conventional app structure. Design the smallest set of screens that delivers the feature list, optimising purely for someone driving. Decide yourself how many screens exist and what each one is. Justify the flow in one short paragraph, then design it.

### Variant 2 — Ambient instrument
> Design it as a car instrument rather than an app. Peripheral-vision first: colour fields, a single dominant element, motion and shape carry the state. Minimal text. Assume the person mostly listens and only glances.

### Variant 3 — Conversational companion
> Design it as a conversation with a character or presence rather than a series of forms. The interface is the dialogue. Explore what score, streaks, settings and buying a pack look like when everything is a conversational turn.

### Variant 4 — Bold editorial, expressive
> Keep a recognisable app structure but push the visual language hard: oversized condensed display type, strong colour, playful energy, game-show confidence. Prioritise excitement and personality while staying glanceable.

### Variant 5 — Constrained to the current design system
> Stay close to the existing product. Refine rather than reinvent: keep a home, a question, a result and a settings surface, and use the tokens below. Improve hierarchy, glanceability and the sense of state, but keep it recognisably the same app.

**Existing design tokens (for variant 5 only):**

| Token | Light | Dark |
|---|---|---|
| Page background | `#F6F7F9` | `#161616` |
| Card surface | `#FFFFFF` | `#1F1F22` |
| Primary text | `#0E1A2B` | `#F4F4F4` |
| Secondary text | `#6B7280` | `#9CA3AF` |
| Brand accent / primary action | `#FF3D8F` | `#FF3D8F` |
| Secondary accent (purple) | `#8B5CF6` | `#8B5CF6` |
| Info accent (blue) | `#0A84FF` | `#0A84FF` |
| Success | `#16A34A` | `#4ADE80` |
| Error | `#FF4444` | `#FF4444` |

Style: cream/editorial light surfaces, soft rounded cards with gentle shadows, a very large condensed display typeface for the single hero word or number on each screen, generous whitespace, one pink primary action per screen. Hero display text must never wrap to a second line.

## 7. Deliverable per variant

For each variant, show whatever screens that variant's own logic requires (it may be two, it may be six) covering at minimum: starting a session, answering a question by voice, seeing the outcome of an answer, and changing preferences. Include both a light and a dark treatment of the main playing surface.
