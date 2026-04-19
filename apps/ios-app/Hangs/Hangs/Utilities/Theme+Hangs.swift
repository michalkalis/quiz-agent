//
//  Theme+Hangs.swift
//  Hangs
//
//  Design tokens for the Hangs redesign (cream editorial, condensed display).
//  Source of truth: docs/design/hangs-redesign-spec.md (Pencil export).
//

import SwiftUI

extension Theme {

    enum Hangs {

        enum Colors {
            static let bg = Color(hex: "#F5F1E8")           // cream
            static let bgCard = Color.white
            static let bgElevated = Color.white

            static let ink = Color(hex: "#0E1A2B")          // near-black primary text
            static let pink = Color(hex: "#FF3D8F")         // brand accent / primary CTA
            static let blue = Color(hex: "#0A84FF")         // secondary accent
            static let muted = Color(hex: "#6B7280")        // subtext
            static let mutedFaint = Color(hex: "#9CA3AF")   // struck-through answer text
            static let greenCheck = Color(hex: "#22C55E")
            static let greenCorrect = Color(hex: "#16A34A")

            static let hairline = Color(hex: "#0E1A2B").opacity(0.08)
            static let subtleBorder = Color(hex: "#0E1A2B").opacity(0.12)
            static let mutedBorder = Color(hex: "#0E1A2B").opacity(0.10)

            static let pinkSoft = Color(hex: "#FF3D8F").opacity(0.12)
            static let pinkHalo1 = Color(hex: "#FF3D8F").opacity(0.08)
            static let pinkHalo2 = Color(hex: "#FF3D8F").opacity(0.20)
            static let pinkHaloStrong = Color(hex: "#FF3D8F").opacity(0.15)
            static let greenSoft = Color(hex: "#22C55E").opacity(0.12)

            // Legacy aliases kept for compatibility with not-yet-migrated files.
            static let accent = pink
            static let accentDim = pink.opacity(0.4)
            static let infoAccent = blue
            static let success = greenCorrect
            static let successDim = greenCorrect.opacity(0.15)
            static let error = pink
            static let errorDim = pink.opacity(0.15)
            static let warning = Color(hex: "#F59E0B")
            static let textPrimary = ink
            static let textSecondary = muted
            static let textTertiary = mutedFaint
            static let textOnAccent = Color.white
            static let divider = hairline
            static let borderDim = subtleBorder
        }

        enum Shadow {
            static let card = ShadowSpec(color: Color(hex: "#0E1A2B").opacity(0.08), radius: 20, y: 4)
            static let navChip = ShadowSpec(color: Color(hex: "#0E1A2B").opacity(0.06), radius: 8, y: 2)
            static let cta = ShadowSpec(color: Color(hex: "#FF3D8F").opacity(0.20), radius: 16, y: 6)
            static let ctaStrong = ShadowSpec(color: Color(hex: "#FF3D8F").opacity(0.25), radius: 16, y: 6)
            static let mic = ShadowSpec(color: Color(hex: "#FF3D8F").opacity(0.30), radius: 24, y: 8)
            static let micStrong = ShadowSpec(color: Color(hex: "#FF3D8F").opacity(0.40), radius: 24, y: 10)
        }

        struct ShadowSpec {
            let color: Color
            let radius: CGFloat
            let y: CGFloat
        }

        enum Spacing {
            static let xxs: CGFloat = 4
            static let xs: CGFloat = 8
            static let sm: CGFloat = 12
            static let md: CGFloat = 16
            static let lg: CGFloat = 20
            static let xl: CGFloat = 24
            static let xxl: CGFloat = 32
        }

        enum Radius {
            static let card: CGFloat = 18
            static let cardInner: CGFloat = 16
            static let cta: CGFloat = 32
            static let ctaSmall: CGFloat = 28
            static let chip: CGFloat = 14
            static let navSquare: CGFloat = 10
            static let navRound: CGFloat = 18
        }
    }
}

// MARK: - Fonts

extension Font {

    /// Condensed heavy display (approximates Anton). "HANGS", "NAILED IT", question text.
    static func hangsDisplay(_ size: CGFloat, weight: Font.Weight = .black) -> Font {
        .system(size: size, weight: weight).width(.compressed)
    }

    /// Monospace small-caps label ("streak", "GEOGRAPHY", "03 / 10").
    static func hangsMono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Body / button copy ("Start Quiz", "Answer out loud…").
    static func hangsBody(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    // Convenience presets that match common Pencil sizes.
    static var hangsBlock: Font { .hangsDisplay(80) }           // "HANGS" hero
    static var hangsDisplayLG: Font { .hangsDisplay(72) }       // "OOPS", "NAILED IT"
    static var hangsDisplayMD: Font { .hangsDisplay(62) }       // "COMPLETE", "SETTINGS"
    static var hangsDisplaySM: Font { .hangsDisplay(40) }       // big question text
    static var hangsQuestion: Font { .hangsDisplay(26) }        // compact question
    static var hangsNumber: Font { .hangsDisplay(44) }          // stat numbers
    static var hangsNumberLG: Font { .hangsDisplay(80) }        // final score
    static var hangsSubHero: Font { .hangsDisplay(22, weight: .black) }
    static var hangsMonoLabel: Font { .hangsMono(11, weight: .medium) }
    static var hangsMonoMini: Font { .hangsMono(10, weight: .medium) }
    static var hangsMonoValue: Font { .hangsMono(14, weight: .medium) }
    static var hangsBrand: Font { .hangsMono(17, weight: .semibold) }
    static var hangsButton: Font { .hangsBody(17, weight: .bold) }
    static var hangsBody: Font { .hangsBody(14) }
}

// MARK: - View helpers

extension View {
    /// Apply a HangsShadow spec as a SwiftUI shadow.
    func hangsShadow(_ spec: Theme.Hangs.ShadowSpec) -> some View {
        shadow(color: spec.color, radius: spec.radius, x: 0, y: spec.y)
    }
}
