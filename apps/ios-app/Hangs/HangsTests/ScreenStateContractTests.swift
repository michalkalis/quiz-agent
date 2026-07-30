//
//  ScreenStateContractTests.swift
//  HangsTests
//
//  #133 §2 — the ViewInspector layer that REPLACES the retired
//  `.dump` / `.stableDump` snapshot baselines (`HangsTests/Snapshots/`).
//
//  Why the dumps had to go: `Swift.dump()` of a SwiftUI view reflects the
//  *view-model property graph*, not the rendered view. It therefore proved
//  nothing about what a driver sees, while breaking on every new `@Published`
//  property (twice on 2026-07-30 alone) — false confidence plus recurring cost.
//
//  What replaces them: one test per retired baseline, at the altitude ios.md
//  "Verification Altitude" prescribes — expected elements present, wrong-state
//  elements ABSENT, state machine in the right state. No pixels, no layout.
//  Each test names the baseline it retires and encodes the CURRENT
//  (post-#125/#127/#131/#132 redesign) UI as expected.
//
//  Deliberately NOT re-asserted here (already covered, finer-grained):
//  explanation/source blocks (ResultViewInspectorTests), plan picker and
//  narrating CTA (PaywallViewInspectorTests), MCQ grid (QuestionViewInspector
//  Tests), plan card (HomeFreePlanCardTests). This file pins the per-state
//  SCREEN contract those suites assume.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

// MARK: - Helpers

/// True when any Text in the tree contains ALL the given fragments — used for
/// interpolated CTA labels whose LocalizedStringKey may or may not resolve.
@MainActor
private func treeHasText(_ tree: InspectableView<ViewType.ClassifiedView>, containing fragments: [String]) -> Bool {
    tree.findAll(ViewType.Text.self).contains { text in
        guard let value = try? text.string() else { return false }
        return fragments.allSatisfy { value.contains($0) }
    }
}

// MARK: - HomeView

@MainActor
@Suite("Screen contract — HomeView")
struct HomeViewStateContractTests {
    /// Retires `HomeViewSnapshotTests/idleWithStats.1.txt`.
    ///
    /// The baseline claimed hero + config card + primary CTA + `home.startQuiz`,
    /// but built the view model in `.askingQuestion` — the one state in which
    /// Home is never on screen. This pins the honest state: `.idle`, the screen
    /// the driver actually launches into, with the start CTA tappable and the
    /// in-flight Cancel control absent.
    ///
    /// The plan card is intentionally NOT asserted: `HomeView.onAppear` fires
    /// `refreshUsage()`, so which branch mounts (`home.freePlanLoading` vs
    /// `home.freePlanCard`) races the hosting. `HomeFreePlanCardTests` owns it.
    @Test("Idle Home renders wordmark, session config card and a tappable Start Quiz CTA")
    func idleHomeContract() async throws {
        let vm = Fixtures.makeViewModel()
        #expect(vm.quizState == .idle, "precondition: Home is the idle screen")

        let view = HomeView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()

            // Brand hero + tagline: the driver must land on a recognisable app.
            #expect(throws: Never.self) { try tree.find(text: "trubbo.") }
            #expect(throws: Never.self) { try tree.find(text: "voice-based trivia for the road") }

            // Session config card (its section label) — where difficulty /
            // language / categories are chosen before starting.
            #expect(throws: Never.self) { try tree.find(text: "session") }

            // The one CTA that must exist on Home, and it must be usable.
            let start = try tree.find(viewWithAccessibilityIdentifier: "home.startQuiz").button()
            #expect(throws: Never.self) { try start.tap() }

            // The in-flight variant belongs to `.startingQuiz` only.
            #expect(throws: (any Error).self) {
                try tree.find(viewWithAccessibilityIdentifier: "home.cancelStart")
            }
        }
    }
}

// MARK: - QuestionView (voice)

