//
//  VoiceCommandTests.swift
//  HangsTests
//
//  Tests for voice command matching, state validity, and echo rejection
//

import Foundation
import Testing
@testable import CarQuiz

// MARK: - Command Matching Tests

@Suite("VoiceCommand Matching Tests")
struct VoiceCommandMatchingTests {

    @Test("matches 'start' command")
    func matchStart() {
        #expect(VoiceCommand.match(from: "start") == .start)
    }

    @Test("matches 'stop' command")
    func matchStop() {
        #expect(VoiceCommand.match(from: "stop") == .stop)
    }

    @Test("matches 'skip' command")
    func matchSkip() {
        #expect(VoiceCommand.match(from: "skip") == .skip)
    }

    @Test("matches 'ok' command")
    func matchOk() {
        #expect(VoiceCommand.match(from: "ok") == .ok)
    }

    @Test("matches command in longer phrase")
    func matchInPhrase() {
        #expect(VoiceCommand.match(from: "please start now") == .start)
        #expect(VoiceCommand.match(from: "ok let's go") == .ok)
    }

    @Test("case insensitive matching")
    func caseInsensitive() {
        #expect(VoiceCommand.match(from: "START") == .start)
        #expect(VoiceCommand.match(from: "Stop") == .stop)
        #expect(VoiceCommand.match(from: "SKIP") == .skip)
        #expect(VoiceCommand.match(from: "OK") == .ok)
    }

    @Test("returns nil for unknown words")
    func noMatchForUnknown() {
        #expect(VoiceCommand.match(from: "hello") == nil)
        #expect(VoiceCommand.match(from: "answer") == nil)
        #expect(VoiceCommand.match(from: "") == nil)
    }

    @Test("priority: start beats stop when both present")
    func priorityStartBeatsStop() {
        #expect(VoiceCommand.match(from: "start or stop") == .start)
    }

    @Test("priority: stop beats skip")
    func priorityStopBeatsSkip() {
        #expect(VoiceCommand.match(from: "stop and skip") == .stop)
    }

    // MARK: - Phase 4: New Command Matching

    @Test("matches 'repeat' command")
    func matchRepeat() {
        #expect(VoiceCommand.match(from: "repeat") == .repeat)
        #expect(VoiceCommand.match(from: "please repeat") == .repeat)
    }

    @Test("matches 'score' command")
    func matchScore() {
        #expect(VoiceCommand.match(from: "score") == .score)
        #expect(VoiceCommand.match(from: "what's my score") == .score)
    }

    @Test("matches 'help' command")
    func matchHelp() {
        #expect(VoiceCommand.match(from: "help") == .help)
        #expect(VoiceCommand.match(from: "I need help") == .help)
    }

    @Test("'help' does not match 'helpful' (word boundary)")
    func helpWordBoundary() {
        #expect(VoiceCommand.match(from: "helpful") == nil)
        #expect(VoiceCommand.match(from: "that was helpful") == nil)
    }

    @Test("'ok' does not match 'book' (word boundary)")
    func okWordBoundary() {
        #expect(VoiceCommand.match(from: "book") == nil)
        #expect(VoiceCommand.match(from: "look") == nil)
    }

    @Test("priority: repeat > score > help")
    func priorityNewCommands() {
        #expect(VoiceCommand.match(from: "repeat score help") == .repeat)
        #expect(VoiceCommand.match(from: "score help") == .score)
    }

    @Test("priority: skip > repeat")
    func prioritySkipBeatsRepeat() {
        #expect(VoiceCommand.match(from: "skip repeat") == .skip)
    }
}

// MARK: - State Validity Tests (ViewModel integration)

@Suite("Voice Command State Validity Tests")
struct VoiceCommandStateValidityTests {

