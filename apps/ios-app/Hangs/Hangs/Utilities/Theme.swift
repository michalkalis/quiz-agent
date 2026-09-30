//
//  Theme.swift
//  Hangs
//
//  The app's one set of design tokens (#188 — unified design system).
//  Code is the source of truth: the design catalog and Pencil variables are
//  generated from this file, never the other way round.
//
//  Two layers:
//  - `Palette` — raw base values (hex). File-private: views never pick a raw hue.
//  - `Colors`, `Shadow`, `Spacing`, `Radius`, `Fonts` — semantic tokens views use.
//
//  `Theme.Hangs` is the internal namespace (the product is Trubbo, see CONTEXT.md).
//

import SwiftUI

enum Theme {
    enum Hangs {}
}

// MARK: - Palette (base values)

/// Base values only — reference them from the semantic tokens below, never from a view.
private enum Palette {
    // Brand
    static let pink500 = "#FF3D8F"
    static let pink600 = "#D91E72"
    static let pink700 = "#C2185B"
    static let violet500 = "#8B5CF6"
    static let blue500 = "#0A84FF"
    static let blue700 = "#0A5DC2"
    static let teal500 = "#14B8A6"

    // Feedback
    static let green400 = "#4ADE80"
    static let green500 = "#22C55E"
    static let green600 = "#16A34A"
    static let red500 = "#FF4444"
    static let amber500 = "#F59E0B"

    // Neutrals — light surfaces
    static let white = "#FFFFFF"
    static let cloud = "#F6F7F9"
    static let snow = "#F4F4F4"
    static let gray400 = "#9CA3AF"
    static let gray500 = "#6B7280"

    // Neutrals — dark surfaces
    static let navy900 = "#0E1A2B"
    static let night900 = "#161616"
    static let night850 = "#1C1D22"
    static let night800 = "#1F1F22"
}

// MARK: - Semantic tokens

extension Theme.Hangs {
    enum Colors {
        // Surfaces (light / dark). See issue #45 task 45.1.
        static let bg = Color(light: Palette.cloud, dark: Palette.night900) // page bg
        static let bgCard = Color(light: Palette.white, dark: Palette.night800) // white card
        // #174 A1: modal sheet surface. MUST stay distinct from `bg` — a sheet
        // painted in the page colour reads as part of the screen, which is the
        // founder's 2026-09-08 report. Lighter than `bg` in dark mode (HIG:
        // a sheet is an elevated plane), lighter than the page in light mode.
        static let bgSheet = Color(light: Palette.white, dark: Palette.night850) // sheet surface

        // Text
        static let ink = Color(light: Palette.navy900, dark: Palette.snow) // primary text
        static let muted = Color(light: Palette.gray500, dark: Palette.gray400) // subtext
        static let mutedFaint = Color(light: Palette.gray400, dark: Palette.gray500) // struck-through answer text
        static let textOnAccent = Color.white

        // Accents
        static let pink = Color(hex: Palette.pink500) // brand accent / primary CTA (both modes)
        static let pinkDeep = Color(hex: Palette.pink600) // CTA countdown base — elapsed time behind the bright remaining fill (#108B, both modes)
        static let accentPrimary = Color(hex: Palette.violet500) // purple accent — MCQ badge/selected (both modes)
        static let accentPrimarySoft = Color(hex: Palette.violet500).opacity(0.125) // accent-primary-soft (#8B5CF6 @ 0x20)
        static let blue = Color(hex: Palette.blue500) // accent-blue (secondary accent)
        static let accentTeal = Color(hex: Palette.teal500) // accent-teal
        // #82 item 6: small chip text on the soft accent-tinted capsules
        // fails WCAG AA in light mode with the raw accents (pink 2.68:1,
        // blue 2.96:1) — these darker light-mode variants measure 4.73:1 /
        // 5.07:1 on the tinted background. Dark mode keeps the brand hues.
        static let pinkText = Color(light: Palette.pink700, dark: Palette.pink500)
        static let blueText = Color(light: Palette.blue700, dark: Palette.blue500)

        // Feedback
        static let greenCheck = Color(hex: Palette.green500) // accent-green
        static let greenCorrect = Color(hex: Palette.green600)
        static let successText = Color(light: Palette.green600, dark: Palette.green400) // success-text adapts per mode
        static let error = Color(hex: Palette.red500) // design `error` token (distinct from brand pink)
        static let warning = Color(hex: Palette.amber500)

