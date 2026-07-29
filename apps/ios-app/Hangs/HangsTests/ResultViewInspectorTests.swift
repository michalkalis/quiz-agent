//
//  ResultViewInspectorTests.swift
//  HangsTests
//
//  ViewInspector assertions for the redesigned Result screen — issue #127,
//  Variant C "Zero-Scroll Deck" (founder pick 2026-07-28). The screen has three
//  FIXED zones and no screen-level ScrollView; the answer panel always renders
//  (no @State appear-gate any more), so the verdict field, answer labels,
//  explanation "why" block and source line are directly inspectable.
//
//  Altitude (#57): these gate on flow / element presence, not pixel fidelity.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

// MARK: - Helpers

/// A Question with controllable `explanation` / `sourceUrl` (the two fields the
/// #127 "why" block and source line are gated on).
@MainActor
private func makeQuestion(
    explanation: String? = nil,
    sourceUrl: String? = "https://www.nasa.gov/uranus"
) -> Question {
    Question(
        id: "q_test",
        question: "Which planet rotates on its side?",
        type: .text,
        possibleAnswers: nil,
        difficulty: "medium",
        topic: "Astronomy",
        category: "adults",
        sourceUrl: sourceUrl,
        sourceExcerpt: nil,
        mediaUrl: nil,
        imageSubtype: nil,
        explanation: explanation,
        generatedBy: nil
    )
}

/// Build a QuizViewModel in .showingResult for the given evaluation + question.
@MainActor
private func makeViewModel(evaluation: Evaluation, question: Question = makeQuestion()) -> QuizViewModel {
    let vm = Fixtures.makeViewModel()
    vm.currentSession = Fixtures.makeActiveSession()
    vm.quizState = .showingResult(question: question, evaluation: evaluation)
    return vm
}

/// A ViewModel with NO evaluation but a live currentQuestion — the defensive
/// nil-evaluation path (resultEvaluation derives from .showingResult, which
/// production never reaches with a nil payload, so this hosts ResultView directly).
@MainActor
private func makeViewModelNoEvaluation() -> QuizViewModel {
    let vm = Fixtures.makeViewModel()
    vm.currentSession = Fixtures.makeActiveSession()
    vm.currentQuestion = Fixtures.makeQuestion() // stem "What is 2+2?"
    // quizState stays .idle → resultEvaluation == nil, resultQuestion == nil.
    return vm
}

// MARK: - Suite

@Suite("ResultView ViewInspector Tests")
@MainActor
struct ResultViewInspectorTests {
    // MARK: - Correct variant