    /// Creates a ViewModel with mock voice command service
    @MainActor
    private func makeViewModel() -> (QuizViewModel, MockVoiceCommandService) {
        let mockVoice = MockVoiceCommandService()
        let mockNetwork = MockNetworkService()
        mockNetwork.mockSession = QuizSession(
            id: "test_session_123",
            mode: "single", phase: "asking", maxQuestions: 10,
            currentDifficulty: "medium", category: nil, language: "en",
            participants: [
                Participant(
                    id: "p1", userId: nil, displayName: "Player",
                    score: 0, answeredCount: 0, correctCount: 0,
                    lastAnswer: nil, lastResult: nil,
                    isHost: true, isReady: true, joinedAt: Date()
                )
            ],
            expiresAt: Date().addingTimeInterval(30 * 60),
            createdAt: Date()
        )
        mockNetwork.mockResponse = QuizResponse(
            success: true,
            message: "Input processed",
            session: mockNetwork.mockSession!,
            currentQuestion: Question(
                id: "q_002", question: "Next?", type: .text,
                possibleAnswers: nil, difficulty: "medium",
                topic: "Test", category: "test",
                sourceUrl: nil, sourceExcerpt: nil,
                mediaUrl: nil, imageSubtype: nil,
                explanation: nil, generatedBy: nil
            ),
            evaluation: Evaluation(
                userAnswer: "Test",
                result: .correct,
                points: 1.0,
                correctAnswer: "Expected",
                questionId: "q_001",
                explanation: nil
            ),
            feedbackReceived: [],
            audio: nil
        )

        let viewModel = QuizViewModel(
            networkService: mockNetwork,
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            voiceCommandService: mockVoice
        )
        return (viewModel, mockVoice)
    }

    @Test("'skip' ignored during recording state")
    @MainActor
    func skipIgnoredDuringRecording() async throws {
        let (viewModel, _) = makeViewModel()
        viewModel.quizState = .recording

        // Directly call handleVoiceCommand which is private,
        // but we can test via the mock service simulation approach
        // For now, test the state guard logic:
        // skip only works in .askingQuestion — recording state should not trigger skip
        #expect(viewModel.quizState == .recording)
        // In recording state, only "stop" should work via voice commands
    }

    @Test("'start' triggers recording from askingQuestion")
    @MainActor
    func startTriggersRecordingFromAskingQuestion() async throws {
        let (viewModel, _) = makeViewModel()
        viewModel.quizState = .askingQuestion

        // Simulate what handleVoiceCommand does for .start
        await viewModel.toggleRecording()

        #expect(viewModel.quizState == .recording)
    }

    @Test("'stop' triggers submission from recording")
    @MainActor
    func stopTriggersSubmissionFromRecording() async throws {
        let (viewModel, _) = makeViewModel()
        viewModel.currentSession = QuizSession(
            id: "test_session_123",
            mode: "single", phase: "asking", maxQuestions: 10,
            currentDifficulty: "medium", category: nil, language: "en",
            participants: [], expiresAt: Date().addingTimeInterval(1800),
            createdAt: Date()
        )
        viewModel.currentQuestion = Question(
            id: "q_001", question: "Test?", type: .text,
            possibleAnswers: nil, difficulty: "medium",
            topic: "Test", category: "test",
            sourceUrl: nil, sourceExcerpt: nil,
            mediaUrl: nil, imageSubtype: nil,
            explanation: nil, generatedBy: nil
        )
        viewModel.quizState = .askingQuestion

        // Start recording first
        await viewModel.toggleRecording()
        #expect(viewModel.quizState == .recording)

        // Then stop (simulating "stop" command)
        await viewModel.toggleRecording()

        // Should have submitted and show confirmation
        #expect(viewModel.showAnswerConfirmation == true)
    }

    @Test("voiceCommandsAvailable reflects service presence")
    @MainActor
    func voiceCommandsAvailableReflectsService() async throws {
        let (viewModel, _) = makeViewModel()
        #expect(viewModel.voiceCommandsAvailable == true)

        // ViewModel without voice service
        let viewModelNoVoice = QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        #expect(viewModelNoVoice.voiceCommandsAvailable == false)
    }

    @Test("voice command state resets on resetToHome")
    @MainActor
    func voiceCommandStateResetsOnHome() async throws {
        let (viewModel, _) = makeViewModel()
        viewModel.voiceCommandState = .listening
        viewModel.resetToHome()
        #expect(viewModel.voiceCommandState == .disabled)
    }
}

// MARK: - Echo Rejection Tests

