//
//  HeroScreenSnapshotTests.swift
//  HangsTests
//
//  #180 track F: the four hero screens frozen as snapshots × sk/cs/en.
//
//  Two strategies, two jobs:
//  - The TEXT CONTRACT (`.lines`) lists every Text the screen renders, resolved
//    for the language, plus every accessibility identifier — what an agent
//    reading a diff in a terminal can act on, and what `snapshot_ui` would show.
//    It does not depend on the simulator runtime, so it gates every CI run: a
//    missing translation, a lost identifier or a dropped element fails the PR
//    with a readable diff.
//  - The PIXEL snapshots (`.image`, 1× scale, default and accessibility Dynamic
//    Type) catch layout drift the contract cannot see — a wrapped hero label in
//    Slovak, a CTA pushed off screen at large type. Rendering differs between
//    iOS runtimes, so they are tied to the runtime they were recorded on
//    (`SnapshotBaseline.iosVersion`) and are visibly SKIPPED elsewhere instead
//    of silently passing or failing on font metrics.
//
//  Baselines live in `__Snapshots__/HeroScreenSnapshotTests/` and are committed.
//  Never re-record to make a red run green: a diff from an intentional UI change
//  is re-recorded on purpose (`TEST_RUNNER_SNAPSHOT_TESTING_RECORD=all`) after a
//  human looked at it; see `.claude/rules/ios.md`.
//

import Clocks
import Foundation
@testable import Hangs
import SnapshotTesting
import SwiftUI
import Testing
import UIKit
import ViewInspector

// MARK: - Baseline

nonisolated enum SnapshotBaseline {
    /// Simulator runtime the pixel baselines were recorded on. Bump it only when
    /// re-recording the whole set on that runtime.
    static let iosVersion = "26.5"
    /// iPhone 17 Pro logical size — the device the RS suite and CI both use.
    static let width: CGFloat = 402
    static let height: CGFloat = 874

    static var runtimeMatches: Bool {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)" == iosVersion
    }
}

nonisolated enum HeroLanguage: String, CaseIterable {
    case en, sk, cs
    var locale: Locale { Locale(identifier: rawValue) }
}

// MARK: - Screens

/// The four screens a driver sees in one quiz, each in a fixed, settled state and
/// without the DEBUG-only surfaces (model badge, state label) so the baseline is
/// the shipped screen.
/// Time-relative copy is anchored so it reads the same on every run: the free
/// quota resets in 12½ days ("resets in 13 days" on Home, "12d 0h" on the wall).
@MainActor
enum HeroScreen: String, CaseIterable {
    case home, question, result, paywall

    func make() async -> AnyView {
        switch self {
        case .home:
            let network = MockNetworkService()
            network.stubbedUsage = Self.freeUsage
            let vm = QuizViewModel(
                networkService: network,
                audioService: MockAudioService(),
                persistenceStore: MockPersistenceStore(),
                silenceDetectionService: MockSilenceDetectionService(),
                clock: AnyClock(TestClock())
            )
            vm.usageInfo = Self.freeUsage
            return AnyView(HomeView(viewModel: vm))

        case .question:
            let vm = Self.quizViewModel()
            vm.quizState = .askingQuestion
            return AnyView(QuestionView(viewModel: vm, debugSurfaces: false))

        case .result:
            let vm = Self.quizViewModel()
            let evaluation = Evaluation(
                userAnswer: "Paris", result: .correct, points: 1.0,
                correctAnswer: "Paris", questionId: Question.preview.id,
                explanation: Question.preview.explanation
            )
            vm.quizState = .showingResult(question: Question.preview, evaluation: evaluation)
            return AnyView(ResultView(viewModel: vm, debugSurfaces: false))

        case .paywall:
            let purchases = MockPurchaseService()
            purchases.stubbedOfferings = PurchasableOfferings(
                monthly: PurchasableProduct(id: StoreProduct.monthlySubId, displayPrice: "€4.99", displayName: "Hangs Unlimited"),
                pack: PurchasableProduct(id: StoreProduct.packId, displayPrice: "€2.99", displayName: "100 Question Pack")
            )
            purchases.stubbedIsEntitled = false
            let store = StoreManager(purchaseService: purchases)
            await store.loadOfferings()
            let wall = QuotaLimitError(
                error: "Monthly limit reached",
                questionsUsed: 30,
                questionsLimit: 30,
                resetsAt: Self.iso8601(Self.resetDate(plusMinutes: 30)),
                upgradeAvailable: true
            )
            return AnyView(PaywallView(storeManager: store, limitError: wall, onDismiss: {}))
        }
    }

