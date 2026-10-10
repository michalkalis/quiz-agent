//
//  Theme.swift
//  Hangs
//
//  The app's one set of design tokens (#188 — unified design system;
//  #194 — "Sklo nad kartami" palette and system type).
//  Code is the source of truth: the design catalog and Pencil variables are
//  generated from this file, never the other way round.
//
//  Two layers:
//  - `Palette` — raw base values (hex). File-private: views never pick a raw hue.
//  - `Colors`, `Category`, `Shadow`, `Spacing`, `Radius`, `Fonts` — semantic tokens views use.
//
//  `Theme.Hangs` is the internal namespace (the product is Trubbo, see CONTEXT.md).
//

import SwiftUI

enum Theme {
    enum Hangs {}
}

// MARK: - Palette (base values)

/// Base values only — reference them from the semantic tokens below, never from a view.
/// #194 B1: the "Sklo nad kartami" palette (claude.ai canvas, page "Finálny smer
/// vs. beta"): a grey page, white cards, ink type, one green for "listening".
private enum Palette {
    // Neutrals — light
    static let page = "#E8EAEE"
    static let white = "#FFFFFF"
    static let ink = "#111216"
    static let slate = "#4C505C" // secondary text, 7.4:1 on the page
    static let slateFaint = "#8A8E99"

    // Neutrals — dark
    static let night = "#0F1014" // page
    static let nightCard = "#1C1D23"
    static let nightInset = "#2A2C35"
    static let paper = "#F2F3F5" // dark-mode ink
    static let fog = "#A3A7B2"
    static let fogFaint = "#6B6F7A"

    // Live (listening) — the one status hue
    static let liveDeep = "#0A6B4C"
    static let liveBright = "#5EEBC0"
    static let liveFill = "#16B386"

    // Categories (founder rounds 2–4); cobalt doubles as geography-world
    static let mandarin = "#FF6B2C"
    static let mandarinDark = "#F0662C"
    static let mint = "#3FE0AE"
    static let mintDark = "#2FC99B"
    static let rose = "#E8317F"
    static let roseDark = "#D42A72"
    static let yellow = "#FFD23F"
    static let yellowDark = "#EBBF35"
    static let violet = "#7A5CFF"
    static let violetDark = "#7052F5"
    static let lime = "#A3E635"
    static let limeDark = "#8FCB2C"

    // Links and the selected choice
    static let cobalt = "#2C45F5"
    static let cobaltDark = "#3A52FF"
    static let linkBlue = "#1A2FC4"
    static let linkBlueDark = "#8C9BFF"

    // Feedback
    static let red = "#D4243B"
    static let redDark = "#FF6B7D"
    static let amber = "#B45309"
    static let amberDark = "#F59E0B"
    static let wrongDark = "#5A5E6B"
}

// MARK: - Semantic tokens

extension Theme.Hangs {
    enum Colors {
        // MARK: Surfaces (light / dark)
        static let bg = Color(light: Palette.page, dark: Palette.night) // page bg
        static let bgCard = Color(light: Palette.white, dark: Palette.nightCard) // white card
        /// #174 A1: modal sheet surface. MUST stay distinct from `bg` — a sheet
        /// painted in the page colour reads as part of the screen, which is the
        /// founder's 2026-09-08 report. White on the grey page in light mode, the
        /// raised card grey in dark mode (HIG: a sheet is an elevated plane).
        static let bgSheet = Color(light: Palette.white, dark: Palette.nightCard) // sheet surface
        /// #194 B1: a well inside a card (MCQ option key, inner chips).
        static let bgInset = Color(light: Palette.page, dark: Palette.nightInset)

        // MARK: Text
        static let ink = Color(light: Palette.ink, dark: Palette.paper) // primary text
        static let muted = Color(light: Palette.slate, dark: Palette.fog) // subtext
        static let mutedFaint = Color(light: Palette.slateFaint, dark: Palette.fogFaint) // struck-through answer text
        /// White text on a saturated fill that stays saturated in both modes
        /// (green badge, cobalt selection, dark category cards).
        static let textOnAccent = Color.white