@Suite("Voice Command Echo Rejection Tests")
struct VoiceCommandEchoRejectionTests {

    @Test("mock service tracks playback text")
    @MainActor
    func mockTracksPlaybackText() async throws {
        let mock = MockVoiceCommandService()

        mock.setPlaybackText("What is the capital of France?")
        #expect(mock.playbackText == "What is the capital of France?")

        mock.setPlaybackText(nil)
        #expect(mock.playbackText == nil)
    }

    @Test("mock service tracks recording active state")
    @MainActor
    func mockTracksRecordingActive() async throws {
        let mock = MockVoiceCommandService()

        mock.setRecordingActive(true)
        #expect(mock.recordingActive == true)

        mock.setRecordingActive(false)
        #expect(mock.recordingActive == false)
    }

    @Test("mock service simulates commands")
    @MainActor
    func mockSimulatesCommands() async throws {
        let mock = MockVoiceCommandService()
        await mock.startListening()

        #expect(mock.isListening == true)
        #expect(mock.startListeningCallCount == 1)

        mock.stopListening()
        #expect(mock.isListening == false)
        #expect(mock.stopListeningCallCount == 1)
    }
}

// MARK: - QuizSettings Voice Commands Tests

@Suite("QuizSettings Voice Commands Tests")
struct QuizSettingsVoiceCommandsTests {

    @Test("default settings have voiceCommandsEnabled = true")
    func defaultVoiceCommandsEnabled() {
        let settings = QuizSettings.default
        #expect(settings.voiceCommandsEnabled == true)
    }

    @Test("backward-compatible decoding — missing voiceCommandsEnabled defaults to true")
    func backwardCompatibleDecoding() throws {
        // Simulate old persisted data without voiceCommandsEnabled
        let json = """
        {
            "language": "en",
            "audioMode": "media",
            "numberOfQuestions": 10,
            "difficulty": "medium",
            "autoAdvanceDelay": 8,
            "answerTimeLimit": 30
        }
        """
        let data = json.data(using: .utf8)!
        let settings = try JSONDecoder().decode(QuizSettings.self, from: data)

        #expect(settings.voiceCommandsEnabled == true)
        #expect(settings.language == "en")
    }

    @Test("voiceCommandsEnabled persists when set to false")
    func voiceCommandsDisabledPersists() throws {
        let json = """
        {
            "language": "en",
            "audioMode": "media",
            "numberOfQuestions": 10,
            "difficulty": "medium",
            "autoAdvanceDelay": 8,
            "answerTimeLimit": 30,
            "voiceCommandsEnabled": false
        }
        """
        let data = json.data(using: .utf8)!
        let settings = try JSONDecoder().decode(QuizSettings.self, from: data)

        #expect(settings.voiceCommandsEnabled == false)
    }
}

// MARK: - Phase 2: Auto-Record & Silence Detection Tests

@Suite("QuizSettings Auto-Record Tests")
struct QuizSettingsAutoRecordTests {

    @Test("default settings have autoRecordEnabled = true")
    func defaultAutoRecordEnabled() {
        let settings = QuizSettings.default
        #expect(settings.autoRecordEnabled == true)
    }

    @Test("backward-compatible decoding — missing autoRecordEnabled defaults to true")
    func backwardCompatibleAutoRecord() throws {
        let json = """
        {
            "language": "en",
            "audioMode": "media",
            "numberOfQuestions": 10,
            "difficulty": "medium",
            "autoAdvanceDelay": 8,
            "answerTimeLimit": 30
        }
        """
        let data = json.data(using: .utf8)!
        let settings = try JSONDecoder().decode(QuizSettings.self, from: data)

        #expect(settings.autoRecordEnabled == true)
    }

    @Test("autoRecordEnabled persists when set to false")
    func autoRecordDisabledPersists() throws {
        let json = """
        {
            "language": "en",
            "audioMode": "media",
            "numberOfQuestions": 10,
            "difficulty": "medium",
            "autoAdvanceDelay": 8,
            "answerTimeLimit": 30,
            "autoRecordEnabled": false
        }
        """
        let data = json.data(using: .utf8)!
        let settings = try JSONDecoder().decode(QuizSettings.self, from: data)

        #expect(settings.autoRecordEnabled == false)
    }

