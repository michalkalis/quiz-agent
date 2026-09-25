//
//  QuestionListenBar.swift
//  Hangs
//
//  #179 D1, variant A (founder pick 2026-09-15, `docs/design/ui-variants-2026-09-14-decisions.md`).
//
//  The question screen used to speak four different bar languages: on MCQ there
//  was no bar at all while the question was being read, on an open question the
//  countdown hid inside the Start button, and on BOTH the bar vanished the moment
//  an answer was submitted — which the founder read as "the screen froze" (TF
//  build 61). This type is the fix: ONE state model, four states, rendered
//  identically for both question types.
//
//   1 `.readingQuestion` — the TTS is reading. Commands "repeat" / "skip".
//   2 `.thinking`        — the think window drains as a fill inside the bar
//                          (#132 B). Commands "start" / "repeat" / "skip".
//   3 `.listening`       — the answer mic is open. NO command chips: the app
//                          listens for EITHER commands or an answer, never both
//                          (founder, 2026-07-28), so a chip here would offer a
//                          word that cannot be heard.
//   4 `.evaluating`      — the answer is being graded. A grey status line with a
//                          spinner; the bar's whole job here is to prove the app
//                          is working.
//   4' `.skipping`       — same grey + spinner, but it says what is actually
//                          happening: nothing was answered, the next question is
//                          being fetched (#181 finding 4 — "Evaluating your
//                          answer" after Skip was a lie the founder noticed).
//
//  The bar never disappears across the four (the ✕ is still the only way to hide
//  it, and only for the question on screen — #173 B1).
//

import SwiftUI

/// The four states of the question screen's listening bar. Derived from the quiz
/// state machine by `current(…)` so MCQ and open questions cannot drift apart:
/// both call sites ask the same function the same question.
enum QuestionListenPhase: Equatable {
    case readingQuestion
    case thinking(remaining: Int, total: Int)
    case listening(ListenBar.AnswerKind)
    case evaluating
    case skipping

    /// The phase for a quiz state, or `nil` when the question screen shows no bar
    /// at all (it is not the driver's turn — starting, results, finished, error).
    ///
    /// Pure on purpose: the founder's complaint was about which state shows what,
    /// and that mapping must be assertable without rendering either body.
    static func current(
        quizState: QuizState,
        answerWindowRemaining: Int,
        answerWindowTotal: Int,
        answerKind: ListenBar.AnswerKind
    ) -> QuestionListenPhase? {
        switch quizState {
        case .recording:
            return .listening(answerKind)
        case .processing:
            return .evaluating
        // #181: a skip grades nothing, and the bar must not claim it does.
        case .skipping:
            return .skipping
        case .askingQuestion:
            // No window running yet = the question is still being read: the think
            // countdown only starts once the TTS finishes.
            guard answerWindowRemaining > 0 else { return .readingQuestion }
            return .thinking(remaining: answerWindowRemaining, total: answerWindowTotal)
        // #182 `.awaitingQuestion`: nothing to listen for — there is no question
        // on screen yet, and the waiting panel speaks for itself.
        case .idle, .startingQuiz, .awaitingQuestion, .showingResult, .finished, .error:
            return nil
        }
    }

    /// The commands this state actually routes, in the order the driver reads
    /// them. `.question` routes start / repeat / skip (`VoiceCommandLexicon`), but
    /// "start" is deliberately withheld while the question is being read — saying
    /// it there opens the mic over the rest of the sentence.
    var commands: [VoiceCommand] {
        switch self {
        case .readingQuestion: return [.repeatQuestion, .skip]
        case .thinking: return [.start, .repeatQuestion, .skip]
        case .listening, .evaluating, .skipping: return []
        }
    }

    /// The `ListenBar` mode this state renders as.
    var barMode: ListenBar.Mode {
        switch self {
        case .readingQuestion: return .readingQuestion
        case .thinking: return .command
        case let .listening(kind): return .answer(kind)
        case .evaluating: return .evaluating
        case .skipping: return .skipping
        }
    }

    /// The draining fill, iff this state has a window to drain (#132 B).
    var countdown: ListenBar.ThinkCountdown? {
        guard case let .thinking(remaining, total) = self else { return nil }
        return .init(remaining: remaining, total: total)
    }

    /// The ✕ belongs to the states the driver can still act in. While the answer
    /// is graded there is nothing to dismiss — and the bar is the only thing on
    /// screen saying the app is alive.
    var isDismissable: Bool { self != .evaluating && self != .skipping }
}

/// `ListenBar` wired to one `QuestionListenPhase` — the single call the MCQ body
/// and the open-question footer both make, so the two screens cannot render the
/// same state differently again.
struct QuestionListenBar: View {
    let phase: QuestionListenPhase

    /// #122 Variant C transient tint.
    var feedback: VoiceFeedbackPhase = .idle

    /// Whether the command words may be shown at all: the Settings toggle AND an
    /// armed listener. A chip is a promise that the word will be heard.
    var showsWords: Bool = true

    var size: ListenBar.Size = .full
    var language: CommandLanguage = .english

    /// #185 track F: the recording has heard the driver ("Capturing…").
    var speechHeard: Bool = false

    /// #185 track F: the live mic level the bar breathes with while listening.
    var inputLevel: RecordingInputLevel? = nil

    var onDismiss: (() -> Void)? = nil

    private var words: [String] {
        guard showsWords else { return [] }
        return VoiceCommandLexicon.spokenChips(phase.commands, language: language)
    }

    var body: some View {
        ListenBar(
            mode: phase.barMode,
            feedback: feedback,
            commandWords: words,
            size: size,
            language: language,
            thinkCountdown: phase.countdown,
            speechHeard: speechHeard,
            inputLevel: inputLevel,
            onDismiss: phase.isDismissable ? onDismiss : nil
        )
    }
}

#if DEBUG
    #Preview {
        VStack(spacing: 16) {
            ForEach(Array([
                QuestionListenPhase.readingQuestion,
                .thinking(remaining: 32, total: 45),
                .listening(.mcq),
                .evaluating,
            ].enumerated()), id: \.offset) { _, phase in
                QuestionListenBar(phase: phase, language: .slovak, onDismiss: {})
                    .padding(.horizontal, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Hangs.Colors.bg)
    }
#endif
