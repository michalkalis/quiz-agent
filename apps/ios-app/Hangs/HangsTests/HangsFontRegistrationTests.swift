//
//  HangsFontRegistrationTests.swift
//  HangsTests
//
//  #194: content type is Rethink Sans. A cut missing from `UIAppFonts` makes
//  `Font.custom` fall back to the system font silently — the question text
//  would quietly lose its typeface — so every bundled cut must resolve.
//

@testable import Hangs
import SwiftUI
import Testing
import UIKit

@MainActor
struct HangsFontRegistrationTests {
    @Test("every Rethink Sans cut the theme names is registered", arguments: Theme.Hangs.Fonts.RethinkSans.all)
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
}