        // MARK: Action — #194 B1: the main action is ink, not pink. Founder
        // rule "accent only for the main action" holds; the accent is now ink
        // (light) / paper (dark), so its text flips with it.
        static let action = Color(light: Color(hex: Palette.ink).opacity(0.92), dark: Color(hex: Palette.paper))
        static let textOnAction = Color(light: Palette.white, dark: Palette.ink)
        /// Text in the action role on a page or card (links like "Upgrade").
        static let actionText = ink
        static let actionSoft = ink.opacity(0.06)

        // MARK: Selection and links
        /// The chosen option (paywall plan, selected MCQ answer) — cobalt with white text.
        static let accentPrimary = Color(light: Palette.cobalt, dark: Palette.cobaltDark)
        static let accentPrimarySoft = Color(light: Palette.cobalt, dark: Palette.cobaltDark).opacity(0.12)
        /// Secondary accent: links, row values, "paused". Dark link blue in light
        /// mode keeps 17pt text above WCAG AA on white and on the page.
        static let blue = Color(light: Palette.linkBlue, dark: Palette.linkBlueDark)
        static let blueText = blue

        // MARK: Live — listening, reading, thinking (#194 B1, was teal)
        /// Text and icons in the live state: 6.4:1 on the light page, 11:1 dark.
        static let live = Color(light: Palette.liveDeep, dark: Palette.liveBright)
        /// Dots, glows and progress fills in the live state (non-text).
        static let liveAccent = Color(hex: Palette.liveFill)
        static let liveSoft = Color(hex: Palette.liveFill).opacity(0.12)

        // MARK: Rows and groups (#188 G12). One colour per role on every
        // screen; the action colour stays reserved for the main action.
        /// Caps label above a group of rows (Settings, Home, sheets).
        static let sectionLabel = muted
        /// The current value of a row (language, difficulty, plan). #194 C8:
        /// secondary text, as in iOS Settings (canvas Bg-Settings) — blue read
        /// as a link on every row.
        static let rowValue = muted

        // MARK: Feedback
        static let greenCheck = Color(hex: Palette.liveFill) // correct fill (white glyph)
        static let greenCorrect = live // correct text/icon on a surface
        static let successText = live
        /// #194 B1: a wrong answer reads neutral (canvas: no red verdicts) —
        /// a dark fill that keeps a white glyph readable in both modes.
        static let wrong = Color(light: Palette.ink, dark: Palette.wrongDark)
        static let error = Color(light: Palette.red, dark: Palette.redDark) // failures, not wrong answers
        static let warning = Color(light: Palette.amber, dark: Palette.amberDark)

        // MARK: Borders. Hairline outlines replace drop shadows (#194 B1).
        static let hairline = Color( // border-subtle
            light: Color(hex: Palette.ink).opacity(0.06),
            dark: Color(hex: Palette.white).opacity(0.08)
        )
        static let subtleBorder = Color( // border-standard
            light: Color(hex: Palette.ink).opacity(0.10),
            dark: Color(hex: Palette.white).opacity(0.14)
        )
        static let mutedBorder = ink.opacity(0.10) // derived, auto-adapts
        /// Unfilled segment of a progress track.
        static let track = ink.opacity(0.14)

        // MARK: Soft washes, translucent fills that read in both appearances
        static let greenSoft = liveSoft
        static let errorSoft = error.opacity(0.15)
        /// neutral-soft — the "no verdict either way" wash (skipped result
        /// band, neutral chips). Derived from ink so it adapts per mode.
        static let neutralSoft = ink.opacity(0.055)
    }

    /// #194 B1: category colours (founder rounds 2–4). Each card carries its
    /// category's fill with the text colour measured for it; dark mode takes
    /// slightly deeper fills so white text keeps its contrast.
    enum Category {
        struct Style {
            let fill: Color
            let text: Color
        }

        private static let inkText = Color(hex: Palette.ink)

        /// The category chip and plates on a card: ink on white in both modes,
        /// readable on every category fill.
        static let chipFill = Color(hex: Palette.white)
        static let chipText = inkText

