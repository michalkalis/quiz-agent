//
//  QuizViewModel+VoiceAllowance.swift
//  Hangs
//
//  Free tier split (founder experiment 2026-11-21): a free player gets 150
//  questions a month, of which at most 30 may be answered by voice. Typed and
//  tapped answers do not use the voice answers. Founder decision D1: when they
//  are used up, the app says so ONCE (spoken and on the question screen, with
//  a quiet Plus link) and the quiz goes on by typing and tapping. For the rest
//  of the month the mic never opens by itself and Answer opens the typed
//  field, so the player never meets the refusal again and again. The server
//  is the truth: its 429 `voice_limit_reached`, or `/usage` reporting none
//  left; a fresh `/usage` with voice open again (new month, Plus) lifts it.
//

import Foundation

extension QuizViewModel {
    /// No voice answer this month in this round: the mic stays closed.
    var isVoiceAllowanceSpent: Bool {
        roundLimitsVoice && entitlementReconciler.isVoiceAllowanceSpent
    }

    /// The server limits voice only in a round that draws on the question
    /// quota (`gate_voice_answer`): never a pack, the daily challenge, a quiz
    /// from a friend's link or a round with kids.
    private var roundLimitsVoice: Bool {
        activePack == nil && activeDaily == nil && activeShare == nil && activeFamily == nil
    }

    /// The question on screen carries the once-a-month notice.
    var showsVoiceLimitNotice: Bool {
        guard let id = entitlementReconciler.voiceLimitNoticeQuestionId else { return false }
        return id == currentQuestion?.id
    }

    /// The voice answers turned out to be used up: `refusal` is the server's
    /// 429, nil when `/usage` already said so and the mic was not opened. The
    /// notice comes once a month (persisted, so also once across launches).
    func noteVoiceAllowanceSpent(_ refusal: VoiceLimitError?) {
        if let refusal { entitlementReconciler.voiceRefusal = refusal }
        quizTimersController.cancelThinkingTime()
        guard let month = entitlementReconciler.voiceRefusal?.resetsAt ?? usageInfo?.resetsAt,
              persistenceStore.voiceLimitNoticeMonth != month,
              let questionId = currentQuestion?.id
        else { return }
        persistenceStore.setVoiceLimitNoticeMonth(month)
        entitlementReconciler.voiceLimitNoticeQuestionId = questionId
        attemptLedger.record(.prompt, "voiceLimit.notice")
        trackAnalytics(.voiceLimitNoticeShown)
        announceVoiceLimit()
    }

    /// The notice's Plus link. The question stays open under the paywall.
    func openPaywallFromVoiceLimitNotice() {
        presentPaywall(source: .voiceLimit)
    }
}
