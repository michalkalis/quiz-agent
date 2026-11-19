//
//  QuizViewModel+QuotaRoundEnd.swift
//  Hangs
//
//  #240.9 (founder 2026-11-18): the monthly limit reached on an answer
//  mid-round. The server graded that answer and sent the verdict with its
//  429, but the app dropped it and jumped straight to the paywall: the player
//  never heard whether the last answer was right and never saw the round's
//  score. Now the verdict shows like any other, the round ends on its own
//  screen, and the paywall comes after it.
//

import Foundation

extension QuizViewModel {
    /// Ends the round on the verdict the 429 carried. False when it carried
    /// none (an older server, the start gate) or nothing is waiting for it:
    /// the caller keeps the plain paywall path then.
    func finishRoundWithLastVerdict(_ limit: QuotaLimitError) async -> Bool {
        guard let evaluation = limit.evaluation,
              quizState == .processing || quizState == .skipping,
              let session = currentSession,
              currentQuestion != nil
        else { return false }
        attemptLedger.record(.network, "quota.lastVerdict", evaluation.result.rawValue)
        roundEndQuotaLimit = limit
        await handleQuizResponse(QuizResponse(
            success: true,
            message: "",
            session: session.finishedByQuota(scoring: evaluation),
            currentQuestion: nil,
            evaluation: evaluation,
            feedbackReceived: [],
            audio: nil
        ))
        return true
    }

    /// The end-of-round screen without a spoken score (end-of-set recap):
    /// the paywall still waits until the player has seen it.
    func scheduleRoundEndPaywall(_ limit: QuotaLimitError) {
        taskBag.add(Task { [weak self] in
            await self?.showRoundEndPaywall(limit)
        }, key: .roundEndPaywall)
    }

    /// A short look at the round's score, then the limit line and the paywall
    /// over the end-of-round screen (closing it lands back there). Leaving
    /// the screen first cancels it: Play again meets the start gate anyway.
    func showRoundEndPaywall(_ limit: QuotaLimitError) async {
        try? await clock.sleep(for: .seconds(Config.roundEndPaywallDelay))
        guard !Task.isCancelled, quizState == .finished else { return }
        let entitled = limit.upgradeAvailable
            ? await entitlementReconciler.resyncBeforePaywallIfLocallyEntitled()
            : false
        guard !entitled, !Task.isCancelled, quizState == .finished else { return }
        await announceQuotaReached(upgradeAvailable: limit.upgradeAvailable)
        guard !Task.isCancelled, quizState == .finished else { return }
        entitlementReconciler.presentQuotaPaywall(limit)
        trackAnalytics(.paywallViewed(source: .quota))
    }
}
