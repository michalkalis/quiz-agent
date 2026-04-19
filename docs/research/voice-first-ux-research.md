# Voice-First UX Research

**Date:** 2026-03-18 | **Purpose:** Inform Hangs voice interaction design

## Executive Summary

1. **Error recovery is the make-or-break of voice UX.** Nearly 55% of users abandon voice apps after repeated errors. Hangs needs graceful fallbacks at every step: reprompt with variation, escalate to simpler interaction, and never dead-end the user.
2. **Ears hate repetition; eyes tolerate it.** Voice-first games demand far more content variety than visual ones. Randomize TTS phrasing for question intros, result announcements, and transitions -- even small variation (4+ alternatives) dramatically reduces fatigue.
3. **Keep interactions under 10 seconds.** Automotive and hands-free UX research converges on one rule: brief interactions only. Hangs's question-answer loop naturally fits this, but explanations and multi-choice options need careful pacing.
4. **VoiceOver and app TTS will fight each other.** On iOS, using `UIAccessibility.post(notification: .announcement)` instead of `AVSpeechSynthesizer` when VoiceOver is active prevents audio collisions. Hangs must detect VoiceOver state and route speech accordingly.

---

## 1. Voice UI Best Practices

### Key Principles

- **Map three conversation paths, not one.** Design for the Happy Path (system understands perfectly), the Repair Path (mishear/stutter -- request clarification), and the Ambiguity Path (vague input -- offer choices). Writing sample dialogs for all three before coding catches most edge cases.
- **Use progressive error escalation.** First failure: gentle reprompt ("Sorry, I didn't catch that. What's your answer?"). Second failure: simplify ("You can say A, B, C, or D"). Third failure: skip gracefully ("No worries, let's move to the next question"). Never make the user feel stuck.
- **Confirmation should be implicit, not blocking.** Instead of "Did you mean Paris? Say yes or no," use implicit confirmation: "Paris! Let me check..." and let the user interrupt only if wrong. This keeps pace and reduces turn count.

### Relevant Sources

