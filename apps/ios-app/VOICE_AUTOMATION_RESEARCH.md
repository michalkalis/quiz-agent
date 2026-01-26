# Voice Automation & Answer Timer Research

## Overview

This document explores hands-free interaction patterns for the CarQuiz iOS app, specifically:
1. Voice-activated recording (no touch required)
2. Answer countdown timers
3. UX considerations for driving scenarios

---

## 1. Voice Command Approaches

### Option A: iOS Vocal Shortcuts (Recommended)

**iOS 18+ Feature:** Vocal Shortcuts allows custom voice commands without "Hey Siri"

**How it works:**
- User records a trigger phrase (e.g., "Answer", "Record", "Start")
- Processing happens entirely on-device (fast, private, works offline)
- Can map to app-specific actions via Shortcuts integration

**Implementation Path:**
1. Create a Shortcut action for "Start Recording in CarQuiz"
2. User assigns a vocal shortcut to trigger it
3. App receives intent and starts recording

**Pros:**
- No custom wake word detection needed
- Leverages Apple's built-in system
- Works with AirPods/CarPlay

**Cons:**
- Requires iOS 18+
- User must manually set up the shortcut
- Less discoverable (need onboarding)

### Option B: Continuous Listening with Speech Framework

**How it works:**
- App continuously listens for a trigger phrase ("Start recording")
- Uses `SFSpeechRecognizer` for on-device recognition
- When detected, starts actual answer recording

**Implementation Path:**
1. Request microphone + speech recognition permissions
2. Run continuous speech recognition in background
3. Detect trigger phrase, then switch to answer recording mode

**Pros:**
- Fully integrated in-app experience
- Custom trigger phrases
- Works on older iOS versions

**Cons:**
- Battery intensive (continuous listening)
- Privacy concerns (always listening)
- May conflict with answer recording
- Complex state management

### Option C: Siri Shortcuts Integration

**How it works:**
- User says "Hey Siri, start CarQuiz recording"
- Siri launches app and triggers recording action

**Pros:**
- No custom implementation needed
- Familiar to users

**Cons:**
- Requires "Hey Siri" prefix
- Slower activation (Siri processing)
- May not work well while driving (Siri interruptions)

### Recommendation

**Start with Option A (Vocal Shortcuts)** for iOS 18+ users:
- Lowest implementation effort
- Best battery efficiency
- Native iOS experience

**Future consideration:** Option B for a more seamless experience, but requires careful battery/privacy management.

---

## 2. Answer Timer Best Practices

### Industry Standards

| Question Type | Recommended Time |
|--------------|------------------|
| Simple recall (capitals, facts) | 10-15 seconds |
| True/False | 10-15 seconds |
| Multiple choice | 15-30 seconds |
| Open-ended text | 30-60 seconds |
| Complex/multi-part | 60-90 seconds |

### Common Timer Patterns

1. **Fixed Timer:** Same duration for all questions
2. **Per-Question Timer:** Different times based on difficulty
3. **Decreasing Points:** More points for faster answers (HQ Trivia style)
4. **Grace Period:** Extra 5-10 seconds for harder questions

### UX Considerations

**Visual Feedback:**
- Circular progress indicator (like HQ Trivia)
- Color change at 10-second warning (yellow → red)
- Pulsing animation in final 5 seconds

**Audio Cues:**
- Optional tick sound in final seconds
- Buzzer when time expires
- Can be disabled in settings

**Auto-Submit Behavior:**
- When timer expires: skip question OR auto-submit current recording
- Show "Time's up!" message
- Transition to next question

### Recommended Implementation

```
Default: 30 seconds per question
Settings options: 15s, 30s, 45s, 60s, "No timer"

Timer behavior:
- Starts after TTS finishes reading question
- Pauses during "processing" state
- Visual countdown always visible
- Audio warning at 10 seconds (optional)
- Auto-skip if no answer submitted
```

---

## 3. Hands-Free UX for Driving

### Key Principles

1. **Zero-Touch Operation**
   - Voice to start quiz
   - Voice to start/stop recording
   - Auto-advance between questions

2. **Audio-First Design**
   - All feedback should be spoken, not just visual
   - "Correct! The answer is Paris. 10 points. Next question..."
   - "Time's up. Moving to next question..."

3. **Simple Voice Commands**
   - "Start" - begin recording
   - "Stop" or silence detection - end recording
   - "Skip" - skip current question
   - "Pause" - pause quiz

4. **Safety Considerations**
   - No complex visual UI while driving
   - Large, glanceable status indicators
   - Haptic feedback for state changes

### Suggested UI Hint

Add a small hint in the QuestionView to inform users about voice control:

```
"Say 'Hey Siri, start recording' or tap the mic"
```

Or for Vocal Shortcuts users:
```
"Say your trigger word or tap to record"
```

---

## 4. Implementation Roadmap

### Phase 1: Answer Timer (Low Effort)
- Add configurable timer to settings (15s, 30s, 45s, 60s, off)
- Visual countdown in QuestionView
- Auto-skip when timer expires
- Estimated: 2-3 hours

### Phase 2: Siri Shortcuts (Medium Effort)
- Create App Intent for "Start Recording"
- Add to Shortcuts app
- User can assign "Hey Siri" command
- Estimated: 4-6 hours

### Phase 3: Vocal Shortcuts Support (Medium Effort)
- Same as Phase 2, but document setup for Vocal Shortcuts
- Create onboarding flow to help users set it up
- Estimated: 2-3 hours (mostly documentation/onboarding)

### Phase 4: Continuous Listening (High Effort)
- Custom wake word detection
- Background audio session management
- Battery optimization
- Estimated: 1-2 weeks

---

## 5. Privacy & Permissions

### Required Permissions
- Microphone (already granted for answer recording)
- Speech Recognition (new - for voice commands)

### Privacy Considerations
- On-device processing preferred (no server uploads for wake word)
- Clear indication when app is listening
- Easy way to disable voice activation

### User Communication
```
"CarQuiz can listen for voice commands to start recording hands-free.
Audio is processed on your device and never sent to servers."
```

---

## 6. Competitive Analysis

### Apps with Voice Quiz Features

1. **Trivia Crack** - Tap-only, no voice input
2. **QuizUp** - Tap-only, timed answers (10-15s)
3. **HQ Trivia** (discontinued) - 10-second countdown, tap selection
4. **Jeopardy! PlayShow** - Voice answer support, uses Siri

### Gap Analysis
- Most quiz apps are tap-based
- Voice input for answers is rare
- Hands-free operation is a differentiator for CarQuiz

---

## Sources

- [iOS Vocal Shortcuts](https://www.simplymac.com/ios/vocal-shortcuts-iphone)
- [Apple Speech Framework](https://developer.apple.com/documentation/speech)
- [Picovoice iOS Speech Recognition](https://picovoice.ai/blog/ios-speech-recognition/)
- [AhaSlides Quiz Timer Guide](https://ahaslides.com/blog/quiz-timer-for-timed-quizzes/)
- [Crowdpurr Trivia Timing](https://help.crowdpurr.com/hc/en-us/articles/115002627972-Trivia-Game-Settings-Playback-and-Timing)
- [HQ Trivia Implementation](https://www.pubnub.com/blog/build-your-own-hq-trivia-app-for-android/)