        static func style(for id: String?) -> Style {
            switch id {
            case "geography-world": return Style(fill: Color(light: Palette.cobalt, dark: Palette.cobaltDark), text: .white)
            case "history": return Style(fill: Color(light: Palette.mandarin, dark: Palette.mandarinDark), text: inkText)
            case "science-nature": return Style(fill: Color(light: Palette.mint, dark: Palette.mintDark), text: inkText)
            case "movies-music": return Style(fill: Color(light: Palette.rose, dark: Palette.roseDark), text: Color(light: Palette.ink, dark: Palette.white))
            case "sports": return Style(fill: Color(light: Palette.yellow, dark: Palette.yellowDark), text: inkText)
            case "food-everyday": return Style(fill: Color(light: Palette.violet, dark: Palette.violetDark), text: .white)
            case "entertainment": return Style(fill: Color(light: Palette.lime, dark: Palette.limeDark), text: inkText)
            default: return Style(fill: Color(light: Palette.ink, dark: Palette.nightInset), text: .white) // custom packs, mixed
            }
        }

        /// Ids in display order — the multi-colour "all categories" strip.
        static let taxonomy = ["geography-world", "history", "science-nature", "movies-music", "sports", "food-everyday", "entertainment"]
    }

    enum Shadow {
        /// Hairline-plus-lift: the canvas `--shadow-border`; cards are outlined, not floated.
        static let card = ShadowSpec(color: Color(hex: Palette.ink).opacity(0.06), radius: 2, y: 1)
        /// Canvas `--shadow-raised`: the one lifted element (main action, deck card).
        static let cta = ShadowSpec(color: Color(hex: Palette.ink).opacity(0.18), radius: 16, y: 8)
        static let raised = cta
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

    /// Concentric corners (#194 B1): a 16pt inset inside a 24pt card leaves 8 + 16.
    enum Radius {
        static let card: CGFloat = 24
        static let cardInner: CGFloat = 16
        /// Question and result cards.
        static let deck: CGFloat = 32
        static let cta: CGFloat = 28
        static let ctaSmall: CGFloat = 24
        static let chip: CGFloat = 14
        static let navRound: CGFloat = 22
    }
}

// MARK: - Fonts

extension Theme.Hangs {
    /// #194: two families. Controls (buttons, labels, captions, overlines,
    /// chips) are SF via iOS text styles, so every label follows Dynamic Type —
    /// `Font.system(size:)` would freeze it. Content (`display`, `content`) is
    /// Rethink Sans on the canvas scale 22 / 28 / 40 / 52.
    enum Fonts {
        /// #194 (founder 2026-10-09): content type — question text, answers,
        /// verdicts, scores — is Rethink Sans; controls stay SF (`body`, `mono`).
        /// Static instances of the OFL variable font (600/700/800), bundled in
        /// `Fonts/`. `relativeTo:` keeps every size on Dynamic Type, heroes
        /// included; they stay one line and scale down to fit.
        static func display(_ size: CGFloat) -> Font {
            switch size {
            case ..<25: return content(22, weight: .bold, relativeTo: .title2)
            case ..<32: return content(28, weight: .bold, relativeTo: .title)
            case ..<48: return content(40, weight: .bold, relativeTo: .largeTitle)
            default: return content(52, weight: .bold, relativeTo: .largeTitle)
            }
        }

        /// Rethink Sans at a body size (MCQ options, recap answers).
        static func content(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
            content(size, weight: weight, relativeTo: textStyle(for: size))
        }

        private static func content(_ size: CGFloat, weight: Font.Weight, relativeTo style: Font.TextStyle) -> Font {
            .custom(RethinkSans.name(for: weight), size: size, relativeTo: style)
        }

        /// PostScript names of the bundled cuts; any weight maps to the nearest.
        nonisolated enum RethinkSans {
            static let all = ["RethinkSans-SemiBold", "RethinkSans-Bold", "RethinkSans-ExtraBold"]

            static func name(for weight: Font.Weight) -> String {
                switch weight {
                case .heavy, .black: return "RethinkSans-ExtraBold"
                case .bold: return "RethinkSans-Bold"
                default: return "RethinkSans-SemiBold"
                }
            }
        }

