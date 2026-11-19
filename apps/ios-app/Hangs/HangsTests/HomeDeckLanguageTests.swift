//
//  HomeDeckLanguageTests.swift
//  HangsTests
//
//  #240 walkthrough: after switching the quiz language from English to
//  Slovak or Czech, the category cards on Home kept their English names
//  until the app was relaunched, while the rest of Home had switched. The
//  cards took their names from text built once in the old language; they
//  now resolve them in the language the screen is drawn in.
//
//  The test process stays English for code-built text (see
//  `InterfaceLanguage.follow`), which is exactly the stale-name condition:
//  only a card that follows the screen's locale shows the Slovak name.
//

@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@Suite("#240 Home category cards follow the quiz language")
@MainActor
struct HomeDeckLanguageTests {
    private func names(in deck: some View, locale: Locale) async throws -> [String] {
        let view = deck.environment(\.locale, locale)
        var names: [String] = []
        try await ViewHosting.host(view) {
            names = try view.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }
        }
        return names
    }

    /// WHY: a Slovak player reading English category names on the cards
    /// cannot tell the app switched; the names must change with the language.
    @Test("the single-category cards show the names in the screen's language",
          arguments: [("sk", "Veda a príroda", "Všetky kategórie"), ("cs", "Věda a příroda", "Všechny kategorie")])
    func cycleCardsFollowLocale(language: String, science: String, all: String) async throws {
        let deck = HomeCategoryDeck(selectedCategories: [], title: "", questionCount: 10, onStep: { _, _ in })

        let names = try await names(in: deck, locale: Locale(identifier: language))

        #expect(names.contains(science), "\(language): \(names)")
        #expect(names.contains(all), "\(language): \(names)")
        #expect(!names.contains("Science & Nature"), "the English name stayed on a \(language) screen")
    }

    /// WHY: the fan of several picked categories names them on its back
    /// cards too; those must not stay English either.
    @Test("the multi-selection fan names its cards in the screen's language")
    func fanFollowsLocale() async throws {
        let deck = HomeCategoryDeck(selectedCategories: ["science-nature", "history"], title: "", questionCount: 10, onStep: { _, _ in })

        let names = try await names(in: deck, locale: Locale(identifier: "sk"))

        #expect(names.contains("Veda a príroda"), "\(names)")
        #expect(names.contains("História"), "\(names)")
    }
}
