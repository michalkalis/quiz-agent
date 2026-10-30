//
//  InterfaceLanguage.swift
//  Hangs
//
//  Founder (car test 2026-10-30, TestFlight build 81): the whole app speaks
//  the quiz language. A quiz switched to Slovak left the buttons, labels and
//  settings in English, because the interface followed the phone (#130 had
//  split the two on purpose). Now there is one language and one place to
//  change it — the quiz-language picker — and the switch is live.
//
//  SwiftUI `Text` follows the `\.locale` the app root sets from here. Text
//  built in code (`String(localized:)` in view models, services, CarPlay)
//  cannot follow a locale, so every such call reads the catalog through
//  `Bundle.interface` (the `.lproj` of the interface language) and formats
//  with `Locale.interface` (its plural rules and numbers).
//
//  System-owned text (permission prompts, share sheet) stays in the phone
//  language; iOS gives an app no live control over it.
//

import Foundation
import Synchronization

nonisolated enum InterfaceLanguage {
    private struct Current {
        /// nil = the phone's language (until the app applies the quiz language).
        let code: String?
        let bundle: Bundle
    }

    private static let current = Mutex(Current(code: nil, bundle: .main))

    /// Where `String(localized:)` looks the interface text up.
    static var bundle: Bundle {
        current.withLock { $0.bundle }
    }

    /// The interface language code (e.g. "sk").
    static var code: String {
        current.withLock { $0.code } ?? Bundle.main.preferredLocalizations.first ?? "en"
    }

    /// The phone's locale (region, calendar) speaking the interface language.
    /// Also what picks a plural form: "3 otázky", not English's "3 otázok".
    static var locale: Locale {
        var components = Locale.Components(locale: .current)
        components.languageComponents = Locale.Language.Components(
            languageCode: Locale.LanguageCode(code), script: nil, region: Locale.current.region
        )
        return Locale(components: components)
    }

    /// The interface language for a quiz in `quizLanguage`: the same one when
    /// the app is translated into it, English otherwise (the source language).
    static func code(forQuiz quizLanguage: String, localizations: [String] = Bundle.main.localizations) -> String {
        localizations.contains(quizLanguage) ? quizLanguage : "en"
    }

    /// The app's quiz language changed (or was loaded at launch). A unit-test
    /// process never follows its host app's saved quiz: every test's text
    /// would then depend on what the simulator last played.
    static func follow(quizLanguage: String) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        apply(quizLanguage: quizLanguage)
    }

    /// `follow` without the test-process guard.
    static func apply(quizLanguage: String) {
        set(code(forQuiz: quizLanguage))
    }

    /// Switch the interface to `code`; nil returns to the phone's language.
    static func set(_ code: String?) {
        let bundle = code
            .flatMap { Bundle.main.path(forResource: $0, ofType: "lproj") }
            .flatMap(Bundle.init(path:)) ?? .main
        current.withLock { $0 = Current(code: code, bundle: bundle) }
    }
}

extension Locale {
    /// The interface language's locale (`InterfaceLanguage`).
    nonisolated static var interface: Locale {
        InterfaceLanguage.locale
    }
}

extension Bundle {
    /// The catalog in the interface language (`InterfaceLanguage`).
    nonisolated static var interface: Bundle {
        InterfaceLanguage.bundle
    }
}
