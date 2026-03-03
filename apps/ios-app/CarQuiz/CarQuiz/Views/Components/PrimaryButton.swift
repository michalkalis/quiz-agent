//
//  PrimaryButton.swift
//  CarQuiz
//
//  Purple filled CTA button matching Pencil design
//

import SwiftUI

/// Primary action button with purple fill, white icon/text, pill shape, and shadow
/// Usage: PrimaryButton(title: "Start Quiz", icon: "play.fill") { ... }
struct PrimaryButton: View {
    let title: String
    var icon: String? = nil
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xs) {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                        .accessibilityHidden(true)
                } else if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: Theme.Components.iconMD))
                        .accessibilityHidden(true)
                }

                Text(title)
            }
        }
        .accessibilityLabel(isLoading ? "Loading" : title)
        .buttonStyle(.primary)
        .disabled(isLoading)
    }
}

#Preview {
    VStack(spacing: 20) {
        PrimaryButton(title: "Start Quiz", icon: "play.fill") {}
        PrimaryButton(title: "Continue", icon: "arrow.right") {}
        PrimaryButton(title: "Loading...", isLoading: true) {}
    }
    .padding()
}