- [Google Conversation Design Guidelines](https://developers.google.com/assistant/conversation-design/welcome) -- Google's official guide for designing voice assistant interactions
- [Voice UI Design Best Practices (Eleken, 2026)](https://www.eleken.co/blog-posts/voice-ui-design) -- Comprehensive overview with conversation flow mapping
- [VUI Design Patterns Guide (UI Deploy, 2025)](https://ui-deploy.com/blog/voice-user-interface-design-patterns-complete-vui-development-guide-2025) -- Reprompt and escalation patterns
- [Conversation Design and Voice UI (Zypsy)](https://llms.zypsy.com/conversation-design-voice-ui) -- Latency management and prototyping
- [Google: Speaking the Same Language (VUI Principles)](https://design.google/library/speaking-the-same-language-vui) -- Error recovery and persona design

### Hangs Application

Hangs already has a state machine (`idle -> startingQuiz -> askingQuestion -> recording -> processing -> showingResult -> finished`) which maps well to conversation design. The gap is in the Repair and Ambiguity paths -- currently, if speech recognition fails, the experience likely dead-ends or requires manual intervention. Adding a 3-tier escalation (reprompt -> simplify -> skip) to the `recording` and `processing` states would cover the most critical failure modes. The implicit confirmation pattern ("Paris! Let me check...") fits naturally with the existing auto-record flow.

---

## 2. Hands-Free Design Patterns

### Key Principles

- **Brief interactions only -- target under 10 seconds per turn.** Apple's CarPlay HIG states: "The best apps support brief interactions and never command the driver's attention." Even though Hangs isn't a CarPlay app, it targets the same context (driving). Each question-answer cycle should be completable in one short voice exchange.
- **Minimize decision-making per interaction.** Limit choices to 3-4 options maximum. For MCQ questions, read options clearly with pauses between them. Never require the user to remember more than what's currently being spoken.
- **Use audio-only state cues, not visual ones.** Drivers can't glance at the screen, so state transitions (listening, processing, correct/incorrect) must be communicated through distinct audio cues: a short tone when recording starts, a different tone for correct vs. incorrect answers.

### Relevant Sources

- [Apple CarPlay Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/carplay) -- Apple's official automotive UX guidelines
- [Designing for CarPlay (Design+Code)](https://designcode.io/ui-design-handbook-designing-for-carplay/) -- Practical CarPlay design patterns
- [Smart Car App Design (Usability Geek)](https://usabilitygeek.com/smart-car-app-design/) -- Input hierarchy for driving contexts
- [CarPlay Developer Guide (Apple, 2026)](https://developer.apple.com/download/files/CarPlay-Developer-Guide.pdf) -- Official developer reference

### Hangs Application

Hangs's question-answer loop is already well-suited for hands-free use. The main risk areas are: (1) reading MCQ options -- 4 options spoken sequentially can exceed 10 seconds; consider shorter option text or letting users respond mid-read ("barge-in" is already implemented); (2) explanations after answers -- these can be long; add a "skip explanation" voice command or auto-truncate to 2 sentences when driving mode is active; (3) state feedback -- the existing `VoiceCommandIndicator` is visual; add distinct earcons for "listening," "correct," and "incorrect" states. A single short ascending tone for correct and descending for incorrect would be instantly learnable.

---

## 3. Accessibility in Voice Apps

### Key Principles

- **VoiceOver and custom TTS will collide -- route speech through the right channel.** When VoiceOver is active, `AVSpeechSynthesizer` competes for the audio channel. Apple recommends using `UIAccessibility.post(notification: .announcement, argument: text)` to delegate speech to VoiceOver's queue instead. This prevents two voices talking simultaneously.
- **Voice Control and VoiceOver can coexist but need careful coordination.** iOS supports using Voice Control and VoiceOver together, but they weren't designed as a pair. If Hangs uses its own speech recognition, it must pause when VoiceOver is speaking to avoid capturing VoiceOver output as user input.
- **Audio session configuration matters.** Use `.duckOthers` audio session option so Hangs's TTS lowers (rather than pauses) any background audio. Set `AVSpeechSynthesizer.usesApplicationAudioSession = true` to maintain control over ducking behavior.

### Relevant Sources

- [Create a Seamless Speech Experience (WWDC20)](https://developer.apple.com/videos/play/wwdc2020/10022/) -- Apple's guide to TTS and VoiceOver coexistence
- [Supporting VoiceOver in Your App (Apple Docs)](https://developer.apple.com/documentation/uikit/supporting-voiceover-in-your-app) -- Official VoiceOver integration guide
- [Using VoiceOver and Voice Control Together (AppleVis)](https://www.applevis.com/forum/ios-ipados/using-voiceover-voice-control-together-ios) -- Community discussion on real-world conflicts
- [AVSpeechSynthesizer (Apple Docs)](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer) -- TTS API reference and audio session behavior

### Hangs Application

Hangs currently has zero accessibility labels (noted in project memory). This is a significant gap. For MVP, the minimum viable accessibility work is: (1) detect VoiceOver state with `UIAccessibility.isVoiceOverRunning` and route TTS through accessibility announcements when active; (2) add `.accessibilityLabel` to all interactive elements (start button, answer buttons, settings toggles); (3) pause speech recognition while VoiceOver is speaking to prevent feedback loops. The existing `AudioService` with `Config.verboseLogging` suggests audio session management is already in place -- extend it to handle the VoiceOver detection case.

---

## 4. Voice Gaming UX

### Key Principles

- **Content variety is non-negotiable for audio games.** "Our ears hate hearing the same thing twice over and over" (Amazon game design guidance). Even 4 variations of the same audio cue feel repetitive eventually. For a trivia game, this means: randomize question intro phrases, vary correct/incorrect response text, and never use the same transition phrase twice in a row.
- **Pacing drives engagement more than content quality.** Successful Alexa trivia games use tight pacing: Trivia Hero gives 60 seconds for maximum questions; Daily Quiz gives 3 minutes for 3 questions. The sweet spot for Hangs is likely 5-10 seconds of silence allowed per question, with a gentle "time's up" prompt. Dead air is the #1 killer of voice game engagement.
- **Local multiplayer is a natural fit for voice-in-car.** Amazon's game design guide notes that Alexa devices are used where multiple people are present (home, car). Hangs could support turn-taking ("Player 1, your turn...") with minimal backend changes since multiplayer state stays local.

### Relevant Sources

- [Best Practices for Building Voice-First Games (Amazon/Alexa Blog)](https://developer.amazon.com/en-US/blogs/alexa/post/fae82327-15dc-4f31-9b52-11ef75203bfc/best-practices-for-building-voice-enabled-game) -- Amazon's official voice game design guide
- [How to Create Engaging Voice-First Games for Alexa (PDF)](https://m.media-amazon.com/images/G/01/mobile-apps/dex/alexa/alexa-skills-kit/guide/AlexaforGamingGuide.pdf) -- Detailed game design patterns
- [Game Audio Immersion and Repetition (A Sound Effect)](https://www.asoundeffect.com/game-audio-immersion/) -- Audio fatigue and variation strategies
- [Design Patterns for Voice Interaction in Games (ACM)](https://dl.acm.org/doi/10.1145/3242671.3242712) -- Academic research on voice game design
- [Alexa Games: Best Trivia Skills (2025)](https://alexagames.com/best-trivia-games-on-alexa-quiz-tutorial/) -- Analysis of top-performing voice trivia games

### Hangs Application

Hangs's current question flow (ask -> record -> evaluate -> result) maps directly to proven Alexa trivia patterns. Three specific improvements based on voice gaming research: (1) **Phrase variation pool** -- create 5+ TTS variants for each interaction type ("Here's your next question" / "Question 3" / "Let's see..." / "Try this one" / "Next up..."). This can be a simple array with random selection, no AI needed. (2) **Pacing timer** -- the existing 15-second hard limit for recording is good, but add a softer 8-second "Need more time?" prompt before the hard cutoff. (3) **Streak audio** -- the app already tracks streaks; add escalating audio excitement for streaks (subtle tone at 3, enthusiastic at 5, celebratory at 10).

---

## 5. iOS Voice Interaction Patterns

### Key Principles

- **SpeechAnalyzer (iOS 26) replaces SFSpeechRecognizer with three specialized modules.** `SpeechTranscriber` for clean command-style speech (ideal for quiz answers), `DictationTranscriber` for natural speech with punctuation, and `SpeechDetector` for voice activity detection (VAD) without transcription. Hangs already uses SpeechAnalyzer -- the key optimization is using `SpeechDetector` for silence detection separately from `SpeechTranscriber` for answer recognition.
- **Implement inactivity-based auto-stop, not just silence detection.** Best practice is a timer that resets when any text is recognized, then fires after ~3 seconds of no new text. This is more reliable than raw audio-level silence detection because it accounts for background noise that isn't speech.
- **Provide haptic feedback for state transitions.** When recording stops (answer captured), fire `UIImpactFeedbackGenerator` -- this gives the user physical confirmation that their input was received, crucial when they're not looking at the screen.

### Relevant Sources

- [SpeechAnalyzer Guide (Anton Gubarenko)](https://antongubarenko.substack.com/p/ios-26-speechanalyzer-guide) -- Practical implementation guide for iOS 26 speech APIs
- [Bring Advanced Speech-to-Text to Your App (WWDC25)](https://developer.apple.com/videos/play/wwdc2025/277/) -- Apple's official SpeechAnalyzer session
- [SpeechAnalyzer (Apple Docs)](https://developer.apple.com/documentation/speech/speechanalyzer) -- API reference
- [SpeechDetector (Apple Docs)](https://developer.apple.com/documentation/speech/speechdetector) -- VAD module reference
- [Implementing SpeechAnalyzer in SwiftUI (Create with Swift)](https://www.createwithswift.com/implementing-advanced-speech-to-text-in-your-swiftui-app/) -- Step-by-step SwiftUI integration
- [Recognizing Speech in Live Audio (Apple Docs)](https://developer.apple.com/documentation/Speech/recognizing-speech-in-live-audio) -- Foundation speech recognition patterns

### Hangs Application

Hangs already uses `SpeechAnalyzer`, `SpeechTranscriber`, and `SpeechDetector` (per the `VoiceCommandService` requiring iOS 26+). The research suggests two optimizations: (1) **Separate VAD from transcription** -- use `SpeechDetector` purely for "is the user talking?" to trigger/extend the recording window, and `SpeechTranscriber` only when speech is actually detected. This saves battery by not running full transcription on silence. (2) **Haptic feedback on capture** -- add `UIImpactFeedbackGenerator.impactOccurred()` when the answer is captured (transition from `recording` to `processing` state). The user feels a tap confirming their answer was heard, even with eyes on the road.

---

## Recommendations for Hangs

Prioritized for a solo dev shipping MVP, ordered by impact-to-effort ratio:

### High Impact, Low Effort

1. **Add phrase variation pools for TTS output.** Create `String` arrays with 5+ variants for question intros, correct/incorrect responses, and transitions. Random selection. Half a day of work, massive reduction in audio fatigue.

2. **Add haptic feedback on state transitions.** A single `UIImpactFeedbackGenerator` call when recording stops and when the answer is evaluated. Two lines of code, significant hands-free UX improvement.

3. **Implement 3-tier error escalation.** On speech recognition failure: (1) reprompt, (2) simplify to "Say A, B, C, or D", (3) auto-skip after third failure. Prevents dead-ends that cause 55% of users to abandon voice apps.

### High Impact, Medium Effort

4. **Add earcons (audio cues) for state transitions.** Short distinct tones for: recording started (soft chime), correct answer (ascending tone), incorrect answer (descending tone), streak milestone (celebratory). Use system sounds or bundled short audio files. Keep to 3-4 distinct sounds maximum to avoid cognitive overload (per Google's guidelines).

5. **Detect VoiceOver and route TTS accordingly.** Check `UIAccessibility.isVoiceOverRunning` and use `UIAccessibility.post(notification: .announcement)` instead of `AVSpeechSynthesizer` when active. Prevents two voices talking over each other.

6. **Add basic accessibility labels.** Cover all interactive elements with `.accessibilityLabel`. No custom accessibility actions needed for MVP, but labels are the minimum for VoiceOver users.

### Medium Impact, Medium Effort

7. **Add a soft timeout prompt before hard cutoff.** At 8 seconds of silence (before the 15-second hard limit), play "Need more time?" This reduces the jarring feeling of a hard cutoff and gives users a cue that they should respond.

8. **Truncate explanations in driving mode.** When auto-record is enabled (proxy for "driving mode"), limit post-answer explanations to 2 sentences max. Full explanations can be shown on screen for later review.

9. **Separate SpeechDetector from SpeechTranscriber pipelines.** Use SpeechDetector for lightweight VAD to manage the recording window, only running full SpeechTranscriber when speech is detected. Saves battery on longer quiz sessions.

### Future (Post-MVP)

10. **Local multiplayer turn-taking.** "Player 1, your turn..." with voice-based player switching. Natural fit for car context with passengers.

11. **Adaptive pacing based on user behavior.** Track average response time and adjust silence timeouts per user. Fast responders get shorter windows; slower responders get more time.

12. **Siri Shortcuts integration.** "Hey Siri, start a car quiz" to launch directly into a quiz session without touching the phone.

---

## Sources

All URLs referenced in this document:

- [Apple CarPlay Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/carplay)
- [Apple: Supporting VoiceOver in Your App](https://developer.apple.com/documentation/uikit/supporting-voiceover-in-your-app)
- [Apple: AVSpeechSynthesizer Documentation](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer)
- [Apple: SpeechAnalyzer Documentation](https://developer.apple.com/documentation/speech/speechanalyzer)
- [Apple: SpeechDetector Documentation](https://developer.apple.com/documentation/speech/speechdetector)
- [Apple: Recognizing Speech in Live Audio](https://developer.apple.com/documentation/Speech/recognizing-speech-in-live-audio)
- [WWDC25: Bring Advanced Speech-to-Text with SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/)
- [WWDC20: Create a Seamless Speech Experience](https://developer.apple.com/videos/play/wwdc2020/10022/)
- [CarPlay Developer Guide (Apple, 2026)](https://developer.apple.com/download/files/CarPlay-Developer-Guide.pdf)
- [Google Conversation Design Guidelines](https://developers.google.com/assistant/conversation-design/welcome)
- [Google: Earcons in Conversation Design](https://developers.google.com/assistant/conversation-design/earcons)
- [Google: Speaking the Same Language (VUI Principles)](https://design.google/library/speaking-the-same-language-vui)
- [Amazon: Best Practices for Voice-First Games](https://developer.amazon.com/en-US/blogs/alexa/post/fae82327-15dc-4f31-9b52-11ef75203bfc/best-practices-for-building-voice-enabled-game)
- [Amazon: Engaging Voice-First Games Guide (PDF)](https://m.media-amazon.com/images/G/01/mobile-apps/dex/alexa/alexa-skills-kit/guide/AlexaforGamingGuide.pdf)
- [Alexa Games: Best Trivia Skills (2025)](https://alexagames.com/best-trivia-games-on-alexa-quiz-tutorial/)
- [Voice UI Design (Eleken, 2026)](https://www.eleken.co/blog-posts/voice-ui-design)
- [VUI Design Patterns Guide (UI Deploy, 2025)](https://ui-deploy.com/blog/voice-user-interface-design-patterns-complete-vui-development-guide-2025)
- [Conversation Design and Voice UI (Zypsy)](https://llms.zypsy.com/conversation-design-voice-ui)
- [VUI Design Principles (Parallel HQ, 2026)](https://www.parallelhq.com/blog/voice-user-interface-vui-design-principles)
- [SpeechAnalyzer Guide (Anton Gubarenko)](https://antongubarenko.substack.com/p/ios-26-speechanalyzer-guide)
- [SpeechAnalyzer in SwiftUI (Create with Swift)](https://www.createwithswift.com/implementing-advanced-speech-to-text-in-your-swiftui-app/)
- [SpeechAnalyzer: Next Evolution (DEV Community)](https://dev.to/arshtechpro/wwdc-2025-the-next-evolution-of-speech-to-text-using-speechanalyzer-6lo)
- [Using VoiceOver and Voice Control Together (AppleVis)](https://www.applevis.com/forum/ios-ipados/using-voiceover-voice-control-together-ios)
- [Designing for CarPlay (Design+Code)](https://designcode.io/ui-design-handbook-designing-for-carplay/)
- [Smart Car App Design (Usability Geek)](https://usabilitygeek.com/smart-car-app-design/)
- [Game Audio Immersion and Repetition (A Sound Effect)](https://www.asoundeffect.com/game-audio-immersion/)
- [Design Patterns for Voice Interaction in Games (ACM)](https://dl.acm.org/doi/10.1145/3242671.3242712)
- [Audio Signifiers for Voice Interaction (NN/g)](https://www.nngroup.com/articles/audio-signifiers-voice-interaction/)
- [Voice Principles (Clearleft)](https://voiceprinciples.com/)
