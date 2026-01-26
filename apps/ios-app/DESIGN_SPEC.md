# CarQuiz iOS App - Design Specification

## Overview

**App Name:** CarQuiz
**Platform:** iOS 18+
**Primary Use Case:** Hands-free trivia quiz while driving
**Core Interaction:** Voice-based Q&A with audio playback

### Design Philosophy

This app is designed for **distracted-free use while driving**. The user's eyes should be on the road, hands on the wheel. All critical interactions must be accessible via large touch targets or voice. Visual design should support quick glances rather than prolonged reading.

---

## Brand & Identity

**Current Branding:**
- Name: "CarQuiz"
- Tagline: "Hands-Free Trivia While You Drive"
- Primary Icon: Car symbol
- Primary Color: Blue

**Design Freedom:** The AI design tool may propose new branding, color schemes, typography, and visual identity that better suits the driving/quiz experience. Consider themes like:
- Road trip / adventure
- Brain / knowledge / trivia
- Audio / voice / sound waves
- Minimal / distraction-free
- Gamification / achievement

---

## User Personas

### Primary: The Commuter
- Daily driver with 20-60 minute commutes
- Wants mental stimulation during boring drives
- Needs completely hands-free operation
- Values quick, glanceable information

### Secondary: The Road Tripper
- Long-distance driver
- Wants entertainment for passengers and driver
- May use CarPlay integration
- Enjoys competitive/social elements

---

## Core User Flows

### Flow 1: Start a Quiz
```
Open App → Configure Settings (optional) → Tap Start → First Question Plays (audio)
```

### Flow 2: Answer a Question
```
Listen to Question (audio) → Tap Mic → Speak Answer → Stop Recording →
Confirm/Re-record → Hear Result (audio) → Auto-advance or Manual Continue
```

### Flow 3: Complete Quiz
```
Answer All Questions → View Final Score → Start Another Quiz or Exit
```

### Flow 4: Minimize/Background Usage
```
During Quiz → Minimize to Floating Widget → Continue Driving →
Tap Widget to Expand → Resume Full View
```

---

## Functional Requirements by Screen

### Screen: Home / Start

**Purpose:** Entry point, quiz configuration, session start

**Required Functionality:**
- Start new quiz session
- Configure quiz settings before starting
- Access question history/settings
- Show current settings summary

**Settings to Configure:**
| Setting | Options | Purpose |
|---------|---------|---------|
| Language | English, Slovak, Czech, German, French, Spanish, Italian, Polish, Hungarian, Romanian | Quiz language |
| Question Count | 5, 10, 15, 20 | Number of questions per session |
| Difficulty | Easy, Medium, Hard, Random | Question difficulty level |
| Category | All Categories, Adults Only, General | Content filtering |
| Audio Mode | Call Mode, Media Mode | Bluetooth routing (Call=HFP, Media=A2DP) |
| Microphone | Device list + Automatic | Input device selection |
| Speaker | System audio route | Output device selection |
| Auto-advance | 5s, 8s, 10s, 15s, Disabled | Delay before next question |

**UX Considerations:**
- Settings could be on home screen, in a separate settings screen, or in a bottom sheet
- Consider showing "quick start" with last-used settings vs "customize" flow
- Large touch targets for driving safety

**States:**
- Default (ready to start)
- Loading (starting session)
- Error (failed to start)

---

### Screen: Question / Recording

**Purpose:** Display current question, handle voice recording

**Required Functionality:**
- Display question text (readable at a glance)
- Show question number and total (e.g., "2 of 10")
- Show current score
- Show topic/category of question
- Large microphone button for recording
- Visual recording indicator
- Stop recording control
- Minimize to floating widget

**Recording States:**
| State | Visual Indicator | User Action |
|-------|------------------|-------------|
| Waiting | "Tap to answer" hint | Tap mic to start |
| Recording | Pulsing animation, "Recording..." | Tap to stop |
| Processing | Spinner, "Processing..." | Wait |

**Voice Interaction:**
- Question audio plays automatically when screen appears
- Recording should be obvious (large pulsing indicator)
- Clear feedback when recording stops

**Error Handling:**
- Recording failed (microphone permission, hardware issue)
- Submission failed (network error)
- Transcription failed (unclear speech)

**UX Considerations:**
- Minimize text, maximize recording button
- Consider voice-activated recording ("Hey CarQuiz" or automatic voice detection)
- Haptic feedback on recording start/stop
- Dark mode for night driving

---

### Screen: Answer Confirmation

**Purpose:** Show transcribed answer, allow re-recording

**Required Functionality:**
- Display what the system heard (transcribed text)
- Confirm button to submit answer
- Re-record button to try again
- Clear indication this is a confirmation step

**States:**
- Processing (transcription in progress)
- Ready (transcription complete, awaiting decision)

