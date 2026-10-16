//
//  QuizResponse.swift
//  Hangs
//
//  API response wrapper matching backend API
//

@preconcurrency import Foundation

/// Response from quiz-related API endpoints
struct QuizResponse: Codable, Sendable {
    let success: Bool
    let message: String
    let session: QuizSession
    let currentQuestion: Question?
    let evaluation: Evaluation?
    let feedbackReceived: [String]
    let audio: AudioInfo?
    /// #182: the custom pack is still generating and the next question is not
    /// ready yet — `currentQuestion` is nil, the session phase stays `asking`,
    /// and the quiz is NOT finished. The client polls
    /// `POST /sessions/{id}/next-question` until a question (or a finished
    /// session) lands. Absent on every pre-#182 response → false.
    let awaitingQuestion: Bool
    /// #205: the crowd strip of a daily-challenge answer. Absent = no strip
    /// (a wrong answer most others knew, or not a daily round).
    let crowd: CrowdStrip?
    /// #208.3: the "you said" read-back the server synthesized while grading a
    /// voice answer (only when the submit asked for it with `read_back=true`).
    /// Absent = synthesize it with `POST /tts/synthesize` as before.
    let readBack: ReadBackAudio?

    enum CodingKeys: String, CodingKey {
        case success
        case message
        case session
        case currentQuestion = "current_question"
        case evaluation
        case feedbackReceived = "feedback_received"
        case audio
        case awaitingQuestion = "awaiting_question"
        case crowd
        case readBack = "read_back"
    }

    init(
        success: Bool,
        message: String,
        session: QuizSession,
        currentQuestion: Question?,
        evaluation: Evaluation?,
        feedbackReceived: [String],
        audio: AudioInfo?,
        awaitingQuestion: Bool = false,
        crowd: CrowdStrip? = nil,
        readBack: ReadBackAudio? = nil
    ) {
        self.success = success
        self.message = message
        self.session = session
        self.currentQuestion = currentQuestion
        self.evaluation = evaluation
        self.feedbackReceived = feedbackReceived
        self.audio = audio
        self.awaitingQuestion = awaitingQuestion
        self.crowd = crowd
        self.readBack = readBack
    }

    /// Hand-written so a missing `awaiting_question` decodes as `false` — the
    /// synthesised initialiser would throw `keyNotFound` on every response from
    /// a backend that predates #182. Everything else keeps the default shape.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = try container.decode(Bool.self, forKey: .success)
        message = try container.decode(String.self, forKey: .message)
        session = try container.decode(QuizSession.self, forKey: .session)
        currentQuestion = try container.decodeIfPresent(Question.self, forKey: .currentQuestion)
        evaluation = try container.decodeIfPresent(Evaluation.self, forKey: .evaluation)
        feedbackReceived = try container.decodeIfPresent([String].self, forKey: .feedbackReceived) ?? []
        audio = try container.decodeIfPresent(AudioInfo.self, forKey: .audio)
        awaitingQuestion = try container.decodeIfPresent(Bool.self, forKey: .awaitingQuestion) ?? false
        // #205: never the reason an answer is lost — an unreadable strip is no strip.
        crowd = try? container.decodeIfPresent(CrowdStrip.self, forKey: .crowd)
        // #208.3: an optional speed-up — an unreadable one falls back to TTS.
        readBack = try? container.decodeIfPresent(ReadBackAudio.self, forKey: .readBack)
    }
}

/// #208.3 `ReadBackAudio` (backend `api/deps.py`): the confirmation read-back,
/// synthesized during grading. Play it only while the sheet still shows
/// exactly `text` (= `evaluation.userAnswer`).
struct ReadBackAudio: Codable, Sendable, Equatable {
    let text: String
    let audioBase64: String
    let format: String

    enum CodingKeys: String, CodingKey {
        case text
        case audioBase64 = "audio_base64"
        case format
    }
}

extension QuizResponse {
    /// Check if there's a new question to display
    var hasNextQuestion: Bool {
        currentQuestion != nil
    }

