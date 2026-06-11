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
            // Adaptive surface + text tokens (light / dark). See issue #45 task 45.1
            // and the "Token values to mirror" table. Decorative translucent fills
            // below stay hardcoded — they read in both appearances.
            static let bg = Color(light: "#F6F7F9", dark: "#161616") // page bg
            static let bgCard = Color(light: "#FFFFFF", dark: "#1F1F22") // white card
            static let bgElevated = Color(light: "#FFFFFF", dark: "#2A2A2A") // bg-elevated

            static let ink = Color(light: "#0E1A2B", dark: "#F4F4F4") // primary text
            static let pink = Color(hex: "#FF3D8F") // brand accent / primary CTA (both modes)
            static let accentPrimary = Color(hex: "#8B5CF6") // purple accent — MCQ badge/selected (both modes)
            static let accentPrimarySoft = Color(hex: "#8B5CF6").opacity(0.125) // accent-primary-soft (#8B5CF6 @ 0x20)
            static let blue = Color(hex: "#0A84FF") // accent-blue (secondary accent)
            static let accentTeal = Color(hex: "#14B8A6") // accent-teal
            static let muted = Color(light: "#6B7280", dark: "#9CA3AF") // subtext
            static let mutedFaint = Color(light: "#9CA3AF", dark: "#6B7280") // struck-through answer text
            static let greenCheck = Color(hex: "#22C55E") // accent-green
            static let greenCorrect = Color(hex: "#16A34A")
            static let successText = Color(light: "#16A34A", dark: "#4ADE80") // success-text adapts per mode

            // Border tokens — alpha differs by mode, so build per-mode Colors
            // (UIColor(hex:) treats 8-digit hex as ARGB, so don't suffix alpha).
            static let hairline = Color( // border-subtle
                light: Color(hex: "#0E1A2B").opacity(0.078),
                dark: Color(hex: "#FFFFFF").opacity(0.078)
            )
            static let subtleBorder = Color( // border-standard
                light: Color(hex: "#0E1A2B").opacity(0.122),
                dark: Color(hex: "#FFFFFF").opacity(0.141)
            )
            static let mutedBorder = ink.opacity(0.10) // derived, auto-adapts

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
            static let error = Color(hex: "#FF4444") // design `error` token (distinct from brand pink)
            static let errorDim = error.opacity(0.15)
            static let warning = Color(hex: "#F59E0B")
            static let textPrimary = ink
            static let textSecondary = muted
            static let textTertiary = mutedFaint
            static let textOnAccent = Color.white
            static let textOnAccentMuted = Color.white.opacity(0.70) // text-on-accent-muted (#FFFFFFB3)
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

    /// Body / button copy ("Start Quiz").
    static func hangsBody(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    // Convenience presets that match common Pencil sizes.
    static var hangsBlock: Font { .hangsDisplay(80) } // "HANGS" hero
    static var hangsDisplayLG: Font { .hangsDisplay(72) } // "OOPS", "NAILED IT"
    static var hangsDisplayMD: Font { .hangsDisplay(62) } // "COMPLETE", "SETTINGS"
    static var hangsDisplaySM: Font { .hangsDisplay(40) } // big question text
    static var hangsQuestion: Font { .hangsDisplay(26) } // compact question
    static var hangsNumber: Font { .hangsDisplay(44) } // stat numbers
    static var hangsNumberLG: Font { .hangsDisplay(80) } // final score
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