**UX Considerations:**
- Could be a modal/sheet or full screen
- Should be quick to dismiss (glance, tap, done)
- Consider auto-confirm after delay for truly hands-free operation

---

### Screen: Result / Evaluation

**Purpose:** Show answer evaluation, provide feedback

**Required Functionality:**
- Show result (Correct, Incorrect, Partially Correct, Skipped)
- Show points awarded
- Show user's answer vs correct answer
- Show source/explanation (if available)
- Link to source article (optional, not for driving)
- Continue to next question
- Pause auto-advance option
- End quiz early option
- Minimize to widget

**Result Types:**
| Result | Visual | Points |
|--------|--------|--------|
| Correct | Positive indicator (checkmark, green) | 1.0 |
| Partially Correct | Partial indicator | 0.5-0.75 |
| Partially Incorrect | Partial indicator | 0.25-0.5 |
| Incorrect | Negative indicator (X, red) | 0 |
| Skipped | Neutral indicator | 0 |

**Auto-advance Behavior:**
- Countdown timer visible
- "Stay Here" pauses countdown for current question only
- Manual "Continue" bypasses countdown
- Disabled globally via settings

**Audio Feedback:**
- Result audio plays automatically (correct/incorrect sound + explanation)
- User can interrupt and continue

**UX Considerations:**
- Result should be immediately obvious (large icon, color)
- Detailed information secondary (scrollable if needed)
- Source link should be de-emphasized (dangerous while driving)
- Consider celebratory animations for correct answers

---

### Screen: Quiz Complete / Results Summary

**Purpose:** Show final score, encourage replay

**Required Functionality:**
- Final score display (points out of total)
- Score as percentage
- Visual achievement indicator (trophy, stars, badge)
- Question count completed
- Accuracy percentage
- Start another quiz button
- Return to home button

**Achievement Tiers:**
| Score | Tier | Suggested Visual |
|-------|------|------------------|
| 90%+ | Gold/Excellent | Trophy, gold color |
| 80-89% | Silver/Great | Star, silver color |
| 60-79% | Bronze/Good | Medal, bronze color |
| <60% | Participant | Checkered flag, neutral |

**Messaging by Performance:**
| Score | Message Tone |
|-------|--------------|
| 90%+ | Exceptional ("Outstanding!", "Quiz Master!") |
| 80-89% | Congratulatory ("Great job!", "Well done!") |
| 60-79% | Encouraging ("Nice work!", "Good effort!") |
| <60% | Supportive ("Keep practicing!", "You'll get 'em next time!") |

**UX Considerations:**
- Celebratory feel for good scores
- Encouraging (not discouraging) for low scores
- Quick path to replay
- Consider sharing results (social, though not while driving)

---

### Screen: Error

**Purpose:** Handle and recover from errors gracefully

**Required Functionality:**
- Clear error indication
- Error message (user-friendly, not technical)
- Retry option
- Return to home option

**Error Types to Handle:**
- Network connectivity issues
- Session expired
- Server errors
- Audio/microphone failures

**UX Considerations:**
- Friendly, not alarming
- Clear recovery path
- Don't lose user's progress if possible

---

### Screen: Settings / History

**Purpose:** Manage question history, app settings

**Required Functionality:**
- Show question history count (X of 500 max)
- Reset question history (to see previously seen questions)
- Capacity warning when history is filling up

**History Capacity Indicators:**
| Fill Level | Indicator |
|------------|-----------|
| <80% | Normal |
| 80-90% | Warning (orange) |
| 90%+ | Critical (red) |

**UX Considerations:**
- Could be standalone screen or part of home screen
- Reset should have confirmation
- Explain what question history does

---

### Component: Minimized Quiz Widget

**Purpose:** Compact view for background quiz operation

**Required Functionality:**
- Show current question number and total
- Show current score
- State-specific indicator (recording, processing, result)
- One-tap expansion to full view
- Record button accessible from widget

**States:**
| Quiz State | Widget Display |
|------------|----------------|
| Asking Question | "Record" button prominent |
| Recording | Recording indicator (red, pulsing) |
| Processing | Loading spinner |
| Showing Result | Result indicator (check/X) |

**UX Considerations:**
- Floating position (corner of screen)
- Non-intrusive but accessible
- Large enough to tap while driving
- Consider Picture-in-Picture style

---

### Component: Audio Device Picker

**Purpose:** Select microphone input device

**Required Functionality:**
- List available input devices
- Show device type (built-in, Bluetooth, wired)
- Automatic option (let system choose)
- Visual indicator for selected device
- Device-specific icons

**Device Types:**
| Type | Icon Suggestion |
|------|-----------------|
| Built-in | iPhone icon |
| Bluetooth HFP | Car/headset icon |
| Bluetooth A2DP | AirPods/headphones icon |
| Wired | Headphones with wire |
| Car Bluetooth | Car icon |