@MainActor
@Suite("Screen contract — QuestionView voice states")
struct QuestionViewStateContractTests {
    /// `Question.preview` is `.text` → the voice body (the driving-critical path).
    private func makeVoiceViewModel(state: QuizState) -> QuizViewModel {
        let vm = Fixtures.makeViewModel()
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Question.preview
        vm.quizState = state
        return vm
    }

    /// Retires `QuestionViewSnapshotTests/askingState.1.txt`.
    ///
    /// Asking = the question is readable and the mic is offered but NOT live.
    /// The absences are the point: a Stop button or a listening surface here
    /// would tell the driver we are recording when we are not.
    @Test("Asking state renders question, chrome and Record — no Stop, no listening surface")
    func askingStateContract() async throws {
        let vm = makeVoiceViewModel(state: .askingQuestion)
        let view = QuestionView(viewModel: vm)

        try await ViewHosting.host(view) {
            let tree = try view.inspect()

            for id in ["question.text", "question.category", "question.counter",
                       "question.timerStrip", "question.record", "question.skip"]
            {
                #expect(throws: Never.self, "\(id) must render while asking") {
                    try tree.find(viewWithAccessibilityIdentifier: id)
                }
            }

            #expect(throws: (any Error).self, "Stop belongs to .recording only") {
                try tree.find(viewWithAccessibilityIdentifier: "question.stop")
            }
            #expect(throws: (any Error).self, "the listening card must not claim we are recording") {
                try tree.find(viewWithAccessibilityIdentifier: "question.liveTranscript")
            }
            #expect(vm.quizState == .askingQuestion)
        }
    }

    /// Retires `QuestionViewSnapshotTests/recordingState.1.txt`.
    ///
    /// Recording = the mic is live, so the transcript card is the listening
    /// surface (#131 Track C) and the button flips to Stop. The command
    /// `listen-bar` must be gone — commands are not accepted mid-answer, and
    /// showing the bar would invite the driver to speak one.
    @Test("Recording state renders the listening card and Stop — no Record, no command bar")
    func recordingStateContract() async throws {
        let vm = makeVoiceViewModel(state: .recording)
        let view = QuestionView(viewModel: vm)

        try await ViewHosting.host(view) {
            let tree = try view.inspect()

            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "question.stop")
            }
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "question.liveTranscript")
            }
            #expect(throws: Never.self, "the card must say we are listening") {
                try tree.find(text: "LISTENING — SAY YOUR ANSWER")
            }
            // Question + countdown stay on screen while answering.
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "question.text")
            }
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "question.timerStrip")
            }

            #expect(throws: (any Error).self, "Record must not coexist with Stop") {
                try tree.find(viewWithAccessibilityIdentifier: "question.record")
            }
            #expect(throws: (any Error).self, "no command bar while the answer mic is live") {
                try tree.find(viewWithAccessibilityIdentifier: "listen-bar")
            }
            #expect(vm.quizState == .recording)
        }
    }
}

// MARK: - ResultView

@MainActor
@Suite("Screen contract — ResultView verdicts")
struct ResultViewStateContractTests {
    private func makeViewModel(_ evaluation: Evaluation) -> QuizViewModel {
        let vm = Fixtures.makeViewModel()
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Question.preview
        vm.quizState = .showingResult(question: Question.preview, evaluation: evaluation)
        return vm
    }

