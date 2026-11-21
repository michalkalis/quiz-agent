//
//  PhoneLanguageFollowTests.swift
//  HangsTests
//
//  #231 — Ukrainian as a fourth language. A fresh install picks its quiz (and
//  interface) language at startup, before the server's language list arrives.
//  The compiled fallback list has no uk on purpose (uk goes live by a server
//  switch), so a Ukrainian phone started its whole first session in English.
//  Once the list arrives, a player who never picked a language takes the
//  phone's language; a player who picked one is never switched.
//

import Foundation
@testable import Hangs
import Testing

/// One-shot async gate — holds the language fetch in flight deterministically.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

@MainActor
private final class FollowedLanguages {
    var codes: [String] = []
}

@MainActor
@Suite("First launch takes the phone language once the list arrives (#231)", .serialized)
struct PhoneLanguageFollowTests {
    private static let ukrainianOn = Language.selectableLanguages(in: ["en", "sk", "cs", "uk"])
    private static let fallback = Language.selectableLanguages(in: LanguageAvailability.fallbackQuizCodes)

    private struct Launch {
        let app: AppState
        let viewModel: QuizViewModel
        let interface: FollowedLanguages
        let defaults: UserDefaults
    }

    /// The app's own launch path on a clean phone: AppState, then the quiz
    /// view model loading settings from a real PersistenceStore.
    private func launch(phone: String, defaults: UserDefaults? = nil) throws -> Launch {
        let defaults = try defaults ?? isolatedDefaults()
        let interface = FollowedLanguages()
        let app = AppState(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: PersistenceStore(userDefaults: defaults, phoneLanguage: phone),
            followQuizLanguage: { interface.codes.append($0) }
        )
        let viewModel = app.sharedQuizViewModel()
        return Launch(app: app, viewModel: viewModel, interface: interface, defaults: defaults)
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "PhoneLanguageFollowTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// WHY: the reported bug. Without the re-pick the quiz and the whole
    /// interface stayed English until the player found the picker.
    @Test("a fresh install on a Ukrainian phone switches to Ukrainian when the list brings it")
    func lateListBringsUkrainian() async throws {
        let run = try launch(phone: "uk")
        #expect(run.viewModel.settings.language == "en")

        await run.app.refreshLanguages(refresh: {}, offered: { Self.ukrainianOn })

        #expect(run.viewModel.settings.language == "uk")
        #expect(run.interface.codes.last == "uk", "the interface follows the quiz language")
    }

    /// WHY: a player's own pick must never be overridden, also when they
    /// picked English because Ukrainian was not in the menu yet.
    @Test("a player who picked a language keeps it", arguments: ["en", "sk"])
    func chosenLanguageStays(choice: String) async throws {
        let run = try launch(phone: "uk")
        run.viewModel.chooseLanguage(choice)

        await run.app.refreshLanguages(refresh: {}, offered: { Self.ukrainianOn })

        #expect(run.viewModel.settings.language == choice)
        // And on every later launch.
        let relaunch = try launch(phone: "uk", defaults: run.defaults)
        await relaunch.app.refreshLanguages(refresh: {}, offered: { Self.ukrainianOn })
        #expect(relaunch.viewModel.settings.language == choice)
    }

    /// WHY: an install from before this build cannot tell a deliberate pick
    /// from the default, so it is never switched.
    @Test("an install with settings saved before this build is never switched")
    func earlierInstallStays() async throws {
        let defaults = try isolatedDefaults()
        PersistenceStore(userDefaults: defaults, phoneLanguage: "uk").saveSettings(.default)
        let run = try launch(phone: "uk", defaults: defaults)

        await run.app.refreshLanguages(refresh: {}, offered: { Self.ukrainianOn })

        #expect(run.viewModel.settings.language == "en")
    }

    /// WHY: uk stays switched off on the server until approved; a failed or
    /// empty fetch leaves the compiled list, which has no uk.
    @Test("a list without Ukrainian, or a failed fetch, leaves the app in English")
    func listWithoutUkrainianStaysEnglish() async throws {
        let run = try launch(phone: "uk")

        await run.app.refreshLanguages(refresh: {}, offered: { Self.fallback })

        #expect(run.viewModel.settings.language == "en")
        #expect(!run.interface.codes.contains("uk"))
    }

    /// WHY: the fetch can take its full 15 s on a cold server. The app must
    /// stay usable in English meanwhile, and a pick made during the wait wins.
    @Test("while the list is slow the app stays English and usable; a pick made meanwhile wins")
    func slowListNeverOverridesAPickMadeMeanwhile() async throws {
        let run = try launch(phone: "uk")
        let gate = Gate()
        let fetch = Task { await run.app.refreshLanguages(refresh: { await gate.wait() }, offered: { Self.ukrainianOn }) }
        for _ in 0 ..< 20 {
            await Task.yield()
        } // the fetch is now parked at the gate

        #expect(run.viewModel.settings.language == "en")
        guard case .idle = run.viewModel.quizState else {
            Issue.record("the quiz must stay ready to start while the list is in flight")
            return
        }
        run.viewModel.chooseLanguage("sk")

        await gate.open()
        await fetch.value
        #expect(run.viewModel.settings.language == "sk")
    }

    /// WHY: switching under a running set would change the screen's language
    /// mid-quiz; the next launch catches up instead.
    @Test("a list that arrives mid-quiz waits for the next launch")
    func midQuizWaitsForNextLaunch() async throws {
        let run = try launch(phone: "uk")
        run.viewModel.quizState = .askingQuestion

        await run.app.refreshLanguages(refresh: {}, offered: { Self.ukrainianOn })
        #expect(run.viewModel.settings.language == "en")

        run.viewModel.settings.numberOfQuestions = 15 // something saved, not the language
        let relaunch = try launch(phone: "uk", defaults: run.defaults)
        await relaunch.app.refreshLanguages(refresh: {}, offered: { Self.ukrainianOn })
        #expect(relaunch.viewModel.settings.language == "uk")
    }
}
