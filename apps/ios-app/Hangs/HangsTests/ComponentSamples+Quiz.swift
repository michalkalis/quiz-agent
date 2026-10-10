//
//  ComponentSamples+Quiz.swift
//  HangsTests
//
//  #188 track C: quiz chrome, voice bars, verdicts and Home cards — see
//  ComponentSnapshotTests.
//

import Foundation
@testable import Hangs
import SwiftUI

nonisolated extension ComponentSample {
    static var quiz: [ComponentSample] { chrome + voice + verdicts + home }

    private static var chrome: [ComponentSample] {
        [
            ComponentSample("brandRow.default") { HangsBrandRow() },
            ComponentSample("progressHeader.default") { HangsQuizProgressHeader(category: "Geography", current: 3, total: 10) },
            // #194 C2: the question screen prints the category on its card chip,
            // so its header is one row — segments + counter.
            ComponentSample("progressHeader.noCategory") { HangsQuizProgressHeader(current: 3, total: 10) },
            ComponentSample("progressHeader.recording") {
                HangsQuizProgressHeader(category: "Geography", current: 3, total: 10, isRecording: true)
            },
            ComponentSample("progressBar.default") { HangsProgressBar(progress: 0.3) },
            ComponentSample("pageIndicator.default") { HangsPageIndicator(pageCount: 4, currentPage: 1) },
            ComponentSample("questionPrompt.default") { HangsQuestionPrompt(text: "What is the capital of France?") },
            ComponentSample("questionPrompt.longText") {
                HangsQuestionPrompt(text: "Ktorý európsky štát má najdlhšie pobrežie, ak nerátame zámorské územia a ostrovy?")
            },
            // #194 B2: the category card — one sample per text colour rule
            // (white on cobalt, ink on yellow, white on the custom-pack ink card).
            ComponentSample("deckCard.question") {
                HangsDeckCard(categoryId: "geography-world", categoryName: "Geografia a svet") {
                    Text(verbatim: "Ktoré mesto je hlavným mestom Austrálie?").font(.hangsDisplay(40))
                }
                .frame(height: 260)
            },
            ComponentSample("deckCard.resultSticker") {
                HangsDeckCard(categoryId: "sports", categoryName: "Šport") {
                    HangsAnswerSticker(text: "Jedenásť")
                }
                .frame(height: 180)
            },
            ComponentSample("deckCard.customPack") {
                HangsDeckCard(categoryId: nil, categoryName: "Slovenské hrady") {
                    Text(verbatim: "Na ktorom hrade sa natáčal Nosferatu?").font(.hangsDisplay(28))
                }
                .frame(height: 200)
            },
            ComponentSample("controlPill.default") {
                QuizControlPill(isMuted: false, isPaused: false, isPauseEnabled: true, onMute: {}, onPause: {})
            },
            ComponentSample("controlPill.mutedPaused") {
                QuizControlPill(isMuted: true, isPaused: true, isPauseEnabled: true, onMute: {}, onPause: {})
            },
            ComponentSample("controlPill.pauseDisabled") {
                QuizControlPill(isMuted: false, isPaused: false, isPauseEnabled: false, onMute: {}, onPause: {})
            },
            ComponentSample("reviewBadge.pendingReview") { ReviewBadge(badge: "pending_review") },
            ComponentSample("reviewBadge.machineTranslation") { ReviewBadge(badge: "translation_machine", filled: true) },
            ComponentSample("reviewBadge.englishFallback") { ReviewBadge(badge: "en_fallback") },
            ComponentSample("provenanceRow.default") {
                QuestionProvenanceRow(question: Question.preview, isEnabled: true, horizontalPadding: 0)
            },
        ]
    }

    private static var voice: [ComponentSample] {
        [
            ComponentSample("listenBar.command") { ListenBar(mode: .command, commandWords: ["skip", "repeat", "pause"]) },
            ComponentSample("listenBar.commandMatched") {
                ListenBar(mode: .command, feedback: .matched, commandWords: ["skip", "repeat", "pause"])
            },
            ComponentSample("listenBar.commandHearing") {
                ListenBar(mode: .command, feedback: .hearing, commandWords: ["skip", "repeat", "pause"])
            },
            ComponentSample("listenBar.commandRecognizing") {
                ListenBar(mode: .command, feedback: .recognizing, recognizingWord: "„preskoč“…",
                          commandWords: ["skip", "repeat", "pause"])
            },
            ComponentSample("listenBar.answerOpen") { ListenBar(mode: .answer(.open)) },
            ComponentSample("listenBar.slimSlovak") {
                ListenBar(mode: .command, size: .slim, shortCaption: true, language: .slovak)
            },
            ComponentSample("questionListenBar.reading") { QuestionListenBar(phase: .readingQuestion) },
            ComponentSample("questionListenBar.thinking") { QuestionListenBar(phase: .thinking(remaining: 3, total: 5)) },
            ComponentSample("questionListenBar.thinkingDismissable") {
                QuestionListenBar(phase: .thinking(remaining: 27, total: 30), language: .slovak, onDismiss: {})
            },
            ComponentSample("questionListenBar.listeningMCQ") { QuestionListenBar(phase: .listening(.mcq)) },
            ComponentSample("questionListenBar.listeningCountdown") {
                // With the ✕: the countdown and the ✕ each need their own room.
                QuestionListenBar(phase: .listening(.open), answerRemaining: 12, onDismiss: {})
            },
            ComponentSample("questionListenBar.evaluating") { QuestionListenBar(phase: .evaluating) },
            ComponentSample("questionListenBar.skipping") { QuestionListenBar(phase: .skipping) },
            ComponentSample("retryHint.default") { EmptyAnswerRetryHint() },
        ]
    }

    private static var verdicts: [ComponentSample] {
        [
            ComponentSample("resultBanner.correct") { HangsResultBanner(kind: .correct) },
            ComponentSample("resultBanner.incorrect") { HangsResultBanner(kind: .incorrect) },
            ComponentSample("inlineBadge.correct") { HangsInlineBadge(kind: .correct) },
            ComponentSample("inlineBadge.incorrect") { HangsInlineBadge(kind: .incorrect) },
        ]
    }

    /// Reset 12½ days out, like the hero Home screen, so the countdown copy is stable.
    private static var home: [ComponentSample] {
        [
            ComponentSample("planCard.free") { HomePlanCard(usage: usage(status: "none")) },
            ComponentSample("planCard.freeWithCredits") { HomePlanCard(usage: usage(status: "none", credits: 100)) },
            ComponentSample("planCard.subscriber") { HomePlanCard(usage: usage(status: "active", premium: true)) },
            ComponentSample("planCard.grace") { HomePlanCard(usage: usage(status: "grace", premium: true)) },
            ComponentSample("planCard.expired") { HomePlanCard(usage: usage(status: "expired")) },
        ]
    }

    private static func usage(status: String, premium: Bool = false, credits: Int = 0) -> UsageInfo {
        let resetsAt = Date().addingTimeInterval(12 * 86400 + 12 * 3600)
        return UsageInfo(
            userId: "snapshot-subject",
            isPremium: premium,
            questionsUsed: 12,
            questionsLimit: premium ? nil : 30,
            remaining: premium ? nil : 18,
            resetsAt: ISO8601DateFormatter().string(from: resetsAt),
            subscriptionStatus: status,
            creditBalance: credits
        )
    }
}