    private static func quizViewModel() -> QuizViewModel {
        let vm = Fixtures.makeViewModel(clock: AnyClock(TestClock()))
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Question.preview
        return vm
    }

    private static var freeUsage: UsageInfo {
        UsageInfo(
            userId: "snapshot-subject",
            isPremium: false,
            questionsUsed: 12,
            questionsLimit: 30,
            remaining: 18,
            resetsAt: iso8601(resetDate(plusMinutes: 12 * 60)),
            subscriptionStatus: "none",
            creditBalance: 0
        )
    }

    /// 12 days out plus a margin that keeps both countdowns on a stable value.
    private static func resetDate(plusMinutes minutes: Double) -> Date {
        Date().addingTimeInterval(12 * 86400 + minutes * 60)
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

// MARK: - Text contract

/// Every rendered Text (resolved for `language`) and every accessibility
/// identifier, in tree order. `String(localized:)` values built in view models
/// stay in the process language (English) — only SwiftUI `Text` keys switch.
@MainActor
private func buildTextContract(of screen: HeroScreen, in language: HeroLanguage) async throws -> String {
    let view = await screen.make()
    var lines: [String] = ["# texts"]
    try await ViewHosting.host(view, function: "\(screen.rawValue)-\(language.rawValue)") {
        let tree = try view.inspect()
        for text in tree.findAll(ViewType.Text.self) {
            if let value = try? text.string(locale: language.locale) {
                lines.append(value)
            }
        }
        lines.append("# identifiers")
        for node in tree.findAll(where: { (try? $0.accessibilityIdentifier()) != nil }) {
            if let id = try? node.accessibilityIdentifier() {
                lines.append(id)
            }
        }
    }
    return lines.joined(separator: "\n")
}

@Suite("Hero screen snapshots")
@MainActor
struct HeroScreenSnapshotTests {
    @Test("text contract", arguments: HeroScreen.allCases, HeroLanguage.allCases)
    func textContract(screen: HeroScreen, language: HeroLanguage) async throws {
        let contract = try await buildTextContract(of: screen, in: language)
        assertSnapshot(of: contract, as: .lines, named: "\(screen.rawValue)-\(language.rawValue)")
    }

    @Test(
        "pixels",
        .enabled(if: SnapshotBaseline.runtimeMatches, "pixel baselines were recorded on iOS \(SnapshotBaseline.iosVersion); re-record on this runtime to enable them here"),
        arguments: HeroScreen.allCases, HeroLanguage.allCases
    )
    func pixels(screen: HeroScreen, language: HeroLanguage) async {
        let view = await screen.make().environment(\.locale, language.locale)
        let strategy: Snapshotting<AnyView, UIImage> = .image(
            precision: 0.99,
            perceptualPrecision: 0.98,
            layout: .fixed(width: SnapshotBaseline.width, height: SnapshotBaseline.height),
            traits: UITraitCollection(displayScale: 1)
        )
        assertSnapshot(of: AnyView(view), as: strategy, named: "\(screen.rawValue)-\(language.rawValue)")
        assertSnapshot(
            of: AnyView(view.dynamicTypeSize(.accessibility2)),
            as: strategy,
            named: "\(screen.rawValue)-\(language.rawValue)-xl"
        )
    }
}