**UX Considerations:**
- Could be sheet, popover, or inline picker
- Warn about audio mode compatibility (HFP devices need Call Mode)
- Show connection status

---

### Component: Language Picker

**Purpose:** Select quiz language

**Required Functionality:**
- List of supported languages
- Native language name (e.g., "Slovenčina")
- English name (e.g., "Slovak")
- Selection indicator

**Supported Languages:**
- English (en)
- Slovak (sk)
- Czech (cs)
- German (de)
- French (fr)
- Spanish (es)
- Italian (it)
- Polish (pl)
- Hungarian (hu)
- Romanian (ro)

---

## Global UI States

### Loading States
Every async operation should have a loading indicator:
- Starting quiz session
- Submitting answer
- Loading next question
- Processing transcription

### Empty States
Handle gracefully when data is missing:
- No microphones available
- No questions loaded yet
- No evaluation result yet

### Offline State
App requires network connectivity:
- Show offline indicator
- Explain what's not working
- Retry when connection restored

---

## Accessibility Requirements

**Voice Control:** App should work with iOS Voice Control
**VoiceOver:** All interactive elements need accessibility labels
**Dynamic Type:** Support system text size preferences
**Contrast:** Sufficient contrast ratios for all text
**Haptics:** Tactile feedback for recording actions

---

## Design System Requirements

### Touch Targets
- Minimum 44x44pt for all tappable elements
- Primary actions (mic button, start button) should be larger (60-80pt+)
- Driving-safe targets should be 80pt+ when possible

### Typography
- Question text: Large, readable, high contrast
- Status text: Secondary, glanceable
- Buttons: Clear, action-oriented labels

### Color Usage
- Success/Correct: Green tones
- Error/Incorrect: Red tones
- Warning/Partial: Orange/yellow tones
- Neutral/Info: Blue tones
- Recording: Red (universal "recording" color)

### Animation
- Recording pulse (heartbeat-like)
- Score increment animation
- State transitions (smooth, not jarring)
- Celebration effects (confetti, bounce) for good scores

### Dark Mode
- Must support iOS dark mode
- Consider auto-switching based on ambient light
- Night driving mode with reduced brightness

---

## Platform Integration

### CarPlay (Future)
- Design should consider CarPlay constraints
- Even simpler interface for car dashboard
- Voice-first interaction

### Background Audio
- App plays audio when backgrounded
- Recording works with screen locked (with limitations)

### Notifications
- Consider reminder notifications (not currently implemented)
- "Continue your quiz" if user abandons mid-session

---

## Competitive Analysis Considerations

Consider design patterns from:
- Trivia Crack (gamification, achievements)
- Duolingo (encouragement, streaks, progress)
- Podcast apps (audio controls, background playback)
- Navigation apps (driving-safe UI, glanceable info)

---

## Design Deliverables Requested

1. **Complete UI Kit:** All screens in all states
2. **Component Library:** Reusable components with variants
3. **Color System:** Primary, secondary, semantic colors
4. **Typography Scale:** Font sizes and weights
5. **Icon Set:** Custom icons or icon selection
6. **Animation Specs:** Motion design guidelines
7. **Dark Mode Variants:** All screens in dark mode
8. **Accessibility Annotations:** Labels, focus order

---

## Open UX Questions (Designer's Choice)

The following UX decisions are **intentionally left open** for the design tool to solve:

1. **Settings Location:** Should settings be on the home screen, in a separate screen, in a bottom sheet, or revealed progressively?

2. **Onboarding:** Should there be a first-run experience explaining the app? How to handle microphone permission request?

3. **Answer Confirmation:** Is a separate confirmation step necessary? Could this be combined with the result screen or use auto-confirm?

4. **Navigation Pattern:** Tab bar, navigation stack, or single-screen with modals?

5. **Widget Placement:** Where should the minimized quiz widget appear? Fixed corner? Draggable?

6. **Progress Visualization:** How to show quiz progress? Linear bar, circular progress, step indicators?

7. **Score Display:** Running total, percentage, both? When to show vs hide?

8. **Gamification:** Badges, streaks, leaderboards, achievements? How much is too much?

9. **Sound Design:** What audio cues for correct/incorrect/recording/navigation? (Visual design should complement audio)

10. **Micro-interactions:** What delightful details would make the app feel polished?

---

## Technical Constraints

- SwiftUI native (no UIKit wrappers where possible)
- iOS 18+ only (can use latest SwiftUI features)
- Must work on iPhone (iPad optional)
- Must support both portrait and landscape
- Must support Dynamic Type
- Must support Dark Mode
- Recording button must be prominent and fail-safe (no accidental recordings)

---

## Success Metrics

A successful redesign should:
- Reduce cognitive load while driving
- Make recording action obvious and accessible
- Clearly communicate quiz state at a glance
- Feel rewarding and encourage continued use
- Be visually distinctive and memorable
- Work flawlessly with voice and large touch targets
