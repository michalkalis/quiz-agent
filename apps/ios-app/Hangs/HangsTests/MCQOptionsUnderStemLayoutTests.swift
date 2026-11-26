//
//  MCQOptionsUnderStemLayoutTests.swift
//  HangsTests
//
//  #249.2 (founder, 2026-11-26): on a multiple-choice question the options sat
//  low under a big empty gap (the answer timer's reserved slot, kept even while
//  it showed nothing), so with a long question the options scrolled and a
//  "SCROLL" hint appeared although all four would have fit. This renders the
//  real screen at a small-phone size and measures it: the options list must
//  need no scrolling when the question is long but the options are short.
//

import Clocks
import Foundation
@testable import Hangs
import SwiftUI
import Testing
import UIKit

@MainActor
@Suite("MCQ options sit right under a long question (#249.2)")
struct MCQOptionsUnderStemLayoutTests {
    /// About 7 lines of question at the screen's title size on a 390 pt phone,
    /// with the 1 to 2 line options a typical question has.
    private static let longStem = Question(
        id: "q_layout_long_stem_001",
        question: "Which European capital, founded as a Roman settlement on a major river and later the seat of a dual monarchy, is famous for its thermal baths and its grand riverside parliament?",
        type: .textMultichoice,
        possibleAnswers: [
            "a": "Vienna, on the Danube",
            "b": "Budapest, on the Danube",
            "c": "Prague, on the Vltava",
            "d": "Bratislava, on the Danube",
        ],
        difficulty: "hard", topic: "Geography", category: "history",
        sourceUrl: nil, sourceExcerpt: nil, mediaUrl: nil, imageSubtype: nil,
        explanation: nil, generatedBy: nil,
        optionLabels: ["a": "A", "b": "B", "c": "C", "d": "D"]
    )

    private func host(thinking: Bool, size: CGSize) async -> UIWindow {
        let vm = Fixtures.makeViewModel(clock: AnyClock(TestClock()))
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Self.longStem
        vm.quizState = .askingQuestion
        if thinking {
            vm.settings.thinkingTime = 30
            vm.thinkingTimeCountdown = 27
        }
        let view = QuestionView(viewModel: vm, debugSurfaces: false)
            .environment(\.hangsCardMotion, false)
            .environment(\.colorScheme, .dark)
            .dynamicTypeSize(.large)
        let controller = UIHostingController(rootView: view)
        // The notch and home indicator take their share on a real phone.
        controller.additionalSafeAreaInsets = UIEdgeInsets(top: size.height > 860 ? 62 : 47, left: 0, bottom: 34, right: 0)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        // Scroll geometry and the measured stem height settle over a few turns.
        for _ in 0 ..< 12 {
            try? await Task.sleep(for: .milliseconds(50))
            controller.view.layoutIfNeeded()
        }
        return window
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        var found: [UIScrollView] = []
        if let scroll = view as? UIScrollView { found.append(scroll) }
        for sub in view.subviews {
            found += scrollViews(in: sub)
        }
        return found
    }

    /// The options list is the lowest scroll region on the screen.
    private func optionsScroll(in window: UIWindow) -> UIScrollView? {
        scrollViews(in: window)
            .filter { $0.bounds.height > 50 }
            .max { $0.convert($0.bounds, to: window).minY < $1.convert($1.bounds, to: window).minY }
    }

    @Test("all four short options fit without scrolling under a long question, timer showing",
          arguments: [CGSize(width: 390, height: 844), CGSize(width: 402, height: 874)])
    func optionsFitWithTimerBar(size: CGSize) async throws {
        let window = await host(thinking: true, size: size)
        let options = try #require(optionsScroll(in: window))
        #expect(options.contentSize.height <= options.bounds.height + 1,
                "the options list scrolls (content \(options.contentSize.height) > \(options.bounds.height)): space between the question and the options is being wasted")
    }

    @Test("all four short options fit without scrolling under a long question, no timer",
          arguments: [CGSize(width: 390, height: 844), CGSize(width: 402, height: 874)])
    func optionsFitWithoutTimerBar(size: CGSize) async throws {
        let window = await host(thinking: false, size: size)
        let options = try #require(optionsScroll(in: window))
        #expect(options.contentSize.height <= options.bounds.height + 1,
                "the options list scrolls (content \(options.contentSize.height) > \(options.bounds.height))")
    }
}