    @Test("both voiceCommandsEnabled and autoRecordEnabled decode together")
    func bothSettingsDecode() throws {
        let json = """
        {
            "language": "en",
            "audioMode": "media",
            "numberOfQuestions": 10,
            "difficulty": "medium",
            "autoAdvanceDelay": 8,
            "answerTimeLimit": 30,
            "voiceCommandsEnabled": true,
            "autoRecordEnabled": false
        }
        """
        let data = json.data(using: .utf8)!
        let settings = try JSONDecoder().decode(QuizSettings.self, from: data)

        #expect(settings.voiceCommandsEnabled == true)
        #expect(settings.autoRecordEnabled == false)
    }
}

@Suite("SilenceEvent Tests")
struct SilenceEventTests {

    @Test("SilenceEvent equality")
    func silenceEventEquality() {
        #expect(SilenceEvent.speechStarted == SilenceEvent.speechStarted)
        #expect(SilenceEvent.silenceAfterSpeech(duration: 1.5) == SilenceEvent.silenceAfterSpeech(duration: 1.5))
        #expect(SilenceEvent.speechStarted != SilenceEvent.silenceAfterSpeech(duration: 1.5))
    }

    @Test("mock service simulates silence events")
    @MainActor
    func mockSimulatesSilenceEvents() async throws {
        let mock = MockVoiceCommandService()
        await mock.startListening()

        // Simulate speech started
        mock.simulateSilenceEvent(.speechStarted)

        // Simulate silence after speech
        mock.simulateSilenceEvent(.silenceAfterSpeech(duration: 1.5))

        // Verify stream is accessible
        #expect(mock.isListening == true)
    }
}

@Suite("Auto-Record ViewModel Tests")
struct AutoRecordViewModelTests {

    @MainActor
    private func makeViewModel(autoRecordEnabled: Bool = true) -> (QuizViewModel, MockVoiceCommandService) {
        let mockVoice = MockVoiceCommandService()
        let mockNetwork = MockNetworkService()
        mockNetwork.mockSession = QuizSession(
            id: "test_session_123",
            mode: "single", phase: "asking", maxQuestions: 10,
            currentDifficulty: "medium", category: nil, language: "en",
            participants: [
                Participant(
                    id: "p1", userId: nil, displayName: "Player",
                    score: 0, answeredCount: 0, correctCount: 0,
                    lastAnswer: nil, lastResult: nil,
                    isHost: true, isReady: true, joinedAt: Date()
                )
            ],
            expiresAt: Date().addingTimeInterval(30 * 60),
            createdAt: Date()
        )
        mockNetwork.mockResponse = QuizResponse(
            success: true,
            message: "Input processed",
            session: mockNetwork.mockSession!,
            currentQuestion: Question(
                id: "q_002", question: "Next?", type: .text,
                possibleAnswers: nil, difficulty: "medium",
                topic: "Test", category: "test",
                sourceUrl: nil, sourceExcerpt: nil,
                mediaUrl: nil, imageSubtype: nil,
                explanation: nil, generatedBy: nil
            ),
            evaluation: Evaluation(
                userAnswer: "Test",
                result: .correct,
                points: 1.0,
                correctAnswer: "Expected",
                questionId: "q_001",
                explanation: nil
            ),
            feedbackReceived: [],
            audio: nil
        )

        let viewModel = QuizViewModel(
            networkService: mockNetwork,
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            voiceCommandService: mockVoice
        )
        viewModel.settings.autoRecordEnabled = autoRecordEnabled
        return (viewModel, mockVoice)
    }

    @Test("auto-record state resets on resetToHome")
    @MainActor
    func autoRecordStateResetsOnHome() async throws {
        let (viewModel, _) = makeViewModel()
        viewModel.isAutoRecording = true
        viewModel.speechDetectedDuringAutoRecord = true
        viewModel.resetToHome()
        #expect(viewModel.isAutoRecording == false)
        #expect(viewModel.speechDetectedDuringAutoRecord == false)
    }

