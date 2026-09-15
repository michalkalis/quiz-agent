//
//  QuestionSkipControlTests.swift
//  HangsTests
//
//  #179 D3 (founder 2026-09-15) — ONE skip control on both question screens.
//
//  The field finding (TestFlight build 61): MCQ offered a capsule reading
//  "Preskočiť otázku", the open question a bare word "Preskoč", and the voice
//  command is "preskoč" — three shapes and two words for the one escape hatch a
//  driver has from a question they cannot answer. What these tests defend:
//
//   - both screens render the SAME control (same capsule, same chevron, same
//     word), so it is found in the same form wherever the driver is;
//   - the word is the imperative "Skip" — which IS the voice command, so
//     reading the button teaches it (#174);
//   - the founder's layout condition survives the change: the open question's
//     bottom row stays ONE line (Start · Type · Skip), and the label shrinks
//     before it ever wraps;
//   - the #174 in-flight spinner still lives in the capsule that started the
//     skip, on both screens, with the label still there so the capsule cannot
//     change width under a thumb.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@MainActor
private func makeViewModel(question: Question, state: QuizState = .askingQuestion) -> QuizViewModel {
    let vm = Fixtures.makeViewModel()
    vm.currentSession = Fixtures.makeActiveSession()
    vm.currentQuestion = question
    vm.quizState = state
    vm.settings.autoRecordEnabled = false
    return vm
}

@MainActor
@Suite("Skip — one control, one imperative word, on both question screens (#179 D3)")
struct QuestionSkipControlTests {
    /// The shared component itself: capsule chrome, the #171 double chevron, and
    /// the imperative word. Everything below asserts that BOTH screens show this.
    @Test("the shared control is the chevron capsule carrying the word Skip")
    func sharedControlShape() async throws {
        let button = QuestionSkipButton(isSkipping: false, isDisabled: false) {}
        try await ViewHosting.host(button) {
            let tree = try button.inspect()
            let glyphs = tree.findAll(ViewType.Image.self).compactMap { try? $0.actualImage().name() }
            #expect(glyphs == ["chevron.right.2"], "the skip glyph drifted: \(glyphs)")
            #expect(throws: Never.self) { try tree.find(text: "Skip") }
        }
    }

    /// The heart of D3: MCQ used to say "Skip question", the voice footer
    /// "Skip". Same key on both now — so a translator cannot re-split them
    /// either, which is how "Preskoč" and "Preskočiť otázku" happened.
    @Test("both question screens render the same skip capsule and the same word",
          arguments: [Question.previewMCQ, Question.preview])
    func bothScreensShareOneControl(question: Question) async throws {
        let view = QuestionView(viewModel: makeViewModel(question: question))
        try await ViewHosting.host(view) {
            let skip = try view.inspect().find(viewWithAccessibilityIdentifier: "question.skip")
            let glyphs = skip.findAll(ViewType.Image.self).compactMap { try? $0.actualImage().name() }
            #expect(glyphs.contains("chevron.right.2"),
                    "\(question.isMultipleChoice ? "MCQ" : "voice") skip lost the chevron: \(glyphs)")
            #expect(throws: Never.self, "the imperative word must be on screen — it is the voice command") {
                try skip.find(text: "Skip")
            }
            #expect(throws: (any Error).self, "the old infinitive label must be gone") {
                _ = try skip.find(text: "Skip question")
            }
        }
    }

    /// #174, kept: a skip in flight spins in the control that started it, on
    /// both screens, and the label stays so the capsule keeps its width.
    @Test("a skip in flight spins in the capsule on both screens, label intact",
          arguments: [Question.previewMCQ, Question.preview])
    func skippingSpinsInTheCapsule(question: Question) async throws {
        let view = QuestionView(viewModel: makeViewModel(question: question, state: .skipping))
        try await ViewHosting.host(view) {
            let skip = try view.inspect().find(viewWithAccessibilityIdentifier: "question.skip")
            #expect(throws: Never.self) {
                try skip.find(viewWithAccessibilityIdentifier: "question.processingIndicator")
            }
            #expect(throws: Never.self, "the label must survive so the capsule keeps its width") {
                try skip.find(text: "Skip")
            }
        }
    }

    /// Founder's condition on D1–D3 alike: the open question's bottom row stays
    /// ONE line. A wider skip capsule must not push Type or Start onto a second
    /// row — so the row is asserted as a single HStack of exactly three
    /// controls, and the word is pinned to one line that scales instead.
    @Test("the open question's action row stays one line of three controls")
    func actionRowStaysOneLine() async throws {
        let view = QuestionView(viewModel: makeViewModel(question: Question.preview))
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let row = try tree.find(ViewType.HStack.self, where: { stack in
                (try? stack.find(viewWithAccessibilityIdentifier: "question.record")) != nil
                    && (try? stack.find(viewWithAccessibilityIdentifier: "question.skip")) != nil
            })
            #expect(row.count == 3, "the action row must stay Start · Type · Skip on one line, got \(row.count)")

            let label = try tree.find(viewWithAccessibilityIdentifier: "question.skip").find(text: "Skip")
            #expect(try label.lineLimit() == 1, "the skip word must shrink, never wrap")
        }
    }

    /// The MCQ half of the same condition: the pinned footer (#179 T5) carries
    /// the capsule and nothing else that could share — or steal — its line.
    @Test("the MCQ pinned footer carries the skip capsule on its own line")
    func mcqFooterStaysOneLine() async throws {
        let vm = makeViewModel(question: Question.previewMCQLongOptions)
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let footer = try view.inspect().find(ViewType.SafeAreaInset.self)
            let skip = try footer.find(viewWithAccessibilityIdentifier: "question.skip")
            #expect(try skip.find(text: "Skip").lineLimit() == 1,
                    "a wrapped label is what pushed the chip off the screen in the first place")
        }
    }
}