    /// Check if answer was evaluated
    var hasEvaluation: Bool {
        evaluation != nil
    }

    /// Check if quiz is finished
    var isQuizFinished: Bool {
        session.isFinished
    }

    /// Get current participant score (single player)
    var currentScore: Double {
        session.participants.first?.score ?? 0.0
    }

    /// Get current participant answered count
    var questionsAnswered: Int {
        session.participants.first?.answeredCount ?? 0
    }
}

// MARK: - Preview Helpers

#if DEBUG
    extension QuizResponse {
        static let previewStartQuiz = QuizResponse(
            success: true,
            message: "Quiz started",
            session: QuizSession(
                id: "sess_preview_123",
                mode: "single",
                phase: "asking",
                maxQuestions: 10,
                currentDifficulty: "medium",
                category: nil,
                language: "en",
                participants: [
                    Participant(
                        id: "p_preview_1",
                        userId: nil,
                        displayName: "Player",
                        score: 0.0,
                        answeredCount: 0,
                        correctCount: 0,
                        lastAnswer: nil,
                        lastResult: nil,
                        isHost: true,
                        isReady: true,
                        joinedAt: Date()
                    ),
                ],
                expiresAt: Date().addingTimeInterval(30 * 60),
                createdAt: Date()
            ),
            currentQuestion: Question.preview,
            evaluation: nil,
            feedbackReceived: [],
            audio: AudioInfo(
                feedbackUrl: nil,
                feedbackAudioBase64: nil,
                questionUrl: "/api/v1/sessions/sess_preview_123/question/audio",
                format: "opus"
            )
        )

        static let previewAnswerIncorrect = QuizResponse(
            success: true,
            message: "Input processed",
            session: QuizSession(
                id: "sess_preview_123",
                mode: "single",
                phase: "asking",
                maxQuestions: 10,
                currentDifficulty: "medium",
                category: nil,
                language: "en",
                participants: [
                    Participant(
                        id: "p_preview_1",
                        userId: nil,
                        displayName: "Player",
                        score: 0.0,
                        answeredCount: 1,
                        correctCount: 0,
                        lastAnswer: "London",
                        lastResult: "incorrect",
                        isHost: true,
                        isReady: true,
                        joinedAt: Date()
                    ),
                ],
                expiresAt: Date().addingTimeInterval(30 * 60),
                createdAt: Date()
            ),
            currentQuestion: Question.previewHard,
            evaluation: Evaluation.previewIncorrect,
            feedbackReceived: ["answer: incorrect"],
            audio: AudioInfo(
                feedbackUrl: "/api/v1/tts/feedback/incorrect",
                feedbackAudioBase64: nil,
                questionUrl: "/api/v1/sessions/sess_preview_123/question/audio",
                format: "opus"
            )
        )

        static let previewAnswerCorrect = QuizResponse(
            success: true,
            message: "Input processed",
            session: QuizSession(
                id: "sess_preview_123",
                mode: "single",
                phase: "asking",
                maxQuestions: 10,
                currentDifficulty: "medium",
                category: nil,
                language: "en",
                participants: [
                    Participant(
                        id: "p_preview_1",
                        userId: nil,
                        displayName: "Player",
                        score: 1.0,
                        answeredCount: 1,
                        correctCount: 1,
                        lastAnswer: "Paris",
                        lastResult: "correct",
                        isHost: true,
                        isReady: true,
                        joinedAt: Date()
                    ),
                ],
                expiresAt: Date().addingTimeInterval(30 * 60),
                createdAt: Date()
            ),
            currentQuestion: Question.previewHard,
            evaluation: Evaluation.previewCorrect,
            feedbackReceived: ["answer: correct"],
            audio: AudioInfo(
                feedbackUrl: "/api/v1/tts/feedback/correct",
                feedbackAudioBase64: nil,
                questionUrl: "/api/v1/sessions/sess_preview_123/question/audio",
                format: "opus"
            )
        )

        /// Long-question variant of previewStartQuiz — used by `--ui-test-long`
        /// in UITestSupport to guard the voice-body overflow regression (54.2).
        static let previewStartQuizLong = QuizResponse(
            success: true,
            message: "Quiz started",
            session: QuizSession(
                id: "sess_preview_123",
                mode: "single",
                phase: "asking",
                maxQuestions: 10,
                currentDifficulty: "medium",
                category: nil,
                language: "en",
                participants: [
                    Participant(
                        id: "p_preview_1",
                        userId: nil,
                        displayName: "Player",
                        score: 0.0,
                        answeredCount: 0,
                        correctCount: 0,
                        lastAnswer: nil,
                        lastResult: nil,
                        isHost: true,
                        isReady: true,
                        joinedAt: Date()
                    ),
                ],
                expiresAt: Date().addingTimeInterval(30 * 60),
                createdAt: Date()
            ),
            currentQuestion: Question.previewLong,
            evaluation: nil,
            feedbackReceived: [],
            audio: AudioInfo(
                feedbackUrl: nil,
                feedbackAudioBase64: nil,
                questionUrl: "/api/v1/sessions/sess_preview_123/question/audio",
                format: "opus"
            )
        )

        /// MCQ variant of previewStartQuiz — used by `--ui-test-mcq` in UITestSupport.
        /// Question: "What is the largest planet?" options a=Mars b=Jupiter c=Saturn d=Neptune
        static let previewStartQuizMCQ = QuizResponse(
            success: true,
            message: "Quiz started",
            session: QuizSession(
                id: "sess_preview_123",
                mode: "single",
                phase: "asking",
                maxQuestions: 10,
                currentDifficulty: "medium",
                category: nil,
                language: "en",
                participants: [
                    Participant(
                        id: "p_preview_1",
                        userId: nil,
                        displayName: "Player",
                        score: 0.0,
                        answeredCount: 0,
                        correctCount: 0,
                        lastAnswer: nil,
                        lastResult: nil,
                        isHost: true,
                        isReady: true,
                        joinedAt: Date()
                    ),
                ],
                expiresAt: Date().addingTimeInterval(30 * 60),
                createdAt: Date()
            ),
            currentQuestion: Question.previewMCQ,
            evaluation: nil,
            feedbackReceived: [],
            audio: AudioInfo(
                feedbackUrl: nil,
                feedbackAudioBase64: nil,
                questionUrl: "/api/v1/sessions/sess_preview_123/question/audio",
                format: "opus"
            )
        )

        /// Long-stem MCQ variant — seeded when `--ui-test-mcq` and `--ui-test-long`
        /// are passed together (#125). Guards the MCQ counterpart of the 54.2
        /// squeeze plus the reveal gate: pre-reveal the stem must be legible and
        /// the option cards absent.
        static let previewStartQuizMCQLong = QuizResponse(
            success: true,
            message: "Quiz started",
            session: QuizResponse.previewStartQuizMCQ.session,
            currentQuestion: Question.previewMCQLong,
            evaluation: nil,
            feedbackReceived: [],
            audio: AudioInfo(
                feedbackUrl: nil,
                feedbackAudioBase64: nil,
                questionUrl: "/api/v1/sessions/sess_preview_123/question/audio",
                format: "opus"
            )
        )

        /// Long-OPTION MCQ variant — seeded by `--ui-test-mcq-long-options`
        /// (#179 finding 10). The stem is ordinary here; it is the four
        /// multi-line options that ate the screen and carried the skip chip off
        /// the bottom with them.
        static let previewStartQuizMCQLongOptions = QuizResponse(
            success: true,
            message: "Quiz started",
            session: QuizResponse.previewStartQuizMCQ.session,
            currentQuestion: Question.previewMCQLongOptions,
            evaluation: nil,
            feedbackReceived: [],
            audio: AudioInfo(
                feedbackUrl: nil,
                feedbackAudioBase64: nil,
                questionUrl: "/api/v1/sessions/sess_preview_123/question/audio",
                format: "opus"
            )
        )
    }
#endif
