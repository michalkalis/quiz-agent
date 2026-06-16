# Quiz Agent Mobile App - Product Specification

**Version:** 1.0
**Target Platform:** iOS (Mobile)
**Date:** December 2025
**Status:** MVP Design Phase

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Product Vision](#product-vision)
3. [User Personas](#user-personas)
4. [App Ecosystem](#app-ecosystem)
5. [Core Features](#core-features)
6. [User Flows](#user-flows)
7. [Screen Structure](#screen-structure)
8. [Feature Specifications](#feature-specifications)
9. [Voice Interface](#voice-interface)
10. [Content & Question Types](#content--question-types)
11. [Personalization & AI](#personalization--ai)
12. [Design Guidelines](#design-guidelines)
13. [Success Metrics](#success-metrics)

---

## Executive Summary

**Quiz Agent** is an AI-powered mobile quiz application that brings pub quiz experiences to iOS devices with intelligent voice interaction and personalized question selection.

### What Makes It Different

- **Conversational AI**: Users can answer naturally - "Paris, but too easy" automatically records the answer, adjusts difficulty, and captures feedback
- **Voice-First Design**: Powered by OpenAI Whisper for natural speech interaction
- **Smart Question Selection**: RAG-based (Retrieval-Augmented Generation) system that understands semantic preferences
- **Quality-Driven**: User ratings continuously improve question quality
- **Flexible Play Modes**: Text or voice input, casual or timed, solo or competitive (future)

### Key Stats (Target)

- **Question Library**: 500+ curated questions at launch
- **Categories**: General, Adults, Music, Movies, Science, Thematic (Harry Potter, 90s, etc.)
- **Question Types**: Text, Multiple Choice, Audio (future), Image (future), Video (future)
- **Session Length**: 10 questions per quiz (configurable)
- **Response Time**: < 2 seconds for voice transcription

---

## Product Vision

### Mission Statement

> "Transform trivia into an intelligent conversation where every player feels heard, challenged appropriately, and continuously engaged."

### Core Values

1. **Intelligent Adaptation**: Questions adapt to player skill and preferences in real-time
2. **Natural Interaction**: Speak or type as naturally as you would in a real pub quiz
3. **Quality First**: Every question is curated, tested, and continuously improved through user feedback
4. **Inclusive Fun**: Questions span difficulty levels and interests for everyone

### Success Definition

A successful session means:
- Player completes the quiz without frustration
- Difficulty feels "just right" (not too easy, not too hard)
- Player wants to play again immediately
- Player rates 80%+ of questions positively

---

## User Personas

### Primary Persona: "Social Sam"

**Demographics:**
- Age: 25-40
- Occupation: Professional, social activities enthusiast
- Tech-savvy: High

**Goals:**
- Practice for real pub quiz nights
- Fill commute time with engaging content
- Learn interesting facts to share with friends
- Challenge themselves mentally

**Pain Points:**
- Most quiz apps feel robotic and rigid
- Gets bored with questions that are too easy or impossible
- Dislikes typing long answers on mobile
- Wants variety, not the same questions recycled

**Quote:** *"I want a quiz that feels like a real quizmaster is talking to me, not a multiple-choice test."*

### Secondary Persona: "Casual Casey"

**Demographics:**
- Age: 18-65
- Occupation: Varied
- Tech-savvy: Medium

**Goals:**
- Kill time during breaks
- Light mental stimulation
- Low-commitment entertainment
- Discover new topics

**Pain Points:**
- Many quiz apps are too serious or competitive
- Doesn't want to commit to long sessions
- Prefers simple, intuitive interfaces
- Gets demotivated by harsh penalties for wrong answers

**Quote:** *"I just want 5 minutes of fun trivia without feeling like I'm taking a test."*

### Tertiary Persona: "Thematic Tina"

**Demographics:**
- Age: 20-45
- Occupation: Varied, strong fandom interests
- Tech-savvy: High

**Goals:**
- Deep dive into favorite topics (Harry Potter, Music, 90s, etc.)
- Test knowledge in niche areas
- Share scores with like-minded communities
- Unlock all questions in favorite categories

**Pain Points:**
- General trivia apps lack depth in specific topics
- Can't easily filter for preferred themes
- Limited content in niche categories
- No progression system for topic mastery

**Quote:** *"I want a Harry Potter quiz that challenges even superfans, not just casual movie watchers."*

---

## App Ecosystem

The Quiz Agent ecosystem consists of two separate applications serving different roles:

### System Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         MOBILE APPS                         │
│                                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐    │
│  │              │  │              │  │              │    │
│  │   iOS App    │  │  Terminal    │  │  Web App     │    │
│  │   (Primary)  │  │  Interface   │  │  (Future)    │    │
│  │              │  │              │  │              │    │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘    │
│         │                 │                  │             │
└─────────┼─────────────────┼──────────────────┼─────────────┘
          │                 │                  │
          ▼                 ▼                  ▼
    ┌──────────────────────────────────────────────────┐
    │         QUIZ AGENT API (Backend)                 │
    │                                                  │
    │  • Session Management                            │
    │  • AI Input Parser (Natural Language)            │
    │  • Question Retrieval (RAG-based)                │
    │  • Answer Evaluation (Smart Scoring)             │
    │  • Voice Transcription (Whisper API)             │
    │  • Rating System                                 │
    │                                                  │
    └───────────────────┬──────────────────────────────┘
                        │
                        ▼
    ┌──────────────────────────────────────────────────┐
    │              SHARED STORAGE                      │
    │                                                  │
    │  ┌──────────────┐        ┌──────────────┐      │
    │  │  ChromaDB    │        │ PostgreSQL/  │      │
    │  │              │        │   SQLite     │      │
    │  │ • Questions  │        │ • Sessions   │      │
    │  │ • Embeddings │        │ • Ratings    │      │
    │  │ • Metadata   │        │ • User Data  │      │
    │  └──────────────┘        └──────────────┘      │
    │                                                  │
    └──────────────────────────────────────────────────┘
                        ▲
                        │
    ┌──────────────────────────────────────────────────┐
    │       QUESTION GENERATOR (Admin Tool)            │
    │                                                  │
    │  • Batch Question Generation                     │
    │  • ChatGPT Integration                           │
    │  • Quality Validation                            │
    │  • Duplicate Detection                           │
    │  • Manual Review & Approval                      │
    │                                                  │
    └──────────────────────────────────────────────────┘
```

### User-Facing App: iOS Quiz Agent

**Purpose:** Consumer-facing quiz experience

**Key Characteristics:**
- Clean, minimalist design focused on content
- Voice-first interaction model
- Intelligent question adaptation
- Instant feedback and source links
- Session persistence (30-minute TTL)

### Admin Tool: Question Generator

**Purpose:** Internal content management (not visible to end users)

**Function:**
- Content creators generate questions via ChatGPT
- Quality review and approval workflow
- Duplicate detection prevents redundant questions
- Continuous content expansion

**Impact on Mobile App:**
- Ensures high-quality question library
- Enables thematic quiz expansions
- Maintains content freshness
- Filters out low-rated questions

---

## Core Features

### 1. Smart Quiz Sessions

**Description:** AI-powered quiz sessions that adapt to user performance and preferences

**User Value:**
- Questions feel personally curated
- Difficulty adjusts automatically
- No repeated questions within session
- Can pause and resume within 30 minutes

**Technical Implementation:**
- Session state stored server-side
- 10 questions per quiz (configurable)
- Session ID-based state management
- Auto-expire after 30 minutes of inactivity

### 2. Natural Language Input

**Description:** Users can combine answers with feedback in natural language

**User Value:**
- Speak or type naturally: *"Paris, but too easy"*
- No rigid command structures
- System understands intent, not just keywords
- Feels like conversation, not a form

**Examples:**
- *"London, no more geography"* → Answer: London, Exclude: Geography
- *"Skip this, make it harder"* → Skip question, Increase difficulty
- *"Shakespeare? This is a great question!"* → Answer: Shakespeare, Rating: 5

**Technical Implementation:**
- LLM-based input parser
- Multi-intent classification
- Extracts: answer, rating, feedback, commands, preferences

### 3. Voice Interaction (Whisper)

**Description:** High-accuracy voice transcription via OpenAI Whisper

**User Value:**
- Hands-free quiz experience
- Perfect for commutes, workouts, cooking
- Feels like real pub quiz with verbal answers
- Faster than typing

**Technical Flow:**
1. User taps microphone button
2. Records audio (WAV/M4A/MP3)
3. Uploads to backend
4. Whisper API transcribes (< 2 sec)
5. Parsed like text input
6. Response displayed and optionally spoken

### 4. Intelligent Question Retrieval (RAG)

**Description:** Semantic search-based question selection

**User Value:**
- *"I like science"* finds Physics, Chemistry, Biology, Astronomy questions
- *"Harry Potter quiz"* retrieves thematic questions without exact tags
- Avoids duplicates and repetition
- Balances variety and relevance

**Traditional Database vs RAG:**

| Capability | Traditional DB | RAG (Our Approach) |
|------------|----------------|-------------------|
| **Exact Match** | ✅ Fast | ✅ Fast + semantic |
| **Semantic Search** | ❌ Keyword only | ✅ Understands meaning |
| **"Space questions"** | Only "Space" tag | Astronomy, NASA, planets, cosmos |
| **Duplicate Detection** | ❌ Exact text only | ✅ Similar meaning detected |
| **Theme Discovery** | ❌ Manual tagging | ✅ "Harry Potter" finds related content |

### 5. Smart Answer Evaluation

**Description:** Nuanced scoring beyond exact matches

**User Value:**
- Partial credit for close answers
- Accepts common variations
- Understands typos and abbreviations
- Fair scoring, not robotic

**Scoring System:**
- **Correct** (+1.0 point): Answer is essentially correct
- **Partially Correct** (+0.5 points): Main idea right, minor errors
- **Partially Incorrect** (+0.25 points): Some relevant elements
- **Incorrect** (+0 points): Wrong answer
- **Skipped** (+0 points): User chose to skip

**Examples:**
- Question: "What year did the Berlin Wall fall?"
- Correct: "1989"
- Partially Correct: "1990" (close, common misconception)
- Incorrect: "1975"

### 6. Source Verification

**Description:** Every question includes source links for fact-checking

**User Value:**
- Learn more about the answer
- Build trust in question accuracy
- Educational value beyond trivia
- Discover related topics

**Display:**
- Wikipedia link (primary)
- Relevant article snippet
- Appears after answer is evaluated

### 7. Quality Feedback System

**Description:** Users rate questions to improve content quality

**User Value:**
- Voice matters - bad questions get filtered
- Influence question selection algorithm
- Optional feedback text
- Non-intrusive (combined with answers)

**Rating Scale:**
- **1 star**: Thumbs down (bad question)
- **5 stars**: Thumbs up (great question)
- Future: 2-4 stars for nuanced feedback

**Impact:**
- Questions with avg rating < 2.5 are flagged for review
- Higher-rated questions prioritized in selection
- Low-rated questions may be removed or improved

### 8. Difficulty Adjustment

**Description:** Real-time difficulty control

**User Value:**
- Say "harder" or "easier" anytime
- System remembers preference
- Can adjust mid-quiz
- Never locked into wrong difficulty

**Levels:**
- **Easy**: Broad knowledge, common facts
- **Medium**: Moderate difficulty, some specificity
- **Hard**: Deep knowledge, obscure facts, expert-level

---

## User Flows

### Flow 1: First-Time User - Complete Quiz

```
1. Open App
   ↓
2. Welcome Screen
   • "Welcome to Quiz Agent"
   • Brief explanation (voice-enabled, adaptive difficulty)
   • [Start Quiz] button
   ↓
3. Session Configuration (Optional - Skip for Quick Start)
   • Number of questions (default: 10)
   • Starting difficulty (default: Medium)
   • Preferred categories (default: General)
   • [Begin] button
   ↓
4. Question 1 Displayed
   • Question text
   • Topic badge (e.g., "Geography")
   • Difficulty indicator
   • Input method toggle (Text / Voice)
   • Score display (0.0/1)
   ↓
5. User Answers

   OPTION A - Text Input:
   • Types: "Paris"
   • [Submit] button

   OPTION B - Voice Input:
   • Taps microphone icon
   • Speaks: "Paris"
   • System transcribes
   • Automatic submission
   ↓
6. Feedback Displayed
   • Result: "Correct!"
   • Correct answer confirmation
   • Source link with snippet
   • Score updated (1.0/1)
   • [Next Question] button (auto-advances after 3 sec)
   ↓
7. Question 2-10
   • Repeat steps 4-6
   • User can say "harder" to adjust difficulty
   • User can say "skip" to skip question
   • Score accumulates
   ↓
8. Quiz Complete
   • Final score displayed (e.g., 7.5/10)
   • Percentage score
   • Performance summary
   • [Play Again] button
   • [Change Settings] button
```

### Flow 2: Voice-First User - Natural Language Interaction

```
1. Open App → Start Quiz
   ↓
2. Question 1: "What is the capital of France?"
   ↓
3. User Taps Microphone
   • Records audio
   • Visual feedback (pulsing animation)
   ↓
4. User Speaks: "Paris, but this is way too easy"
   ↓
5. System Processes
   • Transcribes: "Paris, but this is way too easy"
   • Parses intents:
     - Answer: "Paris"
     - Rating: 1 (negative sentiment)
     - Feedback: "too easy"
     - Implied action: Increase difficulty
   ↓
6. Feedback Displayed
   • "Correct!"
   • Source link
   • Subtle notification: "Difficulty adjusted"
   • Score: 1.0/1
   • Next question is now Medium → Hard
   ↓
7. Question 2 (Now Harder)
   • "What is the Schwarzschild radius formula?"
   • User continues with voice or switches to text
```

### Flow 3: Returning User - Resume Session

```
1. User Opens App (within 30 min of last session)
   ↓
2. App Detects Active Session
   • Modal: "Resume your quiz?"
   • Current progress: 4/10 questions
   • Score: 3.0/4
   • [Resume] or [Start New]
   ↓
3. User Selects [Resume]
   ↓
4. Question 5 Displayed
   • Continues from where they left off
   • All preferences preserved
```

### Flow 4: Thematic Quiz Selection

```
1. Home Screen
   ↓
2. User Taps "Browse Categories"
   ↓
3. Category Grid Displayed
   • General Knowledge
   • Science & Nature
   • History
   • Geography
   • Music
   • Movies & TV
   • Sports (future)
   • Thematic Packs:
     - Harry Potter
     - 90s Nostalgia
     - Science Fiction
   ↓
4. User Selects "Harry Potter"
   ↓
5. Confirmation Screen
   • "Harry Potter Trivia"
   • 10 questions
   • Difficulty: Medium
   • [Start Quiz] button
   ↓
6. Quiz Begins with Harry Potter Questions
   • Questions semantically related to Harry Potter
   • RAG system finds relevant content
```

---

## Screen Structure

### Home Screen

**Purpose:** Quiz start point and navigation hub

**Elements:**
- App logo/branding
- Current streak (days played consecutively)
- [Start Quiz] button (primary CTA)
- [Browse Categories] button
- [Settings] icon (top-right)
- [Statistics] icon (top-right)
- Active session indicator (if session exists)

**States:**
- No active session: Clean, focused on [Start Quiz]
- Active session: Shows [Resume] and [Start New] options
- First time: Shows brief onboarding overlay

### Question Screen

**Purpose:** Core quiz interaction

**Layout:**
```
┌──────────────────────────────────────┐
│  [←] Back    [⚙️] Settings  Q 3/10    │
├──────────────────────────────────────┤
│                                      │
│  Topic Badge: "History"              │
│  Difficulty: ⭐⭐ (Medium)             │
│                                      │
│  ┌────────────────────────────────┐ │
│  │                                │ │
│  │  "In what year did the         │ │
│  │   Berlin Wall fall?"           │ │
│  │                                │ │
│  └────────────────────────────────┘ │
│                                      │
│  Score: 2.5/3                        │
│                                      │
│  ┌────────────────────────────────┐ │
│  │  Type your answer here...      │ │
│  │                                │ │
│  └────────────────────────────────┘ │
│                                      │
│  [🎤 Voice]       [Submit] button    │
│                                      │
│  [Skip this question]                │
│                                      │
└──────────────────────────────────────┘
```

**Interaction States:**
- **Idle**: Waiting for input
- **Voice Recording**: Microphone active, pulsing animation
- **Processing**: Loading spinner during transcription/evaluation
- **Feedback**: Shows result, source link, score update

### Multiple Choice Variant

**Layout:**
```
┌──────────────────────────────────────┐
│  [←] Back    [⚙️] Settings  Q 5/10    │
├──────────────────────────────────────┤
│  Topic: "Geography"  ⭐⭐⭐ (Hard)      │
│                                      │
│  "Which country has the longest      │
│   coastline in the world?"           │
│                                      │
│  Score: 3.5/5                        │
│                                      │
│  ┌────────────────────────────────┐ │
│  │  A. Australia                  │ │
│  └────────────────────────────────┘ │
│  ┌────────────────────────────────┐ │
│  │  B. Canada                     │ │
│  └────────────────────────────────┘ │
│  ┌────────────────────────────────┐ │
│  │  C. Russia                     │ │
│  └────────────────────────────────┘ │
│  ┌────────────────────────────────┐ │
│  │  D. Norway                     │ │
│  └────────────────────────────────┘ │
│                                      │
│  [🎤] "Say A, B, C, or D"            │
│  [Skip this question]                │
│                                      │
└──────────────────────────────────────┘
```

### Feedback Screen (After Answer)

**Layout:**
```
┌──────────────────────────────────────┐
│  Result Screen                       │
├──────────────────────────────────────┤
│                                      │
│  ✅ Correct!                          │
│                                      │
│  Your Answer: "1989"                 │
│  Correct Answer: "1989"              │
│                                      │
│  ┌────────────────────────────────┐ │
│  │  📚 Source                      │ │
│  │                                │ │
│  │  The Berlin Wall fell on       │ │
│  │  November 9, 1989...           │ │
│  │                                │ │
│  │  [Read more →]                 │ │
│  └────────────────────────────────┘ │
│                                      │
│  Score: 5.0/5  (Current: Medium)    │
│                                      │
│  How was this question?             │
│  👍 Good    👎 Bad                   │
│                                      │
│  [Next Question →]                  │
│                                      │
└──────────────────────────────────────┘
```

**Result Types:**
- ✅ **Correct**: Green checkmark, celebratory animation
- ⚠️ **Partially Correct**: Yellow warning, shows correct answer
- ❌ **Incorrect**: Red X, educational tone, source emphasized
- ⏭️ **Skipped**: Neutral, shows correct answer without score change

### Quiz Complete Screen

**Layout:**
```
┌──────────────────────────────────────┐
│  Quiz Complete!  🎉                  │
├──────────────────────────────────────┤
│                                      │
│  Final Score                         │
│  ┌────────────────────────────────┐ │
│  │                                │ │
│  │       8.5 / 10                 │ │
│  │                                │ │
│  │       85%                      │ │
│  │                                │ │
│  └────────────────────────────────┘ │
│                                      │
│  Performance Breakdown:              │
│  • Correct: 7                        │
│  • Partially Correct: 3              │
│  • Incorrect: 0                      │
│  • Skipped: 0                        │
│                                      │
│  Difficulty: Medium                  │
│  Category: General Knowledge         │
│                                      │
│  ┌────────────────────────────────┐ │
│  │  [🔄 Play Again]                │ │
│  └────────────────────────────────┘ │
│                                      │
│  [📊 View Statistics]                │
│  [⚙️ Change Settings]                 │
│                                      │
└──────────────────────────────────────┘
```

### Settings Screen

**Purpose:** Configure quiz preferences

**Sections:**

1. **Quiz Configuration**
   - Number of questions: Slider (5-20)
   - Starting difficulty: Easy | Medium | Hard
   - Auto-advance: Toggle (auto-show next question)

2. **Categories**
   - Preferred categories: Multi-select checkboxes
   - Excluded categories: Multi-select checkboxes

3. **Topics**
   - Preferred topics: Multi-select tags
   - Excluded topics: Multi-select tags

4. **Voice Settings**
   - Enable voice input: Toggle
   - Voice feedback (TTS): Toggle (future)
   - Microphone permission status

5. **Display**
   - Theme: Light | Dark | Auto
   - Font size: Small | Medium | Large

6. **About**
   - App version
   - Privacy policy
   - Terms of service

### Category Browser Screen

**Purpose:** Explore thematic quiz options

**Layout:**
```
┌──────────────────────────────────────┐
│  [←] Categories                      │
├──────────────────────────────────────┤
│                                      │
│  Popular Categories                  │
│                                      │
│  ┌─────────┐  ┌─────────┐           │
│  │ General │  │ Science │           │
│  │   🌍     │  │   🔬     │           │
│  │ 250 Qs  │  │ 180 Qs  │           │
│  └─────────┘  └─────────┘           │
│                                      │
│  ┌─────────┐  ┌─────────┐           │
│  │ History │  │  Music  │           │
│  │   📚     │  │   🎵     │           │
│  │ 200 Qs  │  │ 150 Qs  │           │
│  └─────────┘  └─────────┘           │
│                                      │
│  Thematic Packs                      │
│                                      │
│  ┌─────────┐  ┌─────────┐           │
│  │  Harry  │  │   90s   │           │
│  │ Potter  │  │Nostalgia│           │
│  │   ⚡     │  │   📼     │           │
│  │  75 Qs  │  │  60 Qs  │           │
│  └─────────┘  └─────────┘           │
│                                      │
└──────────────────────────────────────┘
```

**Interactions:**
- Tap category card → Quiz config screen
- Shows question count per category
- Visual icons for recognition

### Statistics Screen

**Purpose:** Track progress and performance

**Sections:**

1. **Overview**
   - Total quizzes played
   - Total questions answered
   - Overall accuracy %
   - Current streak (days)

2. **Performance by Difficulty**
   - Easy: X% accuracy
   - Medium: X% accuracy
   - Hard: X% accuracy

3. **Favorite Categories**
   - Top 3 played categories
   - Accuracy per category

4. **Recent Activity**
   - Last 5 quiz results
   - Date, score, difficulty

---

## Feature Specifications

### 1. Session Management

**Technical Flow:**
1. User starts quiz → API creates session
2. Session ID stored locally on device
3. Each interaction updates session state server-side
4. Session expires after 30 minutes of inactivity
5. User can resume if session is active

**Session State (Internal):**
- Session ID
- Question number (e.g., 3/10)
- Score (e.g., 2.5/3)
- Current difficulty
- Preferred/excluded categories
- Preferred/excluded topics
- Asked question IDs (prevent repeats)
- Current question data
- Phase (idle, asking, awaiting_answer, finished)

**User-Visible:**
- Progress indicator (3/10)
- Current score
- Difficulty level

### 2. Natural Language Input Parser

**Purpose:** Understand combined intents in user input

**Examples:**

| User Input | Parsed Output |
|------------|---------------|
| "Paris" | Answer: Paris |
| "Paris, but too easy" | Answer: Paris, Rating: 1, Feedback: "too easy", Action: Increase difficulty |
| "London, no more geography" | Answer: London, Excluded Topics: ["geography"] |
| "Skip this one" | Action: Skip question |
| "Make it harder" | Action: Increase difficulty |
| "Shakespeare? Great question!" | Answer: Shakespeare, Rating: 5 |

**Intents Supported:**
- **Answer**: Primary answer text
- **Rating**: 1-5 stars (inferred from sentiment)
- **Feedback**: Text feedback on question quality
- **Commands**: skip, harder, easier, quit
- **Preferences**: Exclude/include topics or categories

**User Benefit:**
- No need to learn commands
- Speak naturally as in conversation
- Faster interaction (one input vs multiple actions)

### 3. Voice Transcription

**Flow:**
1. User taps microphone button
2. App requests microphone permission (first time)
3. Recording starts (visual feedback: pulsing animation)
4. User speaks answer
5. User taps stop or auto-stops after silence
6. Audio uploaded to backend (WAV/M4A/MP3)
7. Whisper API transcribes (< 2 sec target)
8. Transcription sent to input parser
9. Result displayed on screen

**Supported Audio Formats:**
- WAV (uncompressed)
- M4A (iOS native)
- MP3 (compressed)

**Error Handling:**
- No microphone permission → Show permission prompt
- Transcription failed → Retry button or switch to text input
- Network error → Cache audio, retry when online

### 4. Smart Scoring System

**Evaluation Logic:**

```
Step 1: Normalize text (lowercase, remove punctuation, trim)
Step 2: Check exact match with correct answer
Step 3: Check exact match with alternative answers
Step 4: If no match, use LLM for nuanced evaluation
Step 5: Assign score category
```

**Score Categories:**

| Category | Points | Criteria | Example |
|----------|--------|----------|---------|
| Correct | +1.0 | Essentially correct | Q: "Capital of France?" A: "Paris" |
| Partially Correct | +0.5 | Main idea right, minor error | Q: "Year Berlin Wall fell?" A: "1990" (correct: 1989) |
| Partially Incorrect | +0.25 | Some relevant info, mostly wrong | Q: "Playwright of Hamlet?" A: "English writer" |
| Incorrect | +0.0 | Wrong | Q: "Capital of France?" A: "London" |
| Skipped | +0.0 | User skipped | - |

**Multiple Choice:**
- Check if user's answer (A/B/C/D) matches correct_answer
- Binary: Correct (+1.0) or Incorrect (+0.0)
- No partial credit for multiple choice

### 5. Question Retrieval Algorithm

**RAG-Based Retrieval:**

```
Step 1: Build semantic query from preferences
  - Example: User prefers "science" → Query: "science questions"

Step 2: Apply metadata filters
  - Difficulty: Match current difficulty level
  - Type: "text" or "text_multichoice"
  - Category: Include preferred, exclude unwanted
  - Topics: Exclude unwanted topics
  - ID: Exclude already-asked question IDs

Step 3: Query ChromaDB
  - Semantic search with embeddings
  - Returns top 10 matches

Step 4: Select diverse question
  - Avoid similar topics in consecutive questions
  - Balance variety and relevance

Step 5: Update session
  - Add question ID to asked list
  - Return question to user
```

**User Benefit:**
- *"I like science"* finds all science-related content (Physics, Chemistry, Biology, Astronomy)
- *"Harry Potter quiz"* retrieves thematic questions without exact tags
- Semantic understanding, not just keyword matching

### 6. Rating System

**User Interaction:**

**Option 1: Implicit Rating (Natural Language)**
- User says: *"Too easy"* → Rating: 1
- User says: *"Great question!"* → Rating: 5

**Option 2: Explicit Rating (Feedback Screen)**
- Thumbs up 👍 → Rating: 5
- Thumbs down 👎 → Rating: 1
- Optional text feedback

**Backend Processing:**
1. Store rating in SQL database
2. Update question's user_ratings dict in ChromaDB
3. Calculate average rating
4. Flag questions with avg < 2.5 for admin review
5. Prioritize high-rated questions in retrieval

**Impact on Content:**
- Questions rated < 2.5 average → Flagged for review or removal
- Questions rated > 4.0 average → Prioritized in selection
- Continuous quality improvement loop

### 7. Difficulty Adjustment

**Levels:**

| Level | Description | Example Questions |
|-------|-------------|-------------------|
| Easy | Common knowledge, broad facts | "What is the capital of France?" |
| Medium | Moderate difficulty, some specificity | "In what year did the Berlin Wall fall?" |
| Hard | Deep knowledge, obscure facts | "What is the Schwarzschild radius formula?" |

**Adjustment Triggers:**

1. **User Command:**
   - Says "harder" → Increase difficulty
   - Says "easier" → Decrease difficulty

2. **Implicit (Future):**
   - Consecutive correct answers → Suggest harder
   - Consecutive incorrect → Suggest easier

**State Management:**
- Difficulty stored in session
- Applies to next question
- User can change anytime

---

## Voice Interface

### Voice Interaction Model

**Primary Use Cases:**
1. Answer questions hands-free
2. Adjust difficulty mid-quiz
3. Skip questions verbally
4. Provide feedback naturally

**Design Principles:**
- **Always Available**: Microphone button visible on every question screen
- **Visual Feedback**: Clear recording state (pulsing animation)
- **Error Tolerance**: Retry options if transcription fails
- **Hybrid Model**: Users can switch between voice and text anytime

### Voice Commands

**Supported Commands:**

| User Says | System Action |
|-----------|---------------|
| "Paris" | Submit answer: Paris |
| "Skip" / "Pass" / "Next" | Skip current question |
| "Harder" / "Make it harder" | Increase difficulty to next level |
| "Easier" / "Make it easier" | Decrease difficulty to previous level |
| "A" / "B" / "C" / "D" | Select multiple choice option |
| "Quit" / "Stop" / "Exit" | End quiz session |

**Combined Commands:**
- "Paris, but too easy" → Answer + Feedback + Difficulty adjustment
- "London, great question" → Answer + Positive rating
- "Skip this one, make it harder" → Skip + Difficulty increase

### Voice UX Considerations

**Microphone Permission:**
- First-time use: Request permission with clear explanation
- Permission denied: Show settings link to enable
- Permission granted: Remember for future sessions

**Recording State:**
- **Idle**: Microphone icon, gray
- **Recording**: Microphone icon, pulsing red animation
- **Processing**: Loading spinner, "Transcribing..."
- **Complete**: Transcription text shown briefly before evaluation

**Error Handling:**
- **Transcription Failed**: "Couldn't understand. Try again or type your answer."
- **Network Error**: "Connection issue. Your answer is saved, retrying..."
- **Silent Recording**: "No speech detected. Please try again."

**Accessibility:**
- Large, tappable microphone button (min 44x44pt)
- Clear visual feedback for hearing-impaired users
- Option to disable voice entirely in settings

---

## Content & Question Types

### Question Types (MVP)

#### 1. Text Questions

**Description:** Open-ended text answer

**Example:**
```
Question: "What is the capital of France?"
Type: text
Correct Answer: "Paris"
Alternative Answers: ["paris", "paris france"]
Topic: Geography
Category: general
Difficulty: easy
```

**UI Display:**
- Question text
- Text input field
- Voice input option
- Submit button

#### 2. Multiple Choice (text_multichoice)

**Description:** Select from 4 options (A, B, C, D)

**Example:**
```
Question: "Which country has the longest coastline?"
Type: text_multichoice
Possible Answers:
  A: Australia
  B: Canada
  C: Russia
  D: Norway
Correct Answer: B
Topic: Geography
Category: adults
Difficulty: hard
```

**UI Display:**
- Question text
- 4 tappable option cards
- Voice input: Say "A", "B", "C", or "D"
- Visual selection state

### Question Types (Future)

#### 3. Audio Questions (Post-MVP)

**Description:** Play audio clip, user guesses

**Example:**
```
Question: "Name this song"
Type: audio
Media URL: https://storage.com/audio/song123.mp3
Duration: 15 seconds
Correct Answer: "Bohemian Rhapsody"
Alternative Answers: ["bohemian rhapsody", "queen bohemian rhapsody"]
Topic: Music
Category: music
Difficulty: medium
```

**UI Display:**
- Audio player with waveform
- Play/pause controls
- Text/voice answer input

#### 4. Image Questions (Post-MVP)

**Description:** Show image, user identifies

**Example:**
```
Question: "Identify this painting"
Type: image
Media URL: https://storage.com/images/monalisa.jpg
Correct Answer: "Mona Lisa"
Topic: Art
Category: adults
Difficulty: easy
```

**UI Display:**
- Full-width image
- Pinch to zoom
- Text/voice answer input

#### 5. Video Questions (Post-MVP)

**Description:** Play video clip, user answers

**Example:**
```
Question: "Name this movie from the scene"
Type: video
Media URL: https://storage.com/videos/inception_clip.mp4
Duration: 10 seconds
Correct Answer: "Inception"
Topic: Movies
Category: movies
Difficulty: medium
```

**UI Display:**
- Video player
- Play/pause controls
- Text/voice answer input

### Content Categories

**Launch Categories:**
1. **General Knowledge** - Broad trivia across topics
2. **Adults** - Adult-oriented content, may include pop culture references
3. **Music** - Songs, artists, albums, music history
4. **Movies & TV** - Films, shows, actors, directors
5. **Science & Nature** - Physics, Chemistry, Biology, Astronomy
6. **History** - Historical events, figures, dates
7. **Geography** - Countries, capitals, landmarks, maps

**Thematic Packs (Post-MVP):**
1. **Harry Potter** - Characters, spells, locations, lore
2. **90s Nostalgia** - 1990s pop culture, music, events
3. **Science Fiction** - Sci-fi books, movies, concepts
4. **Sports** - Athletes, teams, records, events
5. **Technology** - Computers, internet, innovations
6. **Food & Drink** - Cuisine, recipes, restaurants, chefs

### Content Quality Standards

**Good Questions:**
- Clear and unambiguous
- Verifiable facts with sources
- Fair for target difficulty level
- Culturally inclusive
- Educational value

**Avoid:**
- Overly niche references (unless thematic pack)
- Offensive or controversial content
- Trick questions with gotchas
- Questions with disputed answers
- Outdated information

**Example - Good vs Bad:**

✅ **Good (Easy):**
"What element has the chemical symbol Au?"
- Clear, verifiable, educational

❌ **Bad (Niche):**
"TF2: What code does Soldier put into the door keypad?"
- Video game-specific, only fans would know

✅ **Good (Medium):**
"In what year did the Berlin Wall fall?"
- Historical fact, moderate difficulty

❌ **Bad (Trick):**
"How many seconds are in a year?"
- Could be 365 days or specific year type (leap year)

---

## Personalization & AI

### AI-Powered Features

#### 1. Natural Language Understanding

**How It Works:**
- User input → LLM parser
- Extracts multiple intents
- Returns structured data

**User Benefit:**
- Speak naturally
- No command memorization
- Faster interaction

#### 2. Semantic Question Selection

**How It Works:**
- User preferences → Embedding vector
- ChromaDB semantic search
- Returns relevant questions

**User Benefit:**
- Better question matching
- Discovers related topics
- Avoids exact repetition

#### 3. Adaptive Difficulty (Future)

**How It Works:**
- Track user performance
- Analyze patterns (correct rate, response time)
- Suggest difficulty adjustments

**User Benefit:**
- Optimal challenge level
- Flow state engagement
- Less frustration

### Personalization Without Accounts

**Current Approach (MVP):**
- No user accounts required
- Session-based personalization
- Preferences reset after session expires (30 min)

**Data Stored (Session-Level):**
- Preferred categories
- Excluded topics
- Current difficulty
- Asked questions (prevent repeats)

**Future Personalization (With Accounts):**
- Long-term progress tracking
- Cross-device session sync
- Personalized recommendations
- Achievement badges
- Leaderboards (optional opt-in)

---

## Design Guidelines

### Visual Design Principles

#### 1. Clean & Focused
- Minimal distractions during quiz
- Question text is hero element
- Clear visual hierarchy

#### 2. Conversational Tone
- Friendly, not robotic
- Encouraging feedback
- Playful animations (subtle)

#### 3. Accessibility First
- High contrast text
- Minimum font size: 16pt
- Tappable areas: 44x44pt minimum
- VoiceOver support
- Dynamic type support

#### 4. Performance
- Fast load times
- Instant feedback
- Smooth animations (60fps)
- Minimal network delays

### Typography

**Font Family:** San Francisco (iOS default) or custom

**Hierarchy:**
- **H1 (Question Text)**: 24pt, bold, high contrast
- **H2 (Section Headers)**: 20pt, semibold
- **Body (Answers, Descriptions)**: 16pt, regular
- **Caption (Metadata, Sources)**: 14pt, light

**Readability:**
- Line height: 1.4-1.6
- Max line length: 60-80 characters
- Ample spacing between elements

### Color Palette

**Primary Colors:**
- **Brand Primary**: Blue/Purple (engaging, intelligent)
- **Success**: Green (correct answers)
- **Warning**: Yellow/Orange (partial credit)
- **Error**: Red (incorrect answers)
- **Neutral**: Gray scale (backgrounds, text)

**Semantic Colors:**
- ✅ Correct: Green (#4CAF50)
- ⚠️ Partially Correct: Orange (#FF9800)
- ❌ Incorrect: Red (#F44336)
- ⏭️ Skipped: Gray (#9E9E9E)

**Dark Mode Support:**
- All colors have light/dark variants
- High contrast maintained
- Reduced eye strain

### Iconography

**Icon Style:** SF Symbols (iOS) or custom line icons

**Common Icons:**
- 🎤 Microphone (voice input)
- ⚙️ Settings
- 📊 Statistics
- 🔄 Refresh/Play Again
- ⬅️ Back
- ✅ Correct
- ❌ Incorrect
- ⏭️ Skip
- 👍 Thumbs up
- 👎 Thumbs down

### Animations

**Purpose:** Provide feedback and delight

**Types:**
- **Micro-interactions**: Button press, tap feedback
- **Transitions**: Screen changes, smooth slides
- **Result Animations**: Confetti for correct (subtle), shake for incorrect
- **Voice Recording**: Pulsing microphone icon

**Principles:**
- Duration: 200-400ms
- Easing: Ease-in-out for natural feel
- Purposeful, not decorative

### Spacing & Layout

**Grid System:** 8pt grid

**Margins:**
- Screen edges: 16pt
- Section spacing: 24pt
- Element spacing: 8pt-16pt

**Card Design:**
- Rounded corners: 12pt
- Shadow: Subtle elevation
- Padding: 16pt

---

## Success Metrics

### User Engagement

**Primary Metrics:**
- **Quiz Completion Rate**: Target: > 80%
- **Average Session Length**: Target: 5-10 minutes
- **Retention (Day 7)**: Target: > 40%
- **Retention (Day 30)**: Target: > 20%

**Secondary Metrics:**
- Questions per session
- Voice usage rate
- Repeat play rate (same day)

### Content Quality

**Metrics:**
- **Average Question Rating**: Target: > 3.5/5
- **Questions Rated < 2.5**: Target: < 10%
- **Question Diversity**: Ensure varied topics per session

**Actions:**
- Flag low-rated questions for review
- Remove or improve poor performers
- Prioritize high-rated questions

### Voice Usage

**Metrics:**
- **% Sessions Using Voice**: Target: > 30%
- **Voice Transcription Accuracy**: Target: > 90%
- **Avg Transcription Time**: Target: < 2 seconds

**Improvement Actions:**
- Optimize audio compression
- Test edge cases (accents, background noise)
- Provide fallback to text input

### User Satisfaction

**Metrics:**
- **NPS (Net Promoter Score)**: Target: > 50
- **App Store Rating**: Target: > 4.5 stars
- **User Feedback Sentiment**: Positive > 70%

**Collection Methods:**
- In-app feedback prompts
- Post-quiz satisfaction survey (optional)
- App store reviews monitoring

---

## Technical Constraints & Considerations

### API Endpoints (Quiz Agent Backend)

**Base URL:** `https://api.quizagent.com/api/v1`

**Key Endpoints:**

1. **POST /sessions** - Create new quiz session
2. **POST /sessions/{id}/start** - Start quiz
3. **POST /sessions/{id}/input** - Submit answer (AI-powered)
4. **POST /sessions/{id}/voice/transcribe** - Voice input
5. **POST /sessions/{id}/rate** - Rate question
6. **GET /sessions/{id}** - Get session state
7. **DELETE /sessions/{id}** - End session

### Data Flow

```
iOS App (User)
    ↓ HTTP/REST
Quiz Agent API (Backend)
    ↓ Query
ChromaDB (Questions) + PostgreSQL (Ratings)
    ↑ Response
Quiz Agent API
    ↑ JSON
iOS App (User)
```

### Offline Considerations

**Current Approach (Online-Only):**
- Requires internet connection
- Questions fetched per session
- Session state stored server-side

**Future Offline Support:**
- Cache 50 questions locally
- Sync when back online
- Offline mode indicator

### Privacy & Data

**Data Collected:**
- Session ID (anonymous)
- Answers (for evaluation)
- Ratings (for quality improvement)
- Voice recordings (transcribed, not stored)

**Data NOT Collected (MVP):**
- User accounts
- Personal information
- Location data
- Device identifiers (beyond session)

**Future (With Accounts):**
- Optional account creation
- Email for password recovery
- Progress sync across devices

### Performance Targets

- **Question Load Time**: < 500ms
- **Voice Transcription**: < 2 seconds
- **Answer Evaluation**: < 1 second
- **Screen Transitions**: 60fps, < 300ms

---

## Appendix

### Glossary

- **RAG (Retrieval-Augmented Generation)**: AI technique combining semantic search with metadata filtering
- **Whisper**: OpenAI's speech-to-text API
- **ChromaDB**: Vector database for storing question embeddings
- **Session**: Single quiz instance (10 questions)
- **LLM**: Large Language Model (used for input parsing and evaluation)
- **MCP**: Model Context Protocol (tool integration standard)

### Technical Stack Reference

**Backend:**
- Python 3.11+
- FastAPI (REST API)
- LangGraph (AI agent framework)
- OpenAI GPT-4o-mini (LLM)
- Tavily MCP (web search for sources)
- ChromaDB (vector database)
- PostgreSQL/SQLite (ratings)

**Frontend (iOS):**
- Swift
- SwiftUI (recommended)
- AVFoundation (audio recording)
- URLSession (networking)

### Related Documents

- Backend API Documentation: [Link to OpenAPI/Swagger docs]
- Admin Tool Guide: [Link to Question Generator docs]
- Developer Setup: [Link to technical README]

---

## Revision History

| Version | Date | Changes | Author |
|---------|------|---------|--------|
| 1.0 | 2025-12-11 | Initial product specification | Product Team |

---

**End of Product Specification**

For questions or feedback, contact: [Product Owner Email]
