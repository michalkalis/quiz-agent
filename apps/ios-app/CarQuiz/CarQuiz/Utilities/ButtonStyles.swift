//
//  ButtonStyles.swift
//  CarQuiz
//
//  Custom button styles matching the Pencil design system
//

import SwiftUI

// MARK: - Primary Button Style

/// Purple gradient button with pill shape and glow shadow
/// Used for main CTAs like "Start Quiz", "Continue"
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.displayMD)
            .foregroundColor(Theme.Colors.textOnAccent)
            .padding(.vertical, Theme.Spacing.md)
            .padding(.horizontal, Theme.Spacing.xl)
            .frame(maxWidth: .infinity)
            .background(
                Group {
                    if isEnabled {
                        Theme.Gradients.primary()
                    } else {
                        Theme.Gradients.primary().opacity(0.5)
                    }
                }
            )
            .cornerRadius(Theme.Radius.full)
            .shadow(
                color: isEnabled ? Color(hex: "#8B5CF6").opacity(0.25) : .clear,
                radius: 16,
                x: 0,
                y: 4
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Secondary Button Style

/// Bordered button with card background
/// Used for secondary actions like "Settings", "Stay Here"
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.textMDBodyMedium)
            .foregroundColor(isEnabled ? Theme.Colors.textPrimary : Theme.Colors.textTertiary)
            .padding(.vertical, Theme.Spacing.md)
            .padding(.horizontal, Theme.Spacing.xl)
            .background(Theme.Colors.bgCard)
            .cornerRadius(Theme.Radius.full)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.full)
                    .stroke(Theme.Colors.border, lineWidth: 2)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Danger Button Style

/// Red styled button for destructive actions
struct DangerButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.roundedMD)
            .foregroundColor(.white)
            .padding(.vertical, Theme.Spacing.md)
            .padding(.horizontal, Theme.Spacing.xl)
            .frame(maxWidth: .infinity)
            .background(Theme.Colors.error)
            .cornerRadius(Theme.Radius.full)
            .shadow(
                color: Theme.Colors.error.opacity(0.25),
                radius: 12,
                x: 0,
                y: 4
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Text Button Style

/// Minimal text-only button style
struct TextButtonStyle: ButtonStyle {
    var color: Color = Theme.Colors.accentPrimary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.textMDMedium)
            .foregroundColor(color)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Button Style Extensions

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

extension ButtonStyle where Self == DangerButtonStyle {
    static var danger: DangerButtonStyle { DangerButtonStyle() }
}

extension ButtonStyle where Self == TextButtonStyle {
    static var text: TextButtonStyle { TextButtonStyle() }
    static func text(color: Color) -> TextButtonStyle {
        TextButtonStyle(color: color)
    }
}
