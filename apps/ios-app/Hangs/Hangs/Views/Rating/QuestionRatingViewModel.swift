//
//  QuestionRatingViewModel.swift
//  Hangs
//
//  Drives the TestFlight-only question rating panel (#155): a 1–10 score
//  (higher = better) plus an optional spoken/typed justification, posted to the
//  canonical #154 rating store on quiz-pack-api.
//
//  Rating-only by construction: this type holds NO reference to QuizViewModel
//  and calls nothing on it — submitting or cancelling cannot move the quiz
//  state machine, change scoring, or touch TTS. The only quiz coupling is the
//  read-only `isQuizRecording` probe inside `FeedbackVoiceServices`, which
//  keeps dictation off the shared mic while the quiz holds it.
//
//  Dictation lives in QuestionRatingViewModel+Dictation.swift.
//

import Combine
import Foundation
import os

/// Identifiable holder so a freshly-built view model can drive a
/// `.sheet(item:)` — same pattern as `FeedbackPresentation` (#109). Keeping the
/// VM's identity stable across body re-evaluations is what stops a typed
/// justification from being wiped on every redraw.
struct QuestionRatingPresentation: Identifiable {
    let id = UUID()
    let viewModel: QuestionRatingViewModel
}

@MainActor
final class QuestionRatingViewModel: ObservableObject {
    enum SubmitState: Equatable {
        case idle
        case submitting
        case saved
        case failed(String)
    }

    /// Live-transcript state of the mic (mirrors `FeedbackViewModel.MicState`).
    enum MicState: Equatable {
        case idle
        case dictating
        case denied
    }

    /// The #154 scale: 1…10, higher = better. Kept here so the panel and the
    /// tests read the same range the backend validates against.
    static let scoreRange = 1 ... 10

    /// The justification. Editable text at all times — dictation appends to it
    /// rather than owning it, so a wrong transcript can simply be corrected.
    @Published var justification: String = ""
    @Published private(set) var selectedScore: Int?
    @Published private(set) var submitState: SubmitState = .idle

    // Dictation-owned state. Internal setters (not `private(set)`) because the
    // dictation extension lives in a sibling file.
    @Published var micState: MicState = .idle
    /// The in-flight (uncommitted) transcript, shown live while the user speaks.
    @Published var partialTranscript: String = ""
    /// Set when the dictation cap auto-stops a recording, so the UI can hint why.
    @Published var didHitDictationCap = false

    /// The question being rated — captured at open time so a quiz that advances
    /// underneath the sheet can never re-target the rating at a later question.
    let questionId: String
    let questionText: String?

    let ratingService: QuestionRatingServiceProtocol
    let networkService: NetworkServiceProtocol
    let voice: FeedbackVoiceServices?

    /// Hard cap for a single dictation. Injectable so tests drive the auto-stop
    /// without waiting the production 120 s.
    var maxDictationSeconds: TimeInterval = Config.feedbackDictationCapSecs

    var eventListenerTask: Task<Void, Never>?
    var capTask: Task<Void, Never>?
    /// Observes audio-session interruptions (phone call, Siri) WHILE this sheet
    /// holds the shared mic — see the same guard in `FeedbackViewModel`.
    var interruptionObserver: NSObjectProtocol?

    init(
        questionId: String,
        questionText: String? = nil,
        ratingService: QuestionRatingServiceProtocol,
        networkService: NetworkServiceProtocol,
        voice: FeedbackVoiceServices? = nil
    ) {
        self.questionId = questionId
        self.questionText = questionText
        self.ratingService = ratingService
        self.networkService = networkService
        self.voice = voice
    }

    // MARK: - Score

    func select(score: Int) {
        guard Self.scoreRange.contains(score) else { return }
        selectedScore = score
        // A new score after a failed attempt clears the stale error.
        if case .failed = submitState { submitState = .idle }
    }

    func isSelected(score: Int) -> Bool { selectedScore == score }

    var isSubmitting: Bool { submitState == .submitting }

    /// A rating is meaningless without a score; the justification is optional.
    var canSubmit: Bool { selectedScore != nil && !isSubmitting && submitState != .saved }

    var errorMessage: String? {
        if case let .failed(reason) = submitState { return reason }
        return nil
    }

    // MARK: - Dictation availability

    /// Whether the panel offers dictation at all (false in previews / tests
    /// where no shared audio services were injected — text entry still works).
    var voiceAvailable: Bool { voice?.sttService != nil }

    var isDictating: Bool { micState == .dictating }

    /// The quiz is actively holding the shared mic, so dictation must stay
    /// blocked — one AVAudioEngine cannot serve both (#64/#77 crash class).
    var isBlockedByQuizRecording: Bool { voice?.isQuizRecording() ?? false }

    var micButtonDisabled: Bool {
        isBlockedByQuizRecording || isSubmitting || micState == .denied
    }

    // MARK: - Submit

    /// POST the rating. Failure surfaces inline and leaves the panel open with
    /// the score intact — nothing about the quiz is touched either way.
    func submit() async {
        // A tap on Save while still dictating finalizes the transcript first,
        // so the last spoken words land in the justification before the POST.
        if isDictating { await stopDictation() }

        guard let score = selectedScore, canSubmit else { return }
        submitState = .submitting

        let trimmed = justification.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await ratingService.submitRating(
                questionId: questionId,
                score: score,
                reason: trimmed.isEmpty ? nil : trimmed,
                // Identity is the JWT subject server-side; no cosmetic name is
                // sent (a hardcoded one would mislabel other TestFlight raters).
                displayName: nil
            )
            submitState = .saved
            Logger.network.info("⭐️ Question rating saved (score \(score, privacy: .public))")
        } catch {
            submitState = .failed(error.localizedDescription)
            Logger.network.warning("⚠️ Question rating failed: \(error, privacy: .public)")
        }
    }
}