        // Border tokens — alpha differs by mode, so build per-mode Colors
        // (UIColor(hex:) treats 8-digit hex as ARGB, so don't suffix alpha).
        static let hairline = Color( // border-subtle
            light: Color(hex: Palette.navy900).opacity(0.078),
            dark: Color(hex: Palette.white).opacity(0.078)
        )
        static let subtleBorder = Color( // border-standard
            light: Color(hex: Palette.navy900).opacity(0.122),
            dark: Color(hex: Palette.white).opacity(0.141)
        )
        static let mutedBorder = ink.opacity(0.10) // derived, auto-adapts

        // Soft washes — translucent fills that read in both appearances.
        static let pinkSoft = Color(hex: Palette.pink500).opacity(0.12)
        static let greenSoft = Color(hex: Palette.green500).opacity(0.12)
        static let errorSoft = error.opacity(0.15)
        /// neutral-soft — the "no verdict either way" wash (skipped result
        /// band, neutral chips). Derived from ink so it adapts per mode
        /// (#131 Track F token sheet).
        static let neutralSoft = ink.opacity(0.055)
    }

    enum Shadow {
        static let card = ShadowSpec(color: Color(hex: Palette.navy900).opacity(0.08), radius: 20, y: 4)
        static let navChip = ShadowSpec(color: Color(hex: Palette.navy900).opacity(0.06), radius: 8, y: 2)
        static let cta = ShadowSpec(color: Color(hex: Palette.pink500).opacity(0.20), radius: 16, y: 6)
        static let ctaStrong = ShadowSpec(color: Color(hex: Palette.pink500).opacity(0.25), radius: 16, y: 6)
        static let mic = ShadowSpec(color: Color(hex: Palette.pink500).opacity(0.30), radius: 24, y: 8)
        static let micStrong = ShadowSpec(color: Color(hex: Palette.pink500).opacity(0.40), radius: 24, y: 10)
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

// MARK: - Fonts

extension Theme.Hangs {
    /// Design-token font roles — map to bundled custom typefaces (task 52.2).
    /// display = Anton · body = Inter · mono = IBM Plex Mono (all OFL, confirmed 2026-06-11).
    enum Fonts {
        // Display role — Anton (single weight, decorative caps)
        static func display(_ size: CGFloat) -> Font {
            .custom("Anton-Regular", size: size)
        }

        // Body role — Inter (4 weights bundled: 400/500/600/700)
        static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            switch weight {
            case .medium: return .custom("Inter-Medium", size: size)
            case .semibold: return .custom("Inter-SemiBold", size: size)
            case .bold: return .custom("Inter-Bold", size: size)
            default: return .custom("Inter-Regular", size: size)
            }
        }

        // Mono role — IBM Plex Mono (2 weights bundled: 400/500)
        static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            switch weight {
            case .medium: return .custom("IBMPlexMono-Medium", size: size)
            default: return .custom("IBMPlexMono-Regular", size: size)
            }
        }
    }
}

extension Font {
    /// Display (Anton) — large hero text, screen titles, score numbers.
    static func hangsDisplay(_ size: CGFloat, weight _: Font.Weight = .black) -> Font {
        // Fallback to compressed-system for any callers that need a weight variant;
        // Anton is single-weight so the weight param is accepted but unused for the custom path.
        Theme.Hangs.Fonts.display(size)
    }

    /// Monospace label (IBM Plex Mono) — "streak", "GEOGRAPHY", "03 / 10".
    static func hangsMono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        Theme.Hangs.Fonts.mono(size, weight: weight)
    }

    /// Body / button copy (Inter) — "Start Quiz", settings rows, descriptions.
    static func hangsBody(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Theme.Hangs.Fonts.body(size, weight: weight)
    }

    // Convenience presets that match common Pencil sizes.
    static var hangsBlock: Font { .hangsDisplay(80) }
    static var hangsDisplayLG: Font { .hangsDisplay(72) }
    static var hangsDisplayMD: Font { .hangsDisplay(62) }
    static var hangsDisplaySM: Font { .hangsDisplay(40) }
    static var hangsQuestion: Font { .hangsDisplay(26) }
    static var hangsNumber: Font { .hangsDisplay(44) }
    static var hangsNumberLG: Font { .hangsDisplay(80) }
    static var hangsSubHero: Font { .hangsDisplay(22) }
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
