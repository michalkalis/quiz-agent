//
//  QuizViewModel+SharedQuiz.swift
//  Hangs
//
//  #232 — share a quiz by link. The friend's round plays through the
//  ordinary quiz flow; the start lives in `startNewQuiz(shared:)`.
//

import Foundation

extension QuizViewModel {
    /// A friend's link (tapped, or pasted on the first launch): the shared
    /// quiz starts right away. The mic is asked for as at every start.
    @discardableResult
    func beginSharedQuiz(token: String) -> Task<Void, Never> {
        beginQuizStart(shared: token)
    }

    func dismissSharedQuizNotice() {
        sharedQuizNotice = nil
    }

    /// #232: a finished custom pack to a friend (Home's pack menu). The share
    /// sheet opens once the link exists; a failure shows as the notice.
    @discardableResult
    func sendPack(packId: String) -> Task<Void, Never> {
        let share = SharedQuizShareModel(network: networkService, source: .pack(packId))
        return Task {
            await share.send { SharedQuizMessage.pack(questionCount: $0.questionCount, url: $0.url) }.value
            if let failure = share.failureMessage { sharedQuizNotice = failure }
        }
    }

    /// The finished solo round can be sent on: the switch is on, the round
    /// has a server session and it was not a friend's link (that round end
    /// sends the same link on instead).
    var shareableRoundSessionId: String? {
        guard sharedQuizEnabled(), activeShare == nil, let id = currentSession?.id else { return nil }
        return id
    }
}
