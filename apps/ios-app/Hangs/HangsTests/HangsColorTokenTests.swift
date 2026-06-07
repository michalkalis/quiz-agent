//
//  HangsColorTokenTests.swift
//  HangsTests
//
//  Issue #45 task 45.1: assert the adaptive `Theme.Hangs.Colors` tokens resolve
//  to the expected light / dark RGB values. These tests encode WHY the tokens
//  matter — a hands-free driving app must read in both appearances, so a token
//  that silently stays light-only (the old cream bg) is a real regression.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import UIKit

@MainActor
struct HangsColorTokenTests {
    /// Resolve a SwiftUI Color's RGB for a given interface style.
    private func rgb(_ color: Color, _ style: UIUserInterfaceStyle) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b)
    }

    /// Expected RGB from a 6-digit hex.
    private func hexRGB(_ hex: String) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        return (CGFloat(int >> 16) / 255, CGFloat(int >> 8 & 0xFF) / 255, CGFloat(int & 0xFF) / 255)
    }

    private func assertToken(
        _ color: Color, light: String, dark: String,
        _ name: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let tol: CGFloat = 1.0 / 255.0 + 0.0001
        let gotLight = rgb(color, .light), wantLight = hexRGB(light)
        #expect(abs(gotLight.r - wantLight.r) <= tol, "\(name) light R", sourceLocation: sourceLocation)
        #expect(abs(gotLight.g - wantLight.g) <= tol, "\(name) light G", sourceLocation: sourceLocation)
        #expect(abs(gotLight.b - wantLight.b) <= tol, "\(name) light B", sourceLocation: sourceLocation)
        let gotDark = rgb(color, .dark), wantDark = hexRGB(dark)
        #expect(abs(gotDark.r - wantDark.r) <= tol, "\(name) dark R", sourceLocation: sourceLocation)
        #expect(abs(gotDark.g - wantDark.g) <= tol, "\(name) dark G", sourceLocation: sourceLocation)
        #expect(abs(gotDark.b - wantDark.b) <= tol, "\(name) dark B", sourceLocation: sourceLocation)
    }

    @Test func surfaceTokensAdapt() {
        assertToken(Theme.Hangs.Colors.bg, light: "#F6F7F9", dark: "#161616", "bg")
        assertToken(Theme.Hangs.Colors.bgCard, light: "#FFFFFF", dark: "#1F1F22", "bgCard")
        assertToken(Theme.Hangs.Colors.bgElevated, light: "#FFFFFF", dark: "#1F1F22", "bgElevated")
    }

    @Test func textTokensAdapt() {
        assertToken(Theme.Hangs.Colors.ink, light: "#0E1A2B", dark: "#F4F4F4", "ink")
        assertToken(Theme.Hangs.Colors.muted, light: "#6B7280", dark: "#9CA3AF", "muted")
        assertToken(Theme.Hangs.Colors.mutedFaint, light: "#9CA3AF", dark: "#6B7280", "mutedFaint")
    }

    @Test func borderTokensAdapt() {
        // RGB base flips ink→white between modes (alpha differs but is not asserted here).
        assertToken(Theme.Hangs.Colors.hairline, light: "#0E1A2B", dark: "#FFFFFF", "hairline")
        assertToken(Theme.Hangs.Colors.subtleBorder, light: "#0E1A2B", dark: "#FFFFFF", "subtleBorder")
    }

    @Test func brandTokensAreModeInvariant() {
        // pink / greenCheck are intentionally the same in both modes — guards against
        // someone "helpfully" making them adaptive and breaking brand consistency.
        assertToken(Theme.Hangs.Colors.pink, light: "#FF3D8F", dark: "#FF3D8F", "pink")
        assertToken(Theme.Hangs.Colors.greenCheck, light: "#22C55E", dark: "#22C55E", "greenCheck")
    }
}
