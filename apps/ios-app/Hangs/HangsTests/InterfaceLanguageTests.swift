//
//  InterfaceLanguageTests.swift
//  HangsTests
//
//  Founder (car test 2026-10-30, TestFlight build 81): the quiz was in Slovak,
//  the buttons and labels in English. The interface followed the phone, not
//  the quiz. Now one language runs the whole app and it switches live: SwiftUI
//  text through the root locale, text built in code through the interface
//  bundle. These tests hold the second half, which no `\.locale` can reach.
//
//  Every Slovak window below is synchronous on the main actor and restored
//  before it returns: the interface language is process-wide, and no other
//  test may ever see it switched.
//

import Foundation
@testable import Hangs
import Testing

@Suite("Founder 2026-10-30: the whole app speaks the quiz language")
@MainActor
struct InterfaceLanguageTests {
    /// WHY: messages, option lists and CarPlay titles are built in code; they
    /// stayed in the phone's language while the screens around them switched.
    /// Lists that were computed once also kept the language of first use.
    @Test("a quiz in Slovak turns text built in code Slovak, without a restart")
    func textBuiltInCodeFollowsTheQuiz() {
        defer { InterfaceLanguage.set(nil) }
        InterfaceLanguage.apply(quizLanguage: "en")
        #expect(RoomViewModel.genericMessage == "Something went wrong. Try again.")
        #expect(Config.difficultyOptions.first?.1 == "Easy")

        InterfaceLanguage.apply(quizLanguage: "sk")
        #expect(RoomViewModel.genericMessage == "Niečo sa pokazilo. Skús to znova.")
        #expect(Config.difficultyOptions.first?.1 == "Ľahká", "an option list kept the language it was first read in")
        #expect(AudioDevice.automatic.name == "Automaticky")
        #expect(Language.default.name == "Angličtina")
        #expect(String(localized: "\(3) questions", bundle: .interface, locale: .interface) == "3 otázky", "plural forms come from the same language")
    }

    /// WHY: the root view and the code-built text must name the same language,
    /// or one screen mixes two again. Picking it is the quiz-language picker.
    @Test("picking a quiz language moves the app root's locale and the code-built text together")
    func pickerSwitchesTheWholeApp() {
        defer { InterfaceLanguage.set(nil) }
        let appState = AppState(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            followQuizLanguage: InterfaceLanguage.apply
        )
        let viewModel = appState.sharedQuizViewModel()

        viewModel.settings.language = "sk"
        #expect(appState.interfaceLocale.language.languageCode?.identifier == "sk")
        #expect(RoomViewModel.genericMessage == "Niečo sa pokazilo. Skús to znova.")

        viewModel.settings.language = "en"
        #expect(appState.interfaceLocale.language.languageCode?.identifier == "en")
        #expect(RoomViewModel.genericMessage == "Something went wrong. Try again.")
    }

    /// WHY: quiz languages are added on the server; the interface exists only
    /// in en/sk/cs. A quiz in a language without a translation reads English,
    /// the source, instead of a half-resolved mix.
    @Test("a quiz language the app is not translated into gets the English interface")
    func untranslatedQuizLanguageGetsEnglish() {
        let app = ["en", "sk", "cs"]
        #expect(InterfaceLanguage.code(forQuiz: "sk", localizations: app) == "sk")
        #expect(InterfaceLanguage.code(forQuiz: "cs", localizations: app) == "cs")
        #expect(InterfaceLanguage.code(forQuiz: "de", localizations: app) == "en")
    }

    /// WHY: only the language changes; dates and numbers keep the phone's
    /// region, as they did before.
    @Test("the interface locale keeps the phone's region")
    func localeKeepsTheRegion() {
        defer { InterfaceLanguage.set(nil) }
        InterfaceLanguage.set("sk")
        #expect(InterfaceLanguage.locale.language.languageCode?.identifier == "sk")
        #expect(InterfaceLanguage.locale.region == Locale.current.region)
    }

    /// WHY: with the interface tied to the quiz, a fresh install whose quiz
    /// defaulted to English would open a Slovak phone's app in English —
    /// worse than before. A first launch takes the phone's language when
    /// the quiz offers it.
    @Test("a first launch starts the quiz, and the app, in the phone's language")
    func firstLaunchUsesThePhoneLanguage() throws {
        let suite = "InterfaceLanguageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(PersistenceStore(userDefaults: defaults, phoneLanguage: "sk").loadSettings().language == "sk")
        #expect(PersistenceStore(userDefaults: defaults, phoneLanguage: "de").loadSettings().language == "en")
        #expect(PersistenceStore(userDefaults: defaults, phoneLanguage: nil).loadSettings().language == "en")
    }

    /// WHY: the test host app launches with the simulator's saved quiz. If it
    /// switched the process, every other test's English text would depend on
    /// what was last played on that simulator.
    @Test("a unit-test process never follows its host app's quiz language")
    func processDoesNotFollow() {
        defer { InterfaceLanguage.set(nil) }
        InterfaceLanguage.follow(quizLanguage: "sk")
        #expect(InterfaceLanguage.bundle == .main)
    }
}
