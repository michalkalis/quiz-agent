//
//  Color+Theme.swift
//  Hangs
//
//  Color extensions for hex string initialization and adaptive colors
//

import SwiftUI
import UIKit

extension Color {

    /// Initialize a Color from a hex string (supports #RRGGBB and #RRGGBBAA formats)
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)

        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }

    /// Initialize an adaptive color with different values for light and dark mode
    /// - Parameters:
    ///   - light: Hex string for light mode color
    ///   - dark: Hex string for dark mode color
    init(light: String, dark: String) {
        // Resolve hex → UIColor eagerly so the dynamicProvider closure stays free
        // of SwiftUI bridges; iOS 26 runs that closure off-main during renderAsync.
        let lightUI = UIColor(hex: light)
        let darkUI = UIColor(hex: dark)
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? darkUI : lightUI
        })
    }

    /// Initialize an adaptive color with different Color values for light and dark mode
    /// - Parameters:
    ///   - light: Color for light mode
    ///   - dark: Color for dark mode
    init(light: Color, dark: Color) {
        let lightUI = UIColor(light)
        let darkUI = UIColor(dark)
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? darkUI : lightUI
        })
    }
}

extension UIColor {

    /// Initialize a UIColor from a hex string (supports #RGB, #RRGGBB, #RRGGBBAA).
    /// Pure-UIKit path — safe to call from a `UIColor(dynamicProvider:)` closure,
    /// which iOS 26 may invoke off the main thread during SwiftUI's async render.
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)

        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }

        self.init(
            red: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: CGFloat(a) / 255
        )
    }
}
