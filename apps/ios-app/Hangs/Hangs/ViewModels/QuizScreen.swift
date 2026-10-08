//
//  QuizScreen.swift
//  Hangs
//
//  The root screen for each quiz state — the routing ContentView renders.
//  Moved out of ContentView's switch in #194 A1 so the mapping is testable and
//  the redesign cannot reroute a state by restyling the root.
//

import Foundation

enum QuizScreen: Equatable {
    case home
    case question
    case result
    /// #132 E: an end-of-set reveal ends on the recap, not the score screen.
    case setRecap
    case completion
    case error(AppErrorModel)
}

extension QuizViewModel {
    var quizScreen: QuizScreen {
        switch quizState {
        // `.startingQuiz` stays on Home: with no `currentQuestion` yet the
        // question screen rendered only its chrome + a spinner (founder batch
        // 2026-07-12); Home's cancellable start control shows the loading.
        case .idle, .startingQuiz:
            return .home
        // #182: `.awaitingQuestion` stays on the question screen — the header and
        // counter keep standing while the pack catches up.
        case .askingQuestion, .awaitingQuestion, .recording, .processing, .skipping:
            return .question
        case .showingResult:
            return .result
        // #132 E: deferred reveal ends on the recap; an empty recap degrades to
        // the score screen (`endsOnRecap` requires entries).
        case .finished:
            return endsOnRecap ? .setRecap : .completion
        // `activeErrorModel` is built by setError (localised copy + context-correct
        // CTA — 54.15); the context fallback covers direct transitions.
        case let .error(_, context):
            return .error(activeErrorModel ?? AppErrorModel.from(context: context))
        }
    }
}
