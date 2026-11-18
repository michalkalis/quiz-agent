//
//  QuizViewModel+SharedQuiz.swift
//  Hangs
//
//  #232 — share a quiz by link. The friend's round plays through the
//  ordinary quiz flow; the start lives in `startNewQuiz(shared:)`.
//

import Foundation

extension QuizViewModel {
    /// #235 F7: how long the "is this my own link?" question may hold the
    /// start. Slower or failed means: play it.
    static let sharedQuizOwnerCheckSeconds = 3

    /// A friend's link (tapped, or pasted on the first launch): the shared
    /// quiz starts right away. The mic is asked for as at every start. The
    /// sender's own link opens its comparison instead (decided inside
    /// `startNewQuiz`, so Home shows the start's spinner and Cancel at once).
    @discardableResult
    func beginSharedQuiz(token: String) -> Task<Void, Never> {
        let running = taskBag.task(for: .quizStart)
        // The same link already starting (opened twice): that start plays it (#235.2).
        if let running, isStarting, activeShare?.token == token { return running }
        let task = Task {
            // Another start gives way first: its cancel lands on Home, then the link plays.
            await running?.value
            guard !Task.isCancelled else { return }
            await startNewQuiz(shared: token)
        }
        taskBag.add(task, key: .quizStart)
        return task
    }

    /// The server lists the viewer as the link's sender. Any failure (a
    /// friend's first open is a 404 here) or an answer slower than
    /// `sharedQuizOwnerCheckSeconds` means: play it. A sender whose check was
    /// skipped is still safe: the server refuses a second play of a pack
    /// (the comparison opens) and gives a round its questions again without
    /// counting it.
    func isOwnSharedQuiz(token: String) async -> Bool {
        let results = try? await withUserFacingTimeout(seconds: Self.sharedQuizOwnerCheckSeconds, clock: clock) {
            try await self.networkService.sharedQuizResults(token: token)
        }
        return results?.players.contains { $0.isSender && $0.isYou } ?? false
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
