//
//  HangsButton.swift
//  Hangs
//
//  Primary / secondary / ghost buttons matching the Pencil redesign.
//  Primary = pink pill with soft shadow; Secondary = white w/ subtle border;
//  Ghost = inline text link.
//

import SwiftUI

/// Primary CTA — pink filled pill. Label + optional leading / trailing SF symbol.
struct HangsPrimaryButton: View {
    let title: String
    var icon: String? = nil
    var trailingIcon: String? = nil
    var isLoading: Bool = false
    var height: CGFloat = 64
    var isDestructive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isLoading {
                    ProgressView().tint(.white)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .semibold))
                }
                Text(title)
                    .font(.hangsButton)
                if let trailingIcon {
                    Image(systemName: trailingIcon)
                        .font(.system(size: 15, weight: .semibold))
                }
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                Capsule().fill(Theme.Hangs.Colors.pink)
            )
            .hangsShadow(isDestructive ? Theme.Hangs.Shadow.ctaStrong : Theme.Hangs.Shadow.cta)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isLoading ? "Loading" : title)
        .disabled(isLoading)
    }
}

/// Secondary CTA — white pill with hairline border and black text + optional icon.
struct HangsSecondaryButton: View {
    let title: String
    var icon: String? = nil
    var height: CGFloat = 52
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                }
                Text(title)
                    .font(.hangsBody(16, weight: .semibold))
            }
            .foregroundColor(Theme.Hangs.Colors.ink)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                Capsule().fill(Color.white)
            )
            .overlay(
                Capsule().stroke(Theme.Hangs.Colors.subtleBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// Ghost CTA — inline blue text link with optional leading icon. No bg, no border.
struct HangsGhostButton: View {
    let title: String
    var icon: String? = nil
    var color: Color = Theme.Hangs.Colors.blue
    var font: Font = .hangsBody(14, weight: .medium)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(title).font(font)
            }
            .foregroundColor(color)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 12) {
        HangsPrimaryButton(title: "Start Quiz", icon: "play.fill") {}
        HangsPrimaryButton(title: "Next question", trailingIcon: "arrow.right") {}
        HangsSecondaryButton(title: "Home", icon: "house.fill") {}
        HangsGhostButton(title: "Why is this correct?", icon: "book.closed") {}
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.Hangs.Colors.bg)
}
#endif
