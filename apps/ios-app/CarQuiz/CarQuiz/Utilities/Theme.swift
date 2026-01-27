//
//  Theme.swift
//  CarQuiz
//
//  Centralized design system tokens extracted from Pencil design
//

import SwiftUI

/// Design system tokens for consistent styling across the app
enum Theme {

    // MARK: - Colors

    enum Colors {
        // Brand colors (same in both modes)
        static let accentPrimary = Color(hex: "#8B5CF6")
        static let accentPrimarySoft = Color(hex: "#8B5CF6").opacity(0.125) // 20/255 ≈ 0.125
        static let accentSecondary = Color(hex: "#EC4899")
        static let accentTeal = Color(hex: "#14B8A6")

        // Semantic colors (same in both modes)
        static let success = Color(hex: "#22C55E")
        static let successLight = Color(hex: "#10B981")
        static let error = Color(hex: "#EF4444")
        static let errorDark = Color(hex: "#DC2626")
        static let warning = Color(hex: "#F59E0B")
        static let warningDark = Color(hex: "#D97706")
        static let recording = Color(hex: "#EF4444")

        // Gold colors (for trophy, achievements)
        static let goldLight = Color(hex: "#FCD34D")
        static let goldDark = Color(hex: "#F59E0B")

        // Adaptive colors (light/dark mode)
        static let bgPrimary = Color(light: "#FFFFFF", dark: "#0A0A0A")
        static let bgSecondary = Color(light: "#F8F9FA", dark: "#1A1A1A")
        static let bgCard = Color(light: "#F4F4F5", dark: "#27272A")
        static let bgElevated = Color(light: "#E4E4E7", dark: "#3F3F46")

        static let border = Color(light: "#D4D4D8", dark: "#52525B")
        static let borderStrong = Color(light: "#A1A1AA", dark: "#71717A")

        static let textPrimary = Color(light: "#18181B", dark: "#FAFAFA")
        static let textSecondary = Color(light: "#71717A", dark: "#A1A1AA")
        static let textTertiary = Color(light: "#A1A1AA", dark: "#71717A")
        static let textMuted = Color(light: "#D4D4D8", dark: "#52525B")
        static let textOnAccent = Color.white

        // Result backgrounds (adaptive)
        static let successBg = Color(light: "#DCFCE7", dark: "#14532D")
        static let errorBg = Color(light: "#FEE2E2", dark: "#7F1D1D")
        static let warningBg = Color(light: "#FEF3C7", dark: "#78350F")

        // Tinted backgrounds for badges
        static let accentPrimaryTint = Color(hex: "#8B5CF6").opacity(0.1)
    }

    // MARK: - Typography

    enum Typography {
        // Font families
        static let display = "SF Pro Display"
        static let rounded = "SF Pro Rounded"
        static let text = "SF Pro Text"

        // Font sizes
        static let sizeXXS: CGFloat = 11
        static let sizeXS: CGFloat = 13
        static let sizeSM: CGFloat = 15
        static let sizeMD: CGFloat = 17
        static let sizeLG: CGFloat = 20
        static let sizeXL: CGFloat = 28
        static let sizeXXL: CGFloat = 36
        static let sizeHuge: CGFloat = 48
    }

    // MARK: - Font Weights

    enum Weights {
        static let regular: Font.Weight = .regular     // 400
        static let medium: Font.Weight = .medium       // 500
        static let semibold: Font.Weight = .semibold   // 600
        static let bold: Font.Weight = .bold           // 700
        static let heavy: Font.Weight = .heavy         // 800
    }

    // MARK: - Spacing

    enum Spacing {
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }

    // MARK: - Corner Radius

    enum Radius {
        static let xs: CGFloat = 8
        static let sm: CGFloat = 14
        static let md: CGFloat = 18
        static let lg: CGFloat = 20
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 26
        static let full: CGFloat = 100  // Pill shape
    }

    // MARK: - Shadows

    enum Shadows {
        /// Primary button shadow (purple glow)
        static func primaryButton() -> some View {
            Color(hex: "#8B5CF6").opacity(0.25)
        }

        /// Elevation shadow for cards
        static let elevationColor = Color.black.opacity(0.08)
        static let elevationRadius: CGFloat = 16
        static let elevationY: CGFloat = 4

        /// Mic button glow shadow
        static let micGlowColor = Color(hex: "#8B5CF6").opacity(0.31) // 50/255
        static let micGlowRadius: CGFloat = 32
        static let micGlowY: CGFloat = 8
    }

    // MARK: - Gradients

    enum Gradients {
        /// Primary accent gradient (purple) - 135° angle
        static func primary() -> LinearGradient {
            LinearGradient(
                colors: [Color(hex: "#8B5CF6"), Color(hex: "#7C3AED")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        /// Alternate primary gradient (purple to indigo)
        static func primaryAlt() -> LinearGradient {
            LinearGradient(
                colors: [Color(hex: "#8B5CF6"), Color(hex: "#6366F1")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        /// Recording state gradient (red)
        static func recording() -> LinearGradient {
            LinearGradient(
                colors: [Color(hex: "#EF4444"), Color(hex: "#DC2626")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        /// Gold/trophy gradient
        static func gold() -> LinearGradient {
            LinearGradient(
                colors: [Color(hex: "#FCD34D"), Color(hex: "#F59E0B")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        /// Correct answer gradient (green)
        static func correct() -> LinearGradient {
            LinearGradient(
                colors: [Color(hex: "#22C55E"), Color(hex: "#10B981")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        /// Incorrect answer gradient (red)
        static func incorrect() -> LinearGradient {
            LinearGradient(
                colors: [Color(hex: "#EF4444"), Color(hex: "#DC2626")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        /// Partial answer gradient (orange) - 90° angle
        static func partial() -> LinearGradient {
            LinearGradient(
                colors: [Color(hex: "#F59E0B"), Color(hex: "#D97706")],
                startPoint: .top,
                endPoint: .bottom
            )
        }

        /// Level badge gradient (purple) - 90° angle
        static func level() -> LinearGradient {
            LinearGradient(
                colors: [Color(hex: "#8B5CF6"), Color(hex: "#7C3AED")],
                startPoint: .top,
                endPoint: .bottom
            )
        }

        /// Card gradient border
        static func cardBorder() -> LinearGradient {
            LinearGradient(
                colors: [Color(hex: "#E0E7FF"), Color(hex: "#DDD6FE")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        /// Stats card background gradient (white to off-white)
        static func statsCard() -> LinearGradient {
            LinearGradient(
                colors: [Color(hex: "#FFFFFF"), Color(hex: "#F8FAFC")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    // MARK: - Component Sizes

    enum Components {
        // Mic button sizes (updated to match Pencil design)
        static let micButtonLarge: CGFloat = 140
        static let micIconLarge: CGFloat = 56
        static let micGlowInner: CGFloat = 100

        // Widget sizes
        static let widgetWidth: CGFloat = 140
        static let widgetMicHeight: CGFloat = 44

        // Icon sizes
        static let iconSM: CGFloat = 20
        static let iconMD: CGFloat = 24
        static let iconLG: CGFloat = 32
        static let iconXL: CGFloat = 40
        static let iconHuge: CGFloat = 80

        // Trophy icon
        static let trophySize: CGFloat = 80
        static let trophyIconSize: CGFloat = 40

        // Result badge icon
        static let resultIconCircle: CGFloat = 64
        static let resultIcon: CGFloat = 40
    }
}
