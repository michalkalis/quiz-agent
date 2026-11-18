//
//  HangsFontRegistrationTests.swift
//  HangsTests
//
//  #194: content type is Rethink Sans. A cut missing from `UIAppFonts` makes
//  `Font.custom` fall back to the system font silently — the question text
//  would quietly lose its typeface — so every bundled cut must resolve.
//

import CoreText
@testable import Hangs
import SwiftUI
import Testing
import UIKit

@MainActor
struct HangsFontRegistrationTests {
    @Test(
        "every Rethink Sans and Manrope cut the theme names is registered",
        arguments: Theme.Hangs.Fonts.RethinkSans.all + Theme.Hangs.Fonts.Manrope.all
    )
    func bundledCutIsRegistered(_ name: String) {
        let font = UIFont(name: name, size: 17)
        #expect(font?.fontName == name, "\(name) is not registered — check UIAppFonts in Info.plist and Hangs/Fonts")
    }

    @Test("weights map to the nearest bundled cut")
    func weightMapping() {
        #expect(Theme.Hangs.Fonts.RethinkSans.name(for: .bold) == "RethinkSans-Bold")
        #expect(Theme.Hangs.Fonts.RethinkSans.name(for: .heavy) == "RethinkSans-ExtraBold")
        #expect(Theme.Hangs.Fonts.RethinkSans.name(for: .regular) == "RethinkSans-SemiBold")
    }

    /// WHY (#231, founder 2026-11-17): Rethink Sans has no Cyrillic, so a
    /// Ukrainian screen in it would set the letters in a system fallback and
    /// the digits in Rethink. Ukrainian takes Manrope; sk/cs/en must keep
    /// Rethink Sans exactly (their pixel baselines must not move).
    @Test("Ukrainian content is set in Manrope, every other language in Rethink Sans")
    func contentFaceFollowsLanguage() {
        #expect(Theme.Hangs.Fonts.contentFaceName(for: .bold, language: "uk") == "Manrope-Bold")
        #expect(Theme.Hangs.Fonts.contentFaceName(for: .heavy, language: "uk") == "Manrope-ExtraBold")
        #expect(Theme.Hangs.Fonts.contentFaceName(for: .semibold, language: "uk") == "Manrope-SemiBold")
        for language in ["en", "sk", "cs"] {
            #expect(Theme.Hangs.Fonts.contentFaceName(for: .bold, language: language) == "RethinkSans-Bold")
        }
    }

    /// WHY: Manrope must actually draw Ukrainian. A cut without a letter falls
    /// back to the system font for that glyph alone.
    @Test("every Manrope cut draws the Ukrainian alphabet", arguments: Theme.Hangs.Fonts.Manrope.all)
    func manropeCoversUkrainian(_ name: String) throws {
        let font = try #require(UIFont(name: name, size: 17))
        let alphabet = "АБВГҐДЕЄЖЗИІЇЙКЛМНОПРСТУФХЦЧШЩЬЮЯабвгґдеєжзиіїйклмнопрстуфхцчшщьюя'«»"
        let characters = Array(alphabet.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        #expect(CTFontGetGlyphsForCharacters(font as CTFont, characters, &glyphs, characters.count))
    }
}