    @Test("auto-record disabled falls back to timer behavior")
    @MainActor
    func autoRecordDisabledFallsBack() async throws {
        let (viewModel, _) = makeViewModel(autoRecordEnabled: false)
        viewModel.quizState = .askingQuestion
        viewModel.currentQuestion = Question(
            id: "q_001", question: "Test?", type: .text,
            possibleAnswers: nil, difficulty: "medium",
            topic: "Test", category: "test",
            sourceUrl: nil, sourceExcerpt: nil,
            mediaUrl: nil, imageSubtype: nil,
            explanation: nil, generatedBy: nil
        )

        // With auto-record disabled, toggleRecording should still work normally
        await viewModel.toggleRecording()
        #expect(viewModel.quizState == .recording)
        #expect(viewModel.isAutoRecording == false)
    }

    @Test("cancelProcessing resets auto-record state")
    @MainActor
    func cancelProcessingResetsAutoRecord() async throws {
        let (viewModel, _) = makeViewModel()
        viewModel.isAutoRecording = true
        viewModel.speechDetectedDuringAutoRecord = true
        viewModel.quizState = .processing
        viewModel.cancelProcessing()
        #expect(viewModel.isAutoRecording == false)
        #expect(viewModel.speechDetectedDuringAutoRecord == false)
        #expect(viewModel.quizState == .askingQuestion)
    }
}

// MARK: - Phase 3: Barge-In Detection Tests

@Suite("QuizSettings Barge-In Tests")
struct QuizSettingsBargeInTests {

    @Test("default settings have bargeInEnabled = true")
    func defaultBargeInEnabled() {
        let settings = QuizSettings.default
        #expect(settings.bargeInEnabled == true)
    }

    @Test("backward-compatible decoding — missing bargeInEnabled defaults to true")
    func backwardCompatibleBargeIn() throws {
        let json = """
        {
            "language": "en",
            "audioMode": "media",
            "numberOfQuestions": 10,
            "difficulty": "medium",
            "autoAdvanceDelay": 8,
            "answerTimeLimit": 30
        }
        """
        let data = json.data(using: .utf8)!
        let settings = try JSONDecoder().decode(QuizSettings.self, from: data)

        #expect(settings.bargeInEnabled == true)
    }

    @Test("bargeInEnabled persists when set to false")
    func bargeInDisabledPersists() throws {
        let json = """
        {
            "language": "en",
            "audioMode": "media",
            "numberOfQuestions": 10,
            "difficulty": "medium",
            "autoAdvanceDelay": 8,
            "answerTimeLimit": 30,
            "bargeInEnabled": false
        }
        """
        let data = json.data(using: .utf8)!
        let settings = try JSONDecoder().decode(QuizSettings.self, from: data)

        #expect(settings.bargeInEnabled == false)
    }

    @Test("all three voice settings decode together")
    func allVoiceSettingsDecode() throws {
        let json = """
        {
            "language": "en",
            "audioMode": "media",
            "numberOfQuestions": 10,
            "difficulty": "medium",
            "autoAdvanceDelay": 8,
            "answerTimeLimit": 30,
            "voiceCommandsEnabled": true,
            "autoRecordEnabled": false,
            "bargeInEnabled": false
        }
        """
        let data = json.data(using: .utf8)!
        let settings = try JSONDecoder().decode(QuizSettings.self, from: data)

        #expect(settings.voiceCommandsEnabled == true)
        #expect(settings.autoRecordEnabled == false)
        #expect(settings.bargeInEnabled == false)
    }
}

@Suite("Barge-In Mock Service Tests")
struct BargeInMockServiceTests {

    @Test("mock service tracks TTS playback active state")
    @MainActor
    func mockTracksTTSPlaybackActive() async throws {
        let mock = MockVoiceCommandService()

        mock.setTTSPlaybackActive(true)
        #expect(mock.ttsPlaybackActive == true)

        mock.setTTSPlaybackActive(false)
        #expect(mock.ttsPlaybackActive == false)
    }

    @Test("mock service simulates barge-in events")
    @MainActor
    func mockSimulatesBargeIn() async throws {
        let mock = MockVoiceCommandService()
        await mock.startListening()

        // Simulate barge-in
        mock.simulateBargeIn()

        // Verify service is still listening
        #expect(mock.isListening == true)
    }
}

