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
    /// "Correct" word plus the check badge. The old "correct" status chip is
    /// gone; the screen must never say the same state twice.
    @Test("Correct evaluation renders the verdict label, Nailed it word and 'the answer' panel")
    func correctVariantRendersVerdictAndAnswerPanel() async throws {
        let evaluation = Evaluation(
            userAnswer: "Uranus", result: .correct, points: 1.0,
            correctAnswer: "Uranus", questionId: "q_test", explanation: nil
        )
        let view = ResultView(viewModel: makeViewModel(evaluation: evaluation))

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "Correct") }
            #expect(throws: (any Error).self, "the status chip must not repeat the verdict") {
                try tree.find(text: "correct")
            }
            #expect(throws: Never.self) {
                try tree.find(ViewType.Image.self, where: { try $0.actualImage().name() == "checkmark" })
            }
            // #250 (variant A): a right answer said word for word is the
            // headline by itself, with no "Correct answer" label to repeat it.
            #expect(throws: (any Error).self) { try tree.find(text: "Correct answer") }
            #expect(throws: Never.self) { try tree.find(text: "Uranus") }
        }
    }

    // MARK: - #250 variant A: the player's answer is the headline

    /// WHY (founder, TF 1.3 b93): "nie je jasné, čo je moja odpoveď a čo
    /// správna". On a miss the player's own answer leads, struck, and the
    /// correct one follows under its label; a right answer heard differently
    /// shows the exact wording small under it.
    @Test("a miss leads with the player's answer, the correct one under its label")
    func missLeadsWithPlayersAnswer() async throws {
        let evaluation = Evaluation(
            userAnswer: "Saturn", result: .incorrect, points: 0,
            correctAnswer: "Uranus", questionId: "q_test", explanation: nil
        )
        let view = ResultView(viewModel: makeViewModel(evaluation: evaluation))

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let said = try tree.find(viewWithAccessibilityIdentifier: "result.said")
            let answer = try tree.find(viewWithAccessibilityIdentifier: "result.answer")
            #expect(try said.text().string() == "Saturn")
            #expect(try answer.text().string() == "Uranus")
            #expect(throws: Never.self) { try tree.find(text: "Correct answer") }
            #expect(throws: (any Error).self, "the old small 'Your answer' row is back") {
                try tree.find(text: "Your answer")
            }
        }
    }

    @Test("a right answer heard differently shows the exact wording under it")
    func heardDifferentlyShowsExactWording() async throws {
        let evaluation = Evaluation(
            userAnswer: "Eva Farna", result: .correct, points: 1,
            correctAnswer: "Ewa Farná", questionId: "q_test", explanation: nil
        )
        let view = ResultView(viewModel: makeViewModel(evaluation: evaluation))

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(try tree.find(viewWithAccessibilityIdentifier: "result.heard").text().string() == "Eva Farna")
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "result.answer") }
        }
    }

    /// WHY (founder 2026-11-26): the silent green dot of an approved question
    /// read as an unexplained element on the result. A badge asking for a
    /// check stays, it carries words.
    @Test("the result hides the approved dot, keeps a badge that asks for a check", arguments: ["approved", "pending_review"])
    func approvedDotHiddenOnResult(badge: String) async throws {
        let evaluation = Evaluation(
            userAnswer: "Uranus", result: .correct, points: 1,
            correctAnswer: "Uranus", questionId: "q_test", explanation: nil
        )
        let question = Question(
            id: "q_test", question: "Which planet rotates on its side?", type: .text,
            possibleAnswers: nil, difficulty: "medium", topic: "Astronomy", category: "adults",
            sourceUrl: nil, sourceExcerpt: nil, mediaUrl: nil, imageSubtype: nil,
            explanation: nil, generatedBy: nil, reviewBadge: badge
        )
        let view = ResultView(viewModel: makeViewModel(evaluation: evaluation, question: question), debugSurfaces: true)

        try await ViewHosting.host(view) {
            let shown = (try? view.inspect().find(viewWithAccessibilityIdentifier: "result.reviewBadge")) != nil
            #expect(shown == (badge != "approved"))
        }
    }

    // MARK: - Incorrect variant

    /// Incorrect: the band says "Wrong" once (xmark badge, no "incorrect"
    /// chip), the card labels the revealed answer "the answer", and what the
    /// driver said drops to the muted meta row under the card.
    @Test("Incorrect evaluation renders Missed word, 'the answer' panel and 'you said' line")
    func incorrectVariantRendersAnswerPanel() async throws {
        let evaluation = Evaluation(
            userAnswer: "Saturn", result: .incorrect, points: 0.0,
            correctAnswer: "Uranus", questionId: "q_test", explanation: nil
        )
        let view = ResultView(viewModel: makeViewModel(evaluation: evaluation))

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "Wrong") }
            #expect(throws: (any Error).self, "the status chip must not repeat the verdict") {
                try tree.find(text: "incorrect")
            }
            #expect(throws: Never.self) {
                try tree.find(ViewType.Image.self, where: { try $0.actualImage().name() == "xmark" })
            }
            // The revealed correct answer is the dominant text under "the answer".
            #expect(throws: Never.self) { try tree.find(text: "Correct answer") }
            #expect(throws: Never.self) { try tree.find(text: "Uranus") }
            // The wrong answer is the quiet struck-through "you said" line.
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "result.said") }
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "result.metaRow") }
            // NAILED must NOT appear.
            #expect(throws: (any Error).self) { try tree.find(text: "Correct") }
        }
    }

    // MARK: - Skipped variant (#131 Track D)

    /// A skip must never render "MISSED IT. / incorrect" over an answer the
    /// driver never gave — it gets its own neutral verdict: a "Skipped"
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
            #expect(throws: Never.self) { try tree.find(text: "Skipped") }
            #expect(throws: Never.self) {
                try tree.find(ViewType.Image.self, where: { try $0.actualImage().name() == "minus" })
            }
            // The wrong verdicts must NOT appear.
            #expect(throws: (any Error).self) { try tree.find(text: "Wrong") }
            #expect(throws: (any Error).self) { try tree.find(text: "incorrect") }
            #expect(throws: (any Error).self) { try tree.find(text: "Correct") }
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
            #expect(throws: (any Error).self) { try tree.find(viewWithAccessibilityIdentifier: "result.said") }
        }
    }

    /// #132 (founder, 2026-07-29): a skip shows no score delta at all — score and
    /// streak left the result screen entirely.
    @Test("Skipped evaluation shows no score delta")
    func skippedVariantShowsNoScoreDelta() async throws {
        let evaluation = Evaluation(
            userAnswer: "", result: .skipped, points: 0.0,
            correctAnswer: "Uranus", questionId: "q_test", explanation: nil
        )
        let view = ResultView(viewModel: makeViewModel(evaluation: evaluation))

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) { try tree.find(text: "+0") }
        }
    }

    /// A genuine wrong answer must still show "Wrong" — the new `.skipped`
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
            #expect(throws: Never.self) { try tree.find(text: "Wrong") }
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "result.said") }
            #expect(throws: (any Error).self) { try tree.find(text: "Skipped") }
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
            #expect(throws: Never.self) { try tree.find(text: "Wrong") }
            #expect(vm.resultEvaluation?.result == .partiallyCorrect)
            #expect(vm.resultEvaluation?.points == 0.5)
        }
    }

    // MARK: - Explanation "why" block on BOTH outcomes (gated on text, not correctness)

    /// When explanation text exists, the "why" label and the tappable text render
    /// on a CORRECT answer.
    @Test("Explanation present: 'why' + tappable text render on a correct answer")
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
            // #250: read aloud by itself; the text is the tap to hear it again.
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "result.explanationRead") }
            #expect(throws: Never.self) { try tree.find(text: "Uranus is tipped about 98 degrees.") }
        }
    }

    /// The SAME "why" block renders on an INCORRECT answer — the explanation is
    /// gated on the text existing, never on correctness (issue #127 fix).
    @Test("Explanation present: 'why' + tappable text render on an incorrect answer too")
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
            // #250: read aloud by itself; the text is the tap to hear it again.
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "result.explanationRead") }
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

    // MARK: - Footer

    /// The footer is the "Next" CTA alone (TF build 90 dropped the STAY pill,
    /// `ResultScreenC1Tests`). The old "Why is this correct?" ghost stays cut.
    @Test("Footer shows Next; the cut 'Why is this correct?' ghost is gone")
    func footerIsConsolidatedSingleRow() async throws {
        let evaluation = Evaluation(
            userAnswer: "Uranus", result: .correct, points: 1.0,
            correctAnswer: "Uranus", questionId: "q_test", explanation: nil
        )
        let view = ResultView(viewModel: makeViewModel(evaluation: evaluation))

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(button: "Next") }
            #expect(throws: (any Error).self) { try tree.find(button: "Why is this correct?") }
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
            #expect(throws: Never.self) { try tree.find(button: "Next") }
            // Neutral: neither verdict word appears.
            #expect(throws: (any Error).self) { try tree.find(text: "Correct") }
            #expect(throws: (any Error).self) { try tree.find(text: "Wrong") }
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
            #expect(throws: (any Error).self) { try tree.find(text: "Correct answer") }
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
            let counter = try tree.find(viewWithAccessibilityIdentifier: "question.counter")
            #expect(try counter.text().string() == "0/5")
        }
    }

    // MARK: - #188 G9 (D9): one top bar for question and result

    /// The result used to draw its own row (✕ + logo + "03 / 10") with the
    /// TestFlight chips floated over it; at large text the counter landed on the
    /// chips. It now wears the question screen's native toolbar (sound and pause
    /// in the same places) and the same header, so the count can only scale.
    @Test("the result shares the question screen's toolbar and header")
    func resultSharesQuizChrome() async throws {
        let vm = makeViewModel(evaluation: Evaluation(
            userAnswer: "Paris", result: .correct, points: 1.0,
            correctAnswer: "Paris", questionId: "q_test", explanation: nil
        ))
        let view = ResultView(viewModel: vm, ratingEntry: nil)
        try await ViewHosting.host(view) {
            #expect(QuizToolbarInspection.hasToolbar(view), "the native quiz toolbar, as on the question screen")
            #expect(
                (try? QuizToolbarInspection.bodyOccurrences(of: "question.closeButton", in: view)) == 0,
                "the ✕ lives in the toolbar, not a hand-drawn row"
            )
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "question.progress") }
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "question.counter") }
        }
    }

    // MARK: - One replay affordance only (#132)

    /// #132 (founder, TestFlight 2026-07-29): the verdict band's speaker button
    /// replayed the QUESTION on a screen the driver has already left behind, and
    /// sat two taps away from the "hear it" that replays the answer + why. One
    /// replay affordance survives — the card's, not the band's.
    @Test("The verdict band has no replay-question speaker; 'hear it' is the only replay")
    func verdictBandHasNoReadAloudControl() async throws {
        let evaluation = Evaluation(
            userAnswer: "Paris", result: .correct, points: 1.0,
            correctAnswer: "Paris", questionId: "q_test",
            explanation: "Paris has been the capital since the 10th century."
        )
        let view = ResultView(viewModel: makeViewModel(
            evaluation: evaluation,
            question: makeQuestion(explanation: "Paris has been the capital since the 10th century.")
        ))

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) {
                _ = try tree.find(viewWithAccessibilityIdentifier: "result.readAloud")
            }
            // #250: the explanation reads itself by default; tapping its text
            // is the one replay left.
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "result.explanationRead")
            }
        }
    }

    // MARK: - #250: "hear it" only when the result does not read by itself

    /// #250: with explanations the result reads its explanation by itself, so
    /// a "hear it" button beside it would only repeat what is already playing.
    @Test("'hear it' is hidden while the result reads its explanation")
    func hearItHiddenDuringAutoRead() async throws {
        let why = "Paris has been the capital since the 10th century."
        let evaluation = Evaluation(
            userAnswer: "Paris", result: .correct, points: 1.0,
            correctAnswer: "Paris", questionId: "q_test", explanation: why
        )
        let vm = makeViewModel(evaluation: evaluation, question: makeQuestion(explanation: why))
        let view = ResultView(viewModel: vm)

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect((try? tree.find(viewWithAccessibilityIdentifier: "result.hearIt")) == nil)
            #expect(throws: Never.self, "a tap on the text still reads it") {
                try tree.find(viewWithAccessibilityIdentifier: "result.explanationRead")
            }
        }
    }

    /// #252 (founder 2026-11-27): the Home "Game mode" promises that a quick
    /// game shows only right or wrong, and "With explanations" adds the
    /// explanation and its source. If the quick result kept them, the two
    /// modes would look the same and the menu would describe nothing real.
    @Test("Quick game hides the explanation and the source; with explanations shows both", arguments: [false, true])
    func quickGameShowsOnlyTheVerdict(quickGame: Bool) async throws {
        let why = "Paris has been the capital since the 10th century."
        let evaluation = Evaluation(
            userAnswer: "Paris", result: .correct, points: 1.0,
            correctAnswer: "Paris", questionId: "q_test", explanation: why
        )
        let vm = makeViewModel(evaluation: evaluation, question: makeQuestion(explanation: why))
        vm.settings.quickGame = quickGame
        let view = ResultView(viewModel: vm)

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let explanation = try? tree.find(viewWithAccessibilityIdentifier: "result.explanation")
            let source = try? tree.find(viewWithAccessibilityIdentifier: "result.source")
            #expect((explanation == nil) == quickGame)
            #expect((source == nil) == quickGame)
            #expect(throws: Never.self, "the verdict stays in both modes") {
                try tree.find(viewWithAccessibilityIdentifier: "result.verdict")
            }
        }
    }

    // MARK: - Score / streak are off the result screen (#132)

    /// #84 (founder decision 5) banned a streak *echo*; #131 Track D demoted score
    /// and streak into the muted meta row instead. #132 finishes the job — a
    /// per-question result says nothing about the running total, so the numbers
    /// leave the screen entirely. The meta row survives for what the driver still
    /// needs: what they said, and where the answer came from.
    @Test("Correct variant shows no score or streak anywhere on the screen")
    func correctVariantHasNoScoreOrStreak() async throws {
        let evaluation = Evaluation(
            userAnswer: "Paris", result: .correct, points: 1.0,
            correctAnswer: "Paris", questionId: "q_test", explanation: nil
        )
        let vm = makeViewModel(evaluation: evaluation)
        vm.quizStats.recordAnswer(isCorrect: true)
        let view = ResultView(viewModel: vm)

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            for banned in ["score", "streak", "+1"] {
                #expect(throws: (any Error).self, "\(banned) is back on the result screen") {
                    _ = try tree.find(text: banned)
                }
            }
            // The row itself stays — it still carries the source link.
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "result.metaRow") }
            #expect(vm.quizStats.currentStreak == 1)
        }
    }

    @Test("Incorrect variant shows no score or streak, but keeps 'you said'")
    func incorrectVariantHasNoScoreOrStreak() async throws {
        let evaluation = Evaluation(
            userAnswer: "London", result: .incorrect, points: 0.0,
            correctAnswer: "Paris", questionId: "q_test", explanation: nil
        )
        let view = ResultView(viewModel: makeViewModel(evaluation: evaluation))

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            for banned in ["score", "streak", "+0"] {
                #expect(throws: (any Error).self, "\(banned) is back on the result screen") {
                    _ = try tree.find(text: banned)
                }
            }
            // #194 R-Wrong: "you said" moved from the meta row up under the
            // answer on the card — the driver sees both answers together.
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "result.said") }
        }
    }

    // MARK: - MCQ answer reads as letter + option text (#132)

    private static func makeMCQQuestion(_ options: [String: String]) -> Question {
        Question(
            id: "q_mcq", question: "Which structure is in Giza?", type: .textMultichoice,
            possibleAnswers: options,
            difficulty: "easy", topic: "History", category: "adults",
            sourceUrl: nil, sourceExcerpt: nil, mediaUrl: nil, imageSubtype: nil,
            explanation: nil, generatedBy: nil
        )
    }

    /// Founder, TestFlight 2026-07-29: an MCQ result showed a bare "b" as the
    /// answer — the option KEY is meaningless once the options are off screen.
    /// Older backends/sessions still send that key, so it must resolve to the
    /// option text the question already carries.
    @Test("MCQ answer given as a key renders as 'B — <option text>'")
    func mcqKeyAnswerRendersLetterAndOptionText() async throws {
        let mcq = Self.makeMCQQuestion(["a": "Colosseum", "b": "Pyramid", "c": "Parthenon", "d": "Stonehenge"])
        let evaluation = Evaluation(
            userAnswer: "Colosseum", result: .incorrect, points: 0.0,
            correctAnswer: "b", questionId: "q_mcq", explanation: nil
        )
        let view = ResultView(viewModel: makeViewModel(evaluation: evaluation, question: mcq))

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "B — Pyramid") }
        }
    }

    /// The other direction: the current backend serves the TRANSLATED option text,
    /// so the letter has to be recovered from `possibleAnswers` instead. Both
    /// directions must land on the same "letter — text" shape, whatever language
    /// the option is in (the client does no language logic — it renders whatever
    /// `possibleAnswers` holds).
    @Test("MCQ answer given as option text renders as '<KEY> — <option text>'")
    func mcqTextAnswerRendersLetterAndOptionText() async throws {
        let mcq = Self.makeMCQQuestion(["a": "Koloseum", "b": "Pyramída", "c": "Parthenón", "d": "Stonehenge"])
        let evaluation = Evaluation(
            userAnswer: "Koloseum", result: .incorrect, points: 0.0,
            correctAnswer: "pyramída", questionId: "q_mcq", explanation: nil
        )
        let view = ResultView(viewModel: makeViewModel(evaluation: evaluation, question: mcq))

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            // Case-insensitive match, and the option's own casing is what renders.
            #expect(throws: Never.self) { try tree.find(text: "B — Pyramída") }
        }
    }

    /// The fallback must be silent: an answer that matches neither a key nor an
    /// option text — and a question with no options at all — renders unchanged,
    /// never with a stray letter prefix or an empty dash.
    @Test("Answers matching neither a key nor an option text render unchanged")
    func unmatchedAnswersRenderUnchanged() async throws {
        // Open question — no possibleAnswers at all.
        let openEval = Evaluation(
            userAnswer: "Saturn", result: .incorrect, points: 0.0,
            correctAnswer: "Uranus", questionId: "q_test", explanation: nil
        )
        let openView = ResultView(viewModel: makeViewModel(evaluation: openEval))
        try await ViewHosting.host(openView) {
            let tree = try openView.inspect()
            #expect(throws: Never.self) { try tree.find(text: "Uranus") }
            #expect(throws: (any Error).self) { _ = try tree.find(text: "U — Uranus") }
        }

        // MCQ whose evaluation carries an answer that is in neither column.
        let mcq = Self.makeMCQQuestion(["a": "Colosseum", "b": "Pyramid"])
        let strayEval = Evaluation(
            userAnswer: "Colosseum", result: .incorrect, points: 0.0,
            correctAnswer: "The Great Sphinx", questionId: "q_mcq", explanation: nil
        )
        let strayView = ResultView(viewModel: makeViewModel(evaluation: strayEval, question: mcq))
        try await ViewHosting.host(strayView) {
            let tree = try strayView.inspect()
            #expect(throws: Never.self) { try tree.find(text: "The Great Sphinx") }
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

    /// #188 G5 (founder 2026-10-06): a miss is shown mildly ("not quite"), so
    /// it must not be felt as the harshest pattern the system has — one soft
    /// tap for every non-correct verdict, and a correct answer still feels
    /// different from a miss.
    @Test("a miss gets one soft tap, never the error or warning buzz")
    @MainActor
    func missHapticIsSoftTap() {
        #expect(ResultView.haptic(for: .correct) == .success)
        for result in [Evaluation.EvaluationResult.incorrect, .partiallyCorrect, .partiallyIncorrect] {
            #expect(ResultView.haptic(for: result) == ResultView.missHaptic)
            #expect(ResultView.haptic(for: result) != .error)
            #expect(ResultView.haptic(for: result) != .warning)
        }
    }
}

// MARK: - CTA countdown (#108B)

/// #108B: the auto-advance countdown lives inside the "Next question" CTA. The
/// pause is the toolbar's (TF build 90 removed the STAY/RESUME pill).
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
        vm.isPaused = false
        vm.autoAdvanceCountdown = countdown
        vm.settings.autoAdvanceDelay = 10
        return vm
    }

    @Test("Active auto-advance shows the seconds chip in the CTA")
    func activeCountdownShowsChipAndStay() async throws {
        let vm = makeCountdownViewModel(countdown: 7)
        let view = ResultView(viewModel: vm)

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "7s") }
            #expect(throws: (any Error).self) { try tree.find(text: "Next in 7s") }
        }
    }

    @Test("Paused countdown hides the chip and keeps Next")
    func pausedCountdownSwapsPill() async throws {
        let vm = makeCountdownViewModel(countdown: 7)
        vm.isPaused = true
        let view = ResultView(viewModel: vm)

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) { try tree.find(text: "7s") }
            #expect(throws: Never.self) { try tree.find(text: "Next") }
        }
    }
}
