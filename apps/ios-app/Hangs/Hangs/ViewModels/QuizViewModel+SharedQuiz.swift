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
    /// quiz starts right away. The mic is asked for as at every start. The
    /// sender's own link opens its comparison instead: that is where the
    /// sender sees how friends did, after leaving the round end.
    @discardableResult
    func beginSharedQuiz(token: String) -> Task<Void, Never> {
        let task = Task {
            if await isOwnSharedQuiz(token: token) {
                sharedQuizComparison = SharedQuizPlay(token: token)
                return
            }
            await startNewQuiz(shared: token)
        }
        taskBag.add(task, key: .quizStart)
        return task
    }

    /// The server lists the viewer as the link's sender. Any failure (a
    /// friend's first open is a 404 here) means: play it.
    private func isOwnSharedQuiz(token: String) async -> Bool {
        guard let results = try? await networkService.sharedQuizResults(token: token) else { return false }
        return results.players.contains { $0.isSender && $0.isYou }
    }

    func dismissSharedQuizComparison() {
        sharedQuizComparison = nil
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