    /// #131 Track D Variant A: the band states the outcome ONCE — the big
    /// "NAILED IT." word plus the check badge. The old "correct" status chip is
    /// gone; the screen must never say the same state twice.
    @Test("Correct evaluation renders the verdict band, NAILED word and 'your answer' panel")
    func correctVariantRendersVerdictAndAnswerPanel() async throws {
        let evaluation = Evaluation(
            userAnswer: "Uranus", result: .correct, points: 1.0,
            correctAnswer: "Uranus", questionId: "q_test", explanation: nil
        )
        let view = ResultView(viewModel: makeViewModel(evaluation: evaluation))

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "NAILED IT.") }
            #expect(throws: (any Error).self, "the status chip must not repeat the verdict") {
                try tree.find(text: "correct")
            }
            #expect(throws: Never.self) {
                try tree.find(ViewType.Image.self, where: { try $0.actualImage().name() == "checkmark" })
            }
            // Answer panel: correct-branch label + the answer itself.
            #expect(throws: Never.self) { try tree.find(text: "your answer") }
            #expect(throws: Never.self) { try tree.find(text: "Uranus") }
        }
    }

    // MARK: - Incorrect variant

    /// Incorrect: the band says "MISSED IT." once (xmark badge, no "not quite"
    /// chip), the card labels the revealed answer "the answer", and what the
    /// driver said drops to the muted meta row under the card.
    @Test("Incorrect evaluation renders MISSED word, 'the answer' panel and 'you said' line")
    func incorrectVariantRendersAnswerPanel() async throws {
        let evaluation = Evaluation(
            userAnswer: "Saturn", result: .incorrect, points: 0.0,
            correctAnswer: "Uranus", questionId: "q_test", explanation: nil
        )
        let view = ResultView(viewModel: makeViewModel(evaluation: evaluation))

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "MISSED IT.") }
            #expect(throws: (any Error).self, "the status chip must not repeat the verdict") {
                try tree.find(text: "not quite")
            }
            #expect(throws: Never.self) {
                try tree.find(ViewType.Image.self, where: { try $0.actualImage().name() == "xmark" })
            }
            // The revealed correct answer is the dominant text under "the answer".
            #expect(throws: Never.self) { try tree.find(text: "the answer") }
            #expect(throws: Never.self) { try tree.find(text: "Uranus") }
            // The wrong answer is footnoted in the meta row's "you said" entry.
            #expect(throws: Never.self) { try tree.find(text: "you said") }
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "result.metaRow") }
            // NAILED must NOT appear.
            #expect(throws: (any Error).self) { try tree.find(text: "NAILED IT.") }
        }
    }

    // MARK: - Skipped variant (#131 Track D)

    /// A skip must never render "MISSED IT. / not quite" over an answer the
    /// driver never gave — it gets its own neutral verdict: a "SKIPPED."
    /// headline over a neutral dash badge, and no MISSED/NAILED word at all.
    @Test("Skipped evaluation renders neutral SKIPPED verdict, not MISSED IT")
    func skippedVariantRendersNeutralVerdict() async throws {
        let evaluation = Evaluation(
            userAnswer: "", result: .skipped, points: 0.0,
            correctAnswer: "Uranus", questionId: "q_test", explanation: nil
        )
        let view = ResultView(viewModel: makeViewModel(evaluation: evaluation))

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "SKIPPED.") }
            #expect(throws: Never.self) {
                try tree.find(ViewType.Image.self, where: { try $0.actualImage().name() == "minus" })
            }
            // The wrong verdicts must NOT appear.
            #expect(throws: (any Error).self) { try tree.find(text: "MISSED IT.") }
            #expect(throws: (any Error).self) { try tree.find(text: "not quite") }
            #expect(throws: (any Error).self) { try tree.find(text: "NAILED IT.") }
        }
    }

    /// The redundant strikethrough "you said · <empty>" row must be dropped for
    /// a skip — there is nothing the driver said, so no "you said" label at all.
    @Test("Skipped evaluation drops the 'you said' recap row")
    func skippedVariantHasNoYouSaidRow() async throws {
        let evaluation = Evaluation(
            userAnswer: "", result: .skipped, points: 0.0,
            correctAnswer: "Uranus", questionId: "q_test", explanation: nil
        )
        let view = ResultView(viewModel: makeViewModel(evaluation: evaluation))

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) { try tree.find(text: "you said") }
        }
    }

    /// Score delta stays "+0" for a skip, same as a wrong answer (unchanged).
    @Test("Skipped evaluation shows +0 score delta")
    func skippedVariantShowsZeroScoreDelta() async throws {
        let evaluation = Evaluation(
            userAnswer: "", result: .skipped, points: 0.0,
            correctAnswer: "Uranus", questionId: "q_test", explanation: nil
        )
        let view = ResultView(viewModel: makeViewModel(evaluation: evaluation))

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "+0") }
        }
    }

    /// A genuine wrong answer must still show "MISSED IT." — the new `.skipped`
    /// branch must not swallow the existing incorrect path.
    @Test("Wrong answer still renders MISSED IT after the skipped verdict was added")
    func incorrectVariantStillRendersMissedIt() async throws {
        let evaluation = Evaluation(
            userAnswer: "Saturn", result: .incorrect, points: 0.0,
            correctAnswer: "Uranus", questionId: "q_test", explanation: nil
        )
        let view = ResultView(viewModel: makeViewModel(evaluation: evaluation))

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "MISSED IT.") }
            #expect(throws: Never.self) { try tree.find(text: "you said") }
            #expect(throws: (any Error).self) { try tree.find(text: "SKIPPED.") }
        }
    }

    // MARK: - Partial credit variant

    /// Partial collapses to the incorrect visual branch (documented limitation);
    /// the model still carries partiallyCorrect + partial points.
    @Test("Partial-credit evaluation renders incorrect-branch and keeps partial result in model")
    func partialVariantRendersIncorrectBranch() async throws {
        let evaluation = Evaluation(
            userAnswer: "Paris, France", result: .partiallyCorrect, points: 0.5,
            correctAnswer: "Paris", questionId: "q_test", explanation: nil
        )
        let vm = makeViewModel(evaluation: evaluation)
        let view = ResultView(viewModel: vm)

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "MISSED IT.") }
            #expect(vm.resultEvaluation?.result == .partiallyCorrect)
            #expect(vm.resultEvaluation?.points == 0.5)
        }
    }

    // MARK: - Explanation "why" block on BOTH outcomes (gated on text, not correctness)

    /// When explanation text exists, the "why" label + "hear it" control render on
    /// a CORRECT answer.
    @Test("Explanation present: 'why' + 'hear it' render on a correct answer")
    func explanationRendersOnCorrect() async throws {
        let evaluation = Evaluation(
            userAnswer: "Uranus", result: .correct, points: 1.0,
            correctAnswer: "Uranus", questionId: "q_test", explanation: nil
        )
        let q = makeQuestion(explanation: "Uranus is tipped about 98 degrees.")
        let view = ResultView(viewModel: makeViewModel(evaluation: evaluation, question: q))

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "why") }
            #expect(throws: Never.self) { try tree.find(text: "hear it") }
            #expect(throws: Never.self) { try tree.find(text: "Uranus is tipped about 98 degrees.") }
        }
    }

    /// The SAME "why" block renders on an INCORRECT answer — the explanation is
    /// gated on the text existing, never on correctness (issue #127 fix).
    @Test("Explanation present: 'why' + 'hear it' render on an incorrect answer too")
    func explanationRendersOnIncorrect() async throws {
        let evaluation = Evaluation(
            userAnswer: "Saturn", result: .incorrect, points: 0.0,
            correctAnswer: "Uranus", questionId: "q_test", explanation: nil
        )
        let q = makeQuestion(explanation: "Uranus is tipped about 98 degrees.")
        let view = ResultView(viewModel: makeViewModel(evaluation: evaluation, question: q))

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "why") }
            #expect(throws: Never.self) { try tree.find(text: "hear it") }
        }
    }

    /// No explanation text → the whole "why" block (and its internal ScrollView)
    /// is omitted on both outcomes.
    @Test("No explanation: the 'why' block and internal ScrollView are omitted")
    func explanationAbsentWhenNoText() async throws {
        let evaluation = Evaluation(
            userAnswer: "Saturn", result: .incorrect, points: 0.0,
            correctAnswer: "Uranus", questionId: "q_test", explanation: nil
        )
        // Question + evaluation both carry no explanation.
        let view = ResultView(viewModel: makeViewModel(evaluation: evaluation, question: makeQuestion(explanation: nil)))

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) { try tree.find(text: "why") }
            #expect(throws: (any Error).self) { try tree.find(text: "hear it") }
            // No explanation ⇒ the ONLY ScrollView (the internal explanation one)
            // is absent ⇒ proves there is no screen-level ScrollView (issue #127).
            #expect(throws: (any Error).self) { try tree.find(ViewType.ScrollView.self) }
        }
    }

    // MARK: - Source line gated on sourceUrl only (NOT correctness)

    /// The source line renders on a WRONG answer when a sourceUrl exists. This is
    /// the core #127 fix: the old `if isCorrect` gate would suppress it here, so
    /// this assertion FAILS on the pre-#127 code.
    @Test("Source line renders on an incorrect answer when sourceUrl exists (#127 fix)")
    func sourceLineRendersOnIncorrectWhenUrlExists() async throws {
        let evaluation = Evaluation(
            userAnswer: "Saturn", result: .incorrect, points: 0.0,
            correctAnswer: "Uranus", questionId: "q_test", explanation: nil
        )
        let view = ResultView(viewModel: makeViewModel(
            evaluation: evaluation,
            question: makeQuestion(sourceUrl: "https://www.nasa.gov/uranus")
        ))

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "source") }
        }
    }

    /// And on a correct answer — the source line is symmetric.
    @Test("Source line renders on a correct answer when sourceUrl exists")
    func sourceLineRendersOnCorrectWhenUrlExists() async throws {
        let evaluation = Evaluation(
            userAnswer: "Uranus", result: .correct, points: 1.0,
            correctAnswer: "Uranus", questionId: "q_test", explanation: nil
        )
        let view = ResultView(viewModel: makeViewModel(
            evaluation: evaluation,
            question: makeQuestion(sourceUrl: "https://www.nasa.gov/uranus")
        ))

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "source") }
        }
    }

    /// No sourceUrl → no source line, on either outcome (gated on URL only).
    @Test("Source line absent when sourceUrl is nil")
    func sourceLineAbsentWhenNoUrl() async throws {
        let evaluation = Evaluation(
            userAnswer: "Saturn", result: .incorrect, points: 0.0,
            correctAnswer: "Uranus", questionId: "q_test", explanation: nil
        )
        let view = ResultView(viewModel: makeViewModel(
            evaluation: evaluation,
            question: makeQuestion(sourceUrl: nil)
        ))

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) { try tree.find(text: "source") }
        }
    }

    // MARK: - Footer consolidation

    /// Footer consolidates to one row: STAY pill + "Next question" CTA. The old
    /// "Why is this correct?" ghost button is cut on BOTH outcomes.
    @Test("Footer shows STAY + Next question; the cut 'Why is this correct?' ghost is gone")
    func footerIsConsolidatedSingleRow() async throws {
        let evaluation = Evaluation(
            userAnswer: "Uranus", result: .correct, points: 1.0,
            correctAnswer: "Uranus", questionId: "q_test", explanation: nil
        )
        let view = ResultView(viewModel: makeViewModel(evaluation: evaluation))

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(button: "Next question") }
            #expect(throws: Never.self) { try tree.find(text: "STAY") }
            #expect(throws: (any Error).self) { try tree.find(button: "Why is this correct?") }
        }
    }

    /// #131 Track D: "Next question" is the primary CTA and must sit LEFT of the
    /// STAY/RESUME pill (swapped from the #127 layout, founder spec). Asserted by
    /// document order of the two footer buttons, which mirrors left-to-right
    /// layout order in the underlying HStack.
    @Test("Footer button order: Next question precedes the STAY pill")
    func footerNextQuestionPrecedesStayPill() async throws {
        let evaluation = Evaluation(
            userAnswer: "Uranus", result: .correct, points: 1.0,
            correctAnswer: "Uranus", questionId: "q_test", explanation: nil
        )
        let view = ResultView(viewModel: makeViewModel(evaluation: evaluation))

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            // Document order of Text nodes mirrors left-to-right HStack layout
            // order; "Next question" is the CTA's label, "STAY" the pill's.
            let texts = try tree.findAll(ViewType.Text.self).compactMap { try? $0.string() }
            let nextIndex = try #require(texts.firstIndex(of: "Next question"))
            let stayIndex = try #require(texts.firstIndex(of: "STAY"))
            #expect(nextIndex < stayIndex)
        }
    }

    // MARK: - Nil-evaluation defensive rendering (req. 6/7)

    /// The old code rendered nothing but the hero for a nil evaluation. The
    /// redesign renders a DEFINED fallback: a neutral field (no verdict word) and
    /// the answer panel recapped to the question stem — never a blank screen.
    @Test("Nil evaluation renders the neutral recap fallback (stem + Next question), no verdict word")
    func nilEvaluationRendersRecapFallback() async throws {
        let vm = makeViewModelNoEvaluation()
        let view = ResultView(viewModel: vm)

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            // Recap: the stem is the dominant text under a "the question" label.
            #expect(throws: Never.self) { try tree.find(text: "the question") }
            #expect(throws: Never.self) { try tree.find(text: "What is 2+2?") }
            // Footer still works.
            #expect(throws: Never.self) { try tree.find(button: "Next question") }
            // Neutral: neither verdict word appears.
            #expect(throws: (any Error).self) { try tree.find(text: "NAILED IT.") }
            #expect(throws: (any Error).self) { try tree.find(text: "MISSED IT.") }
            #expect(vm.resultEvaluation == nil)
        }
    }

    /// Empty canonical answer (backend sent an empty correct_answer) must NOT
    /// render an empty 46pt row — it falls back to the same recap layout (req. 7).
    @Test("Empty revealed answer falls back to the question-stem recap layout")
    func emptyAnswerFallsBackToRecap() async throws {
        let evaluation = Evaluation(
            userAnswer: "", result: .incorrect, points: 0.0,
            correctAnswer: "", questionId: "q_test", explanation: nil
        )
        let view = ResultView(viewModel: makeViewModel(evaluation: evaluation))

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            // Recap label + stem (from the seeded question), not the answer branch.
            #expect(throws: Never.self) { try tree.find(text: "the question") }
            #expect(throws: Never.self) { try tree.find(text: "Which planet rotates on its side?") }
            #expect(throws: (any Error).self) { try tree.find(text: "the answer") }
        }
    }

    // MARK: - Revealed answer (headline_answer ?? correct_answer) — 46.B9

    @Test("Open question reveals headlineAnswer gist, not the long correctAnswer")
    func openQuestionRevealsHeadlineAnswer() {
        let evaluation = Evaluation(
            userAnswer: "desert", result: .incorrect, points: 0.0,
            correctAnswer: "A lush green landscape with rivers, lakes and abundant wildlife",
            questionId: "q_open",
            explanation: "The Sahara was a savanna during the African Humid Period.",
            headlineAnswer: "Grassland/savanna"
        )
        let view = ResultView(viewModel: makeViewModel(evaluation: evaluation))
        #expect(view.revealedAnswer == "Grassland/savanna")
    }

    @Test("Closed question reveal falls back to correctAnswer unchanged")
    func closedQuestionRevealsCorrectAnswer() {
        let evaluation = Evaluation(
            userAnswer: "London", result: .incorrect, points: 0.0,
            correctAnswer: "Paris", questionId: "q_closed", explanation: nil
        )
        let view = ResultView(viewModel: makeViewModel(evaluation: evaluation))
        #expect(view.revealedAnswer == "Paris")
    }

    // MARK: - 54.10 — totalQuestions fallback to settings

    @Test("Counter falls back to settings.numberOfQuestions when session is nil")
    func counterFallsBackToSettingsLength() async throws {
        let evaluation = Evaluation(
            userAnswer: "Paris", result: .correct, points: 1.0,
            correctAnswer: "Paris", questionId: "q_test", explanation: nil
        )
        let vm = Fixtures.makeViewModel()
        vm.quizState = .showingResult(question: Fixtures.makeQuestion(), evaluation: evaluation)
        vm.settings.numberOfQuestions = 5
        let view = ResultView(viewModel: vm)

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "00 / 05") }
        }
    }

    // MARK: - read-aloud control

    /// Variant A moves read-aloud into the verdict band as an icon-only control
    /// (a text label would compete with the 56pt verdict word) — the affordance
    /// must survive the move, so assert its stable identifier, not its label.
    @Test("Read-aloud control is present in the verdict band")
    func readAloudButtonPresent() async throws {
        let evaluation = Evaluation(
            userAnswer: "Paris", result: .correct, points: 1.0,
            correctAnswer: "Paris", questionId: "q_test", explanation: nil
        )
        let view = ResultView(viewModel: makeViewModel(evaluation: evaluation))

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "result.readAloud")
            }
        }
    }

    // MARK: - Score / streak live ONLY in the muted meta row (#131 Track D)

    /// #84 (founder decision 5) banned a streak *echo* — a second, celebratory
    /// statement of progress competing with the verdict. #131 Track D Variant A
    /// (founder pick 2026-07-29) supersedes the blanket ban: score, delta and
    /// streak are allowed, but ONLY demoted into the single 10pt mono meta row
    /// under the card. So: the values render, and they render inside
    /// `result.metaRow` — never as their own hero block.
    @Test("Correct variant shows score, delta and streak only inside the meta row")
    func correctVariantHasNoStreakEcho() async throws {
        let evaluation = Evaluation(
            userAnswer: "Paris", result: .correct, points: 1.0,
            correctAnswer: "Paris", questionId: "q_test", explanation: nil
        )
        let vm = makeViewModel(evaluation: evaluation)
        vm.quizStats.recordAnswer(isCorrect: true)
        let view = ResultView(viewModel: vm)

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let meta = try tree.find(viewWithAccessibilityIdentifier: "result.metaRow")
            #expect(throws: Never.self) { try meta.find(text: "+1") }
            #expect(throws: Never.self) { try meta.find(text: "streak") }
            #expect(throws: Never.self) { try meta.find(text: "score") }
            #expect(vm.quizStats.currentStreak == 1)
        }
    }

    @Test("Incorrect variant shows score, delta and streak only inside the meta row")
    func incorrectVariantHasNoStreakEcho() async throws {
        let evaluation = Evaluation(
            userAnswer: "London", result: .incorrect, points: 0.0,
            correctAnswer: "Paris", questionId: "q_test", explanation: nil
        )
        let view = ResultView(viewModel: makeViewModel(evaluation: evaluation))

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let meta = try tree.find(viewWithAccessibilityIdentifier: "result.metaRow")
            #expect(throws: Never.self) { try meta.find(text: "+0") }
            #expect(throws: Never.self) { try meta.find(text: "streak") }
        }
    }

    /// 54.9: no per-question retry button exists on either variant.
    @Test("Neither result variant shows a retry button")
    func neitherVariantShowsRetryButton() async throws {
        let incorrectEval = Evaluation(
            userAnswer: "London", result: .incorrect, points: 0.0,
            correctAnswer: "Paris", questionId: "q_test", explanation: nil
        )
        let correctEval = Evaluation(
            userAnswer: "Paris", result: .correct, points: 1.0,
            correctAnswer: "Paris", questionId: "q_test", explanation: nil
        )

        let viewIncorrect = ResultView(viewModel: makeViewModel(evaluation: incorrectEval))
        try await ViewHosting.host(viewIncorrect) {
            let tree = try viewIncorrect.inspect()
            #expect(throws: (any Error).self) { try tree.find(button: "Try this question again") }
        }

        let viewCorrect = ResultView(viewModel: makeViewModel(evaluation: correctEval))
        try await ViewHosting.host(viewCorrect) {
            let tree = try viewCorrect.inspect()
            #expect(throws: (any Error).self) { try tree.find(button: "Try this question again") }
        }
    }
}

