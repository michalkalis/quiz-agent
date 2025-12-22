//
//  QuizResponse.swift
//  CarQuiz
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

    enum CodingKeys: String, CodingKey {
        case success
        case message
        case session
        case currentQuestion = "current_question"
        case evaluation
        case feedbackReceived = "feedback_received"
        case audio
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
                )
            ],
            expiresAt: Date().addingTimeInterval(30 * 60),
            createdAt: Date()
        ),
        currentQuestion: Question.preview,
        evaluation: nil,
        feedbackReceived: [],
        audio: AudioInfo(
            feedbackUrl: nil,
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
                )
            ],
            expiresAt: Date().addingTimeInterval(30 * 60),
            createdAt: Date()
        ),
        currentQuestion: Question.previewHard,
        evaluation: Evaluation.previewCorrect,
        feedbackReceived: ["answer: correct"],
        audio: AudioInfo(
            feedbackUrl: "/api/v1/tts/feedback/correct",
            questionUrl: "/api/v1/sessions/sess_preview_123/question/audio",
            format: "opus"
        )
    )
}
#endif
