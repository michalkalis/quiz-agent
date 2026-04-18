//
//  Theme+Hangs.swift
//  CarQuiz
//
//  Design tokens for the Hangs redesign (terminal/cyberpunk aesthetic, dark-only).
//  Additive to Theme.swift — legacy screens keep using Theme.Colors.*.
//

import SwiftUI

extension Theme {

    /// Hangs redesign tokens. Dark-only. Non-adaptive colors intentional.
    enum Hangs {

        enum Colors {
            static let bg = Color(hex: "#1A1A1A")
            static let bgCard = Color(hex: "#212121")
            static let bgElevated = Color(hex: "#252525")

            static let divider = Color(hex: "#333333")
            static let borderDim = Color(hex: "#2A2A2A")

            static let accent = Color(hex: "#FF4FB6")         // Pink primary
            static let accentDim = Color(hex: "#FF4FB6").opacity(0.4)
            static let infoAccent = Color(hex: "#0A84FF")     // iOS blue, used for outlines + recording chrome

            static let success = Color(hex: "#10B981")
            static let successDim = Color(hex: "#10B981").opacity(0.15)
            static let error = Color(hex: "#FF4444")
            static let errorDim = Color(hex: "#FF4444").opacity(0.15)
            static let warning = Color(hex: "#F59E0B")

            static let textPrimary = Color.white
            static let textSecondary = Color(hex: "#A1A1AA")
            static let textTertiary = Color(hex: "#6B7280")
            static let textOnAccent = Color.black     // Black text on pink block (not white — matches Pencil)
        }

        enum Spacing {
            static let xs: CGFloat = 8
            static let sm: CGFloat = 12
            static let md: CGFloat = 16
            static let lg: CGFloat = 20
            static let xl: CGFloat = 24
            static let xxl: CGFloat = 32
        }

        /// Hangs uses sharp, hard corners — redesign is blocky, not rounded.
        enum Radius {
            static let none: CGFloat = 0
            static let sm: CGFloat = 2
            static let md: CGFloat = 4
            static let lg: CGFloat = 6
        }
    }
}

extension Font {

    /// Huge block display (pink "HANGS" / "QUIZ MASTER!" hero blocks). Heavy weight, tight tracking.
    static var hangsBlock: Font {
        .system(size: 64, weight: .black, design: .default)
    }

    /// Large display (screen titles like "SETTINGS", "ANSWER").
    static var hangsDisplay: Font {
        .system(size: 44, weight: .heavy, design: .default)
    }

    /// Medium display (verdict "CORRECT!" / "INCORRECT!").
    static var hangsDisplayMD: Font {
        .system(size: 32, weight: .black, design: .default)
    }

    /// Big number display ("9.5", "47" in metric tiles).
    static var hangsNumber: Font {
        .system(size: 34, weight: .bold, design: .default)
    }

    /// Question text body — clean sans, serious weight.
    static var hangsQuestion: Font {
        .system(size: 22, weight: .bold, design: .default)
    }

    /// Monospace label ("// HANGS.SYS", "[ VERDICT ]", "// QUICK_CONFIG").
    static var hangsMonoLabel: Font {
        .system(size: 11, weight: .semibold, design: .monospaced)
    }

    /// Monospace mini-label (footer "REG.MARK.01 · PWR ON · V2.1").
    static var hangsMonoMini: Font {
        .system(size: 10, weight: .medium, design: .monospaced)
    }

    /// Monospace value ("1989", "8.5", "+1.0").
    static var hangsMonoValue: Font {
        .system(size: 14, weight: .semibold, design: .monospaced)
    }

    /// Button label — uppercase bold sans.
    static var hangsButton: Font {
        .system(size: 15, weight: .bold, design: .default)
    }

    /// Body copy (explanation text, tagline).
    static var hangsBody: Font {
        .system(size: 14, weight: .regular, design: .default)
    }
}
