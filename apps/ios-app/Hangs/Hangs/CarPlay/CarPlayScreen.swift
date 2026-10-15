//
//  CarPlayScreen.swift
//  Hangs
//
//  #97 — CarPlay support. What the car's screen shows at a given quiz moment.
//  Kept free of CarPlay types so the mapping is unit-tested without a scene.
//
//  Apple's rules for voice-based conversational apps shape it: voice is the
//  interface, the screen only says what Trubbo is doing (never the question
//  or answer text), at most 5 states per voice template, at most 2 buttons
//  per state. Hence two templates: home (between rounds) and quiz (a round
//  is running).
//

#if CARPLAY
    enum CarPlayScreen: Equatable {
        case home(Home)
        case quiz(Quiz)

        enum Home: String, CaseIterable {
            case ready
            case finished
            case failed
            /// The free monthly questions are used up; the paywall is on the phone.
            case limitReached
        }

        enum Quiz: String, CaseIterable {
            /// Trubbo reads the question or the result.
            case speaking
            case listening
            /// Starting, checking the answer, skipping, waiting for a pack batch.
            case thinking
            /// The answer sheet: an answer to confirm, or nothing was heard.
            case confirming
            case paused
        }

        /// The slice of QuizViewModel the car screen depends on.
        struct Inputs: Equatable {
            var quizState: QuizState
            var isPaused: Bool
            var showAnswerConfirmation: Bool
            var showPaywall: Bool
        }

        init(_ inputs: Inputs) {
            if inputs.showPaywall {
                self = .home(.limitReached)
                return
            }
            switch inputs.quizState {
            case .idle:
                self = .home(.ready)
            case .finished:
                self = .home(.finished)
            case .error:
                self = .home(.failed)
            case .askingQuestion, .showingResult:
                self = .quiz(inputs.isPaused ? .paused : .speaking)
            case .recording:
                self = .quiz(inputs.isPaused ? .paused : .listening)
            case .processing where inputs.showAnswerConfirmation:
                self = .quiz(inputs.isPaused ? .paused : .confirming)
            case .startingQuiz, .awaitingQuestion, .processing, .skipping:
                self = .quiz(.thinking)
            }
        }
    }
#endif