// MARK: - Skip Haptic (#82 item 2)

@Suite("ResultView Skip Haptic Tests")
struct ResultViewSkipHapticTests {
    /// #82 item 2 (founder decision 7): a skip is not a failure — gentle tick,
    /// never the error buzz a wrong answer gets.
    @Test("skip gets a selection tick, not the error haptic")
    @MainActor
    func skipHapticIsGentleTick() {
        #expect(ResultView.haptic(for: .skipped) == .selection)
        #expect(ResultView.haptic(for: .skipped) != ResultView.haptic(for: .incorrect))
    }

    @Test("non-skip results keep their existing haptics")
    @MainActor
    func nonSkipHapticsUnchanged() {
        #expect(ResultView.haptic(for: .correct) == .success)
        #expect(ResultView.haptic(for: .incorrect) == .error)
        #expect(ResultView.haptic(for: .partiallyCorrect) == .warning)
        #expect(ResultView.haptic(for: .partiallyIncorrect) == .warning)
    }
}

// MARK: - CTA countdown + STAY/RESUME pill (#108B / #127)

/// #108B: the auto-advance countdown lives inside the "Next question" CTA. #127
/// consolidates the escape hatch into a single STAY/RESUME pill in the same row.
@Suite("ResultView CTA Countdown Tests")
@MainActor
struct ResultViewCTACountdownTests {
    private func makeCountdownViewModel(countdown: Int) -> QuizViewModel {
        let vm = Fixtures.makeViewModel()
        vm.currentSession = Fixtures.makeActiveSession()
        vm.quizState = .showingResult(
            question: Fixtures.makeQuestion(),
            evaluation: Evaluation(
                userAnswer: "Paris", result: .correct, points: 1.0,
                correctAnswer: "Paris", questionId: "q_test", explanation: nil
            )
        )
        vm.currentQuestionPaused = false
        vm.autoAdvanceCountdown = countdown
        vm.settings.autoAdvanceDelay = 10
        return vm
    }

    @Test("Active auto-advance shows the seconds chip in the CTA and the STAY pill")
    func activeCountdownShowsChipAndStay() async throws {
        let vm = makeCountdownViewModel(countdown: 7)
        let view = ResultView(viewModel: vm)

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "7s") }
            #expect(throws: (any Error).self) { try tree.find(text: "Next in 7s") }
            #expect(throws: Never.self) { try tree.find(text: "STAY") }
        }
    }

    @Test("Paused countdown hides the chip and swaps STAY → RESUME in the same slot")
    func pausedCountdownSwapsPill() async throws {
        let vm = makeCountdownViewModel(countdown: 7)
        vm.currentQuestionPaused = true
        let view = ResultView(viewModel: vm)

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) { try tree.find(text: "7s") }
            #expect(throws: (any Error).self) { try tree.find(text: "STAY") }
            #expect(throws: Never.self) { try tree.find(text: "RESUME") }
            #expect(throws: Never.self) { try tree.find(text: "Next question") }
        }
    }
}