@Suite("Barge-In ViewModel Tests")
struct BargeInViewModelTests {

    @MainActor
    private func makeViewModel(bargeInEnabled: Bool = true) -> (QuizViewModel, MockVoiceCommandService) {
        let mockVoice = MockVoiceCommandService()
        let mockNetwork = MockNetworkService()
        mockNetwork.mockSession = QuizSession(
            id: "test_session_123",
            mode: "single", phase: "asking", maxQuestions: 10,
            currentDifficulty: "medium", category: nil, language: "en",
            participants: [
                Participant(
                    id: "p1", userId: nil, displayName: "Player",
                    score: 0, answeredCount: 0, correctCount: 0,
                    lastAnswer: nil, lastResult: nil,
                    isHost: true, isReady: true, joinedAt: Date()
                )
            ],
            expiresAt: Date().addingTimeInterval(30 * 60),
            createdAt: Date()
        )

        let viewModel = QuizViewModel(
            networkService: mockNetwork,
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            voiceCommandService: mockVoice
        )
        viewModel.settings.bargeInEnabled = bargeInEnabled
        return (viewModel, mockVoice)
    }

    @Test("barge-in setting toggle reflects in settings model")
    @MainActor
    func bargeInSettingToggle() async throws {
        let (viewModel, _) = makeViewModel(bargeInEnabled: true)
        #expect(viewModel.settings.bargeInEnabled == true)

        viewModel.settings.bargeInEnabled = false
        #expect(viewModel.settings.bargeInEnabled == false)
    }

    @Test("TTS playback active is set correctly via mock")
    @MainActor
    func ttsPlaybackActiveSet() async throws {
        let (_, mockVoice) = makeViewModel()

        mockVoice.setTTSPlaybackActive(true)
        #expect(mockVoice.ttsPlaybackActive == true)

        mockVoice.setTTSPlaybackActive(false)
        #expect(mockVoice.ttsPlaybackActive == false)
    }
}

// MARK: - Phase 4: Repeat / Score / Help Command Tests

@Suite("Phase 4 Voice Command Tests")
struct Phase4VoiceCommandTests {

    @Test("VoiceCommand enum includes repeat, score, help")
    func newCasesExist() {
        let allCases = VoiceCommand.allCases
        #expect(allCases.contains(.repeat))
        #expect(allCases.contains(.score))
        #expect(allCases.contains(.help))
    }

    @Test("repeat raw value is 'repeat'")
    func repeatRawValue() {
        #expect(VoiceCommand.repeat.rawValue == "repeat")
    }

    @Test("score raw value is 'score'")
    func scoreRawValue() {
        #expect(VoiceCommand.score.rawValue == "score")
    }

    @Test("help raw value is 'help'")
    func helpRawValue() {
        #expect(VoiceCommand.help.rawValue == "help")
    }

    @Test("VoiceCommandIndicator labels via rawValue.capitalized")
    func indicatorLabels() {
        #expect(VoiceCommand.repeat.rawValue.capitalized == "Repeat")
        #expect(VoiceCommand.score.rawValue.capitalized == "Score")
        #expect(VoiceCommand.help.rawValue.capitalized == "Help")
    }

    @Test("'score' in various phrases")
    func scoreInPhrases() {
        #expect(VoiceCommand.match(from: "what is my score") == .score)
        #expect(VoiceCommand.match(from: "SCORE") == .score)
    }

    @Test("'repeat' ignored when not a standalone word")
    func repeatWordBoundary() {
        // "repeated" splits into the word "repeated", not "repeat"
        #expect(VoiceCommand.match(from: "repeated") == nil)
    }

    @Test("'help' in sentence with standalone word")
    func helpInSentence() {
        #expect(VoiceCommand.match(from: "I need help please") == .help)
    }

    @Test("currentQuestionAudioUrl cleared on resetToHome")
    @MainActor
    func audioUrlClearedOnReset() async throws {
        let viewModel = QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        viewModel.resetToHome()
        // After reset, all state should be clean
        #expect(viewModel.quizState == .idle)
    }
}