    /// Retires `ResultViewSnapshotTests/correctVariant.1.txt`.
    ///
    /// One verdict word, and the way onward. `result.continue` is the control the
    /// whole hands-free loop depends on — nothing else asserted its presence.
    @Test("Correct result states NAILED IT once and offers the continue CTA")
    func correctVerdictContract() async throws {
        let view = ResultView(viewModel: makeViewModel(.previewCorrect))

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "result.verdict") }
            #expect(throws: Never.self) { try tree.find(text: "NAILED IT.") }
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "result.continue") }
            // No competing verdict may appear on the same screen.
            #expect(throws: (any Error).self) { try tree.find(text: "MISSED IT.") }
            #expect(throws: (any Error).self) { try tree.find(text: "SKIPPED.") }
        }
    }

    /// Retires `ResultViewSnapshotTests/incorrectVariant.1.txt`.
    ///
    /// A wrong answer must reveal the right one and footnote what the driver
    /// said — the two things they need before the next question.
    @Test("Incorrect result states MISSED IT, reveals the answer and keeps the you-said row")
    func incorrectVerdictContract() async throws {
        let view = ResultView(viewModel: makeViewModel(.previewIncorrect))

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "result.verdict") }
            #expect(throws: Never.self) { try tree.find(text: "MISSED IT.") }
            #expect(throws: Never.self) { try tree.find(text: "the answer") }
            #expect(throws: Never.self) { try tree.find(text: "you said") }
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "result.continue") }
            #expect(throws: (any Error).self) { try tree.find(text: "NAILED IT.") }
            #expect(throws: (any Error).self) { try tree.find(text: "SKIPPED.") }
        }
    }

    /// Retires `ResultViewSnapshotTests/skippedVariant.1.txt`.
    ///
    /// A skip is not a failure: neutral verdict, and no "you said" row over an
    /// answer the driver never gave. Continue must still be there.
    @Test("Skipped result states SKIPPED neutrally with no you-said row")
    func skippedVerdictContract() async throws {
        let evaluation = Evaluation(
            userAnswer: "", result: .skipped, points: 0.0,
            correctAnswer: "Uranus", questionId: Question.preview.id, explanation: nil
        )
        let view = ResultView(viewModel: makeViewModel(evaluation))

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "result.verdict") }
            #expect(throws: Never.self) { try tree.find(text: "SKIPPED.") }
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "result.continue") }
            #expect(throws: (any Error).self) { try tree.find(text: "you said") }
            #expect(throws: (any Error).self) { try tree.find(text: "MISSED IT.") }
            #expect(throws: (any Error).self) { try tree.find(text: "NAILED IT.") }
        }
    }
}

// MARK: - PaywallView

/// A `PurchaseService` whose offerings fetch never returns, so `StoreManager`
/// parks in its genuine "still loading" window (`offerings == nil` AND
/// `hasAttemptedOfferingsLoad == false`) for the assertion. `MockPurchaseService`
/// cannot express this — it answers synchronously, and the moment it does the
/// paywall is either populated or offline. Same 60s-suspend trick the in-flight
/// CTA tests use; the test never awaits it, so nothing hangs.
@MainActor
private final class StalledOfferingsPurchaseService: PurchaseService {
    let entitlementUpdates: AsyncStream<EntitlementUpdate>

    init() {
        entitlementUpdates = AsyncStream { _ in }
    }

    func loadOfferings() async -> PurchasableOfferings? {
        try? await Task.sleep(for: .seconds(60))
        return nil
    }

    func purchase(productID _: String) async throws -> PurchaseOutcome {
        .success(unlimitedActive: true)
    }

    func restore() async throws {}

    func currentlyEntitled(entitlementId _: String) async -> Bool { false }

    func logIn(appUserID _: String) async {}
}

/// The purchase CTA's underlying `Button` — `HangsPrimaryButton` applies
/// `.disabled(isLoading)` inside its own body, so `isDisabled()` must be read
/// there and not on the wrapper the accessibility identifier tags.
@MainActor
private func ctaButton(
    in tree: InspectableView<ViewType.ClassifiedView>
) throws -> InspectableView<ViewType.Button> {
    try tree.find(viewWithAccessibilityIdentifier: "paywall-purchase-button")
        .find(ViewType.Button.self)
}