        static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .system(textStyle(for: size), weight: weight)
        }

        /// Former mono labels: caps captions and counters. Semibold system with
        /// tabular digits so "03 / 10" does not jitter.
        static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .system(textStyle(for: size), weight: weight == .regular ? .regular : .semibold).monospacedDigit()
        }

        /// Nearest iOS text style by its default point size.
        static func textStyle(for size: CGFloat) -> Font.TextStyle {
            switch size {
            case ..<11.5: return .caption2 // 11
            case ..<12.5: return .caption // 12
            case ..<14: return .footnote // 13
            case ..<15.5: return .subheadline // 15
            case ..<16.5: return .callout // 16
            case ..<18.5: return .body // 17
            case ..<21: return .title3 // 20
            case ..<25: return .title2 // 22
            case ..<31: return .title // 28
            default: return .largeTitle // 34
            }
        }
    }
}

extension Font {
    /// Display — large hero text, screen titles, score numbers.
    static func hangsDisplay(_ size: CGFloat, weight _: Font.Weight = .black) -> Font {
        Theme.Hangs.Fonts.display(size)
    }

    /// Caps label / counter — "GEOGRAPHY", "03 / 10".
    static func hangsMono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        Theme.Hangs.Fonts.mono(size, weight: weight)
    }

    /// Body / button copy — "Start Quiz", settings rows, descriptions.
    static func hangsBody(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Theme.Hangs.Fonts.body(size, weight: weight)
    }

    // Presets.
    static var hangsBlock: Font { .hangsDisplay(80) }
    static var hangsDisplayLG: Font { .hangsDisplay(72) }
    static var hangsDisplayMD: Font { .hangsDisplay(62) }
    static var hangsDisplaySM: Font { .hangsDisplay(40) }
    static var hangsQuestion: Font { .hangsDisplay(26) }
    static var hangsNumber: Font { .hangsDisplay(44) }
    static var hangsNumberLG: Font { .hangsDisplay(80) }
    static var hangsSubHero: Font { .hangsDisplay(22) }
    static var hangsMonoLabel: Font { .hangsMono(13, weight: .semibold) }
    static var hangsMonoMini: Font { .hangsMono(11, weight: .semibold) }
    static var hangsMonoValue: Font { .hangsMono(15, weight: .medium) }
    static var hangsBrand: Font { .hangsBody(17, weight: .semibold) }
    static var hangsButton: Font { .hangsBody(17, weight: .semibold) }
    static var hangsBody: Font { .hangsBody(15) }
    // #194 B1 — canvas type scale (caption 13 · body 17 · heading 22 · title 28 · display 40).
    static var hangsOverline: Font { .hangsMono(13, weight: .semibold) }
    static var hangsTitle: Font { .hangsDisplay(28) }
    // #194 C — the rest of the canvas scale for the app screens.
    static var hangsCaption: Font { .hangsBody(13) }
    static var hangsBodyLG: Font { .hangsBody(17) }
    static var hangsLabel: Font { .hangsBody(17, weight: .semibold) }
    static var hangsHeading: Font { .hangsDisplay(22) }
    // #194 — content at body size (Rethink Sans) and the "trubbo" wordmark.
    static var hangsContent: Font { Theme.Hangs.Fonts.content(17) }
    /// Long answers in the one-column MCQ list.
    static var hangsContentCompact: Font { Theme.Hangs.Fonts.content(16) }
    static var hangsWordmark: Font { Theme.Hangs.Fonts.content(28, weight: .heavy) }
}

// MARK: - View helpers

extension View {
    /// Apply a HangsShadow spec as a SwiftUI shadow.
    func hangsShadow(_ spec: Theme.Hangs.ShadowSpec) -> some View {
        shadow(color: spec.color, radius: spec.radius, x: 0, y: spec.y)
    }
}
