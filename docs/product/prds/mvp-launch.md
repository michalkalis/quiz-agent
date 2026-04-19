# PRD: Hangs MVP Launch

**Author:** Michal + Claude | **Date:** 2026-03-18 | **Status:** Draft

## Problem Statement

Trivia apps are abundant, but none are designed for hands-free use. When you're on a road trip, cooking, or walking, existing apps require constant tapping, reading, and screen attention. Hangs solves this by making trivia fully voice-first: questions are read aloud, answers are spoken, and the entire quiz flow can be completed without touching the phone.

The MVP targets the founder and close circle (friends, family on road trips) with a path toward families with kids who want fun, shared entertainment during drives.

## Goals & Success Metrics

| Goal | Success Metric |
|------|---------------|
| Content quality | <5% wrong-answer reports per 1000 questions served |
| Quiz completion rate | >70% of started quizzes are completed (not abandoned) |
| Voice reliability | >85% of voice answers are correctly transcribed and evaluated |
| Content depth | 200+ verified questions across 10+ topics |
| App Store readiness | Approved on first submission, no rejections for HIG violations |

## Target Users

### MVP (Now)
- **Primary:** Founder + close circle (5-20 people). Adults who enjoy trivia during road trips, commutes, or casual downtime.
- **Context:** Hands-free while driving, but also usable visually when relaxing.

### Post-MVP
- **Families with kids:** Parents + children playing together. Requires kid-friendly categories (animals, cartoons, sports, geography) that are fun for both age groups.
- **Broader trivia enthusiasts:** People who enjoy trivia in any hands-free context.

## User Stories

| As a... | I want to... | So that... |
|---------|-------------|------------|
| Driver | Start a quiz and answer entirely by voice | I stay safe and entertained on long drives |
| Passenger | See questions on screen and tap answers | I can play visually when I'm not driving |
| Player | Choose difficulty, category, and language | The quiz matches my preferences |
| Player | Hear if I'm right/wrong with the correct answer | I learn something new each time |
| Player | See my streak and score at the end | I feel motivated to play again |
| Player | Skip questions I don't know by saying "skip" | I don't get stuck and the quiz keeps flowing |
| Returning player | Not get the same questions again | Every quiz feels fresh |
| Free user | Play a limited number of questions per day/week | I can try the app before paying |
| Paying user | Get unlimited questions | I can play as much as I want |

## Scope

### In Scope (MVP)

**Core Experience:**
- Voice-first quiz flow: TTS reads questions, Whisper transcribes answers, GPT-4 evaluates
- Auto-record after TTS finishes (hands-free loop)
- Barge-in (interrupt question reading to answer early)
- Voice commands: skip, repeat, score, help
- Multiple choice questions (tap or say "A"/"B"/"C"/"D")
- Image-based questions (silhouettes, blind maps, hint images)
- 10 language support for questions and TTS
- Answer explanations shown after each question

**Content:**
- 200+ verified questions across 10+ topics
- Difficulty levels: easy, medium, hard, random
- Category filtering (adults, general)
- Source attribution on questions

**Engagement:**
- Streak tracking (current + best)
- Completion stats (score, accuracy %)
- Auto-confirm answer after countdown
- Question history exclusion (no repeats)

**Quality:**
- Full VoiceOver accessibility
- Dynamic Type support
- Reduce Motion support
- Onboarding flow for first-time users
- Haptic feedback for correct/incorrect/recording

**Monetization (v1 — simple):**
- Free tier: N questions per day (or per week), resets on timer
- Paid tier: unlimited questions (one-time purchase or subscription TBD)
- Paywall shown when free limit reached, with countdown to reset

### Out of Scope (Future)

- Multiplayer (voice calls with friends/family)
- Kid-friendly categories and age-based content filtering
- CarPlay integration
- Offline mode
- User accounts and cross-device sync
- Leaderboards
- Custom question packs / user-generated content
- Social sharing
- Advanced analytics dashboard
- Android app

## Technical Approach

**Architecture:** FastAPI backend on Fly.io (3GB persistent volume) + native iOS SwiftUI app.

| Component | Technology | Role |
|-----------|-----------|------|
| Backend API | FastAPI + Python 3.11 | Session management, question retrieval, answer evaluation |
| Question DB | ChromaDB (embeddings) + SQLite (ratings) | Semantic search, diversity scoring, rating storage |
| AI Pipeline | OpenAI Whisper (STT) + GPT-4 (evaluation) + TTS | Voice transcription, answer scoring, speech synthesis |
| iOS App | Swift 6, SwiftUI, iOS 18+ | Native voice-first UI with MVVM + Service Layer |
| Hosting | Fly.io (single instance) | Backend API + persistent storage |

**Key Technical Decisions:**
- **In-memory sessions** — quizzes are short (10-15 min), no persistence needed
- **Semantic question retrieval** — RAG-first with ChromaDB embeddings for diversity
- **Client-side question history** — iOS tracks seen questions locally, sends exclusion list
- **Rate limiting** — slowapi with in-memory storage (single instance)
- **Structured logging** — JSON in production, human-readable in dev

**Monetization Implementation (simple approach):**
- Track question count per device (anonymous, no accounts)
- Backend enforces limit via session creation or question serving
- iOS shows paywall UI when limit response received
- StoreKit 2 for in-app purchase (or RevenueCat for subscription)

## Open Questions

- [ ] Free tier limit: how many questions per day? (10? 20? 50?)
- [ ] Monetization: one-time purchase vs subscription vs consumable credits?
- [ ] Price point for paid tier?
- [ ] Kid-friendly content: separate category or separate mode?
- [ ] TestFlight beta: how many external testers before public launch?
- [ ] App Store: which markets to launch in first?

## Timeline Estimate

| Phase | Description | Size |
|-------|-------------|------|
| 0 | Pre-launch hardening (logging, CORS, rate limiting) | S — done |
| 1 | Content pipeline (verify 222 questions, generate more) | M — in progress |
| 2 | Deploy hardened backend + import questions | S |
| 3 | Product documentation (PRD, user stories, research) | S — in progress |
| 4 | Free tier / paywall implementation (backend + iOS) | M |
| 5 | TestFlight beta with close circle | S |
| 6 | App Store submission | S |

**Ship when ready** — no hard deadline. Quality bar: content verified, voice flow reliable, accessibility complete, monetization functional.