@MainActor
@Suite("Screen contract — PaywallView load states")
struct PaywallViewStateContractTests {
    private func makeStoreManager(offerings: PurchasableOfferings?) async -> StoreManager {
        let mock = MockPurchaseService()
        mock.stubbedOfferings = offerings
        mock.stubbedIsEntitled = false
        let manager = StoreManager(purchaseService: mock)
        // Drain the init load so @Published state has settled.
        await Task.yield()
        await Task.yield()
        return manager
    }

    /// Retires `PaywallViewSnapshotTests/limitErrorWithCountdown.1.txt`.
    ///
    /// Quota hit with the store reachable: the driver must see when their free
    /// questions come back (the countdown) AND what upgrading costs — a paywall
    /// that shows neither is a dead end.
    @Test("Quota-hit paywall with a loaded product shows the reset countdown and the price")
    func limitErrorWithProductContract() async throws {
        let offerings = PurchasableOfferings(
            monthly: PurchasableProduct(
                id: StoreProduct.monthlySubId, displayPrice: "€4.99", displayName: "Hangs Unlimited"
            ),
            annual: nil,
            pack: nil
        )
        let manager = await makeStoreManager(offerings: offerings)
        let limitError = QuotaLimitError(
            error: "Daily limit reached",
            questionsUsed: 10,
            questionsLimit: 10,
            resetsAt: "2099-01-01T08:00:00.000Z",
            upgradeAvailable: true
        )
        let view = PaywallView(storeManager: manager, limitError: limitError, onDismiss: {})
        #expect(!view.isOffline, "precondition: offerings loaded → normal paywall")

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "paywall.headline") }
            #expect(throws: Never.self) { try tree.find(text: "GO UNLIMITED") }
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "paywall.countdownPill") }
            #expect(treeHasText(tree, containing: ["4.99"]), "the CTA must state what it costs")
            // The `.disabled` lives on the Button inside HangsPrimaryButton, one
            // level below the a11y id — so reach the Button, not the wrapper
            // (asserting on the wrapper passes vacuously either way).
            #expect(try !ctaButton(in: tree).isDisabled(), "a loaded product must be buyable")
        }
    }

    /// Retires `PaywallViewSnapshotTests/noLimitErrorProductLoading.1.txt`.
    ///
    /// Proactive entry while the offerings fetch is STILL IN FLIGHT: no countdown
    /// (nothing has run out), a CTA that is un-tappable rather than pretending a
    /// price it does not have yet, and — the invariant that matters — NOT the
    /// offline variant. Crying "can't reach the store" while the store is still
    /// answering would kill the upgrade on a slow connection.
    ///
    /// Needs `StalledOfferingsPurchaseService`: the retired baseline built this
    /// state with `MockPurchaseService`, which answers instantly and flips
    /// `hasAttemptedOfferingsLoad`, so what it actually captured was the OFFLINE
    /// body — its own doc comment ("CTA uses the loading branch") had gone stale
    /// unnoticed, which is precisely what a property dump cannot catch.
    @Test("Proactive paywall with the offerings fetch in flight hides the countdown, disables the CTA, and is not offline")
    func productLoadingContract() async throws {
        let manager = StoreManager(purchaseService: StalledOfferingsPurchaseService())
        await Task.yield()
        await Task.yield()
        let view = PaywallView(storeManager: manager, limitError: nil, onDismiss: {})
        #expect(!view.isOffline, "fetch still in flight → loading, not offline")

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "paywall.headline") }
            #expect(throws: Never.self) { try tree.find(text: "GO UNLIMITED") }
            #expect(throws: (any Error).self, "no quota error → nothing to count down to") {
                try tree.find(viewWithAccessibilityIdentifier: "paywall.countdownPill")
            }
            #expect(try ctaButton(in: tree).isDisabled(),
                    "the CTA must not be tappable before a product exists")
            #expect(throws: (any Error).self, "the offline variant belongs to a FAILED load") {
                try tree.find(viewWithAccessibilityIdentifier: "paywall.offline.headline")
            }
        }
    }
}
