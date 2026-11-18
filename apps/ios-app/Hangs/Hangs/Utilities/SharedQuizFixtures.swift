//
//  SharedQuizFixtures.swift
//  Hangs
//
//  #232: the `--ui-test` mock graph's side of a shared quiz link (RS-33).
//  Combine with `--app-config-shared-quiz` (the server switch):
//
//    (no flag)                       a friend's link plays the mock quiz
//    --ui-test-shared-quiz-played    the link was played already: its comparison
//    --ui-test-shared-quiz-own       the sender opens their own link: its comparison
//

#if DEBUG

    import Foundation

    enum SharedQuizFixtures {
        static let token = "rs33-shared-quiz"

        static func configure(_ network: MockNetworkService, arguments: [String] = CommandLine.arguments) {
            let own = arguments.contains("--ui-test-shared-quiz-own")
            if arguments.contains("--ui-test-shared-quiz-played") {
                network.startSharedQuizError = NetworkError.sharedQuizUnavailable(.alreadyPlayed)
                network.stubbedShareResults = results(viewerIsSender: false)
            } else if own {
                network.stubbedShareResults = results(viewerIsSender: true)
            }
        }

        static func results(viewerIsSender: Bool) -> SharedQuizResults {
            SharedQuizResults(
                kind: "round",
                language: "sk",
                title: nil,
                categories: ["history"],
                questionCount: 5,
                players: [
                    SharedQuizPlayer(name: "Rýchly gepard", score: 4, total: 5, isSender: !viewerIsSender, isYou: !viewerIsSender,
                                     marks: [true, true, false, true, true]),
                    SharedQuizPlayer(name: "Michal", score: 3, total: 5, isSender: viewerIsSender, isYou: viewerIsSender,
                                     marks: [true, false, true, false, true]),
                ]
            )
        }
    }

#endif
