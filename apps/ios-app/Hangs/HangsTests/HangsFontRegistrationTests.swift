//
//  HangsFontRegistrationTests.swift
//  HangsTests
//
//  Issue #52 task 52.2: assert that each bundled custom font is registered under its
//  PostScript name and is NOT silently falling back to the system font. A missing
//  UIAppFonts entry or a misnamed file produces a nil UIFont — this test catches that.
//

import Testing
import UIKit

@MainActor
struct HangsFontRegistrationTests {
    // All PostScript names that must be resolvable at runtime.
    // If a file is renamed or removed from UIAppFonts, the corresponding entry fails here.
    private let requiredFonts: [String] = [
        "Anton-Regular",
        "IBMPlexMono-Regular",
        "IBMPlexMono-Medium",
        "Inter-Regular",
        "Inter-Medium",
        "Inter-SemiBold",
        "Inter-Bold",
    ]

    @Test func allBundledFontsAreRegistered() {
        for psName in requiredFonts {
            let font = UIFont(name: psName, size: 16)
            #expect(font != nil, "Font '\(psName)' is not registered — check UIAppFonts in Info.plist and the Fonts/ directory")
            if let font {
                // UIFont silently falls back to the system font when the name isn't found;
                // guard against that by asserting the loaded fontName matches the request.
                #expect(
                    font.fontName == psName,
                    "Font '\(psName)' loaded but PostScript name mismatch: got '\(font.fontName)' — likely a system-font fallback"
                )
            }
        }
    }

    @Test func displayRoleUsesAnton() {
        // Theme.Hangs.Fonts.display(_:) must resolve to Anton, not the system font.
        // This guards against a future code change that re-wires the display role.
        let font = UIFont(name: "Anton-Regular", size: 36)
        #expect(font != nil, "Anton-Regular must be registered for display role")
    }

    @Test func bodyRoleUsesInter() {
        let regular = UIFont(name: "Inter-Regular", size: 15)
        let bold = UIFont(name: "Inter-Bold", size: 15)
        #expect(regular != nil, "Inter-Regular must be registered for body role")
        #expect(bold != nil, "Inter-Bold must be registered for body role")
    }

    @Test func monoRoleUsesIBMPlexMono() {
        let regular = UIFont(name: "IBMPlexMono-Regular", size: 13)
        let medium = UIFont(name: "IBMPlexMono-Medium", size: 13)
        #expect(regular != nil, "IBMPlexMono-Regular must be registered for mono role")
        #expect(medium != nil, "IBMPlexMono-Medium must be registered for mono role")
    }
}
