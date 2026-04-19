//
//  MCQOptionPicker.swift
//  Hangs
//
//  Multiple choice option picker with driving-safe tap targets
//

import SwiftUI

struct MCQOptionPicker: View {
    let options: [(key: String, value: String)]
    let onSelect: (String, String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedKey: String?

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            ForEach(options, id: \.key) { option in
                Button {
                    guard selectedKey == nil else { return }
                    selectedKey = option.key
                    submitAfterDelay(key: option.key, value: option.value)
                } label: {
                    HStack(spacing: Theme.Spacing.md) {
                        Text(option.key.uppercased() + ".")
                            .font(.displayMD)
                            .foregroundColor(
                                selectedKey == option.key
                                    ? .white
                                    : Theme.Colors.accentPrimary
                            )
                            .frame(width: 32)

                        Text(option.value)
                            .font(.textMDBodyMedium)
                            .foregroundColor(
                                selectedKey == option.key
                                    ? .white
                                    : Theme.Colors.textPrimary
                            )
                            .multilineTextAlignment(.leading)

                        Spacer()
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(
                        selectedKey == option.key
                            ? Theme.Colors.accentPrimary
                            : Theme.Colors.bgCard
                    )
                    .cornerRadius(Theme.Radius.xl)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.xl)
                            .stroke(
                                selectedKey == option.key
                                    ? Theme.Colors.accentPrimary
                                    : Theme.Colors.border,
                                lineWidth: 1.5
                            )
                    )
                }
                .disabled(selectedKey != nil)
                .accessibilityLabel("Option \(option.key.uppercased()): \(option.value)")
                .accessibilityIdentifier("mcq.option.\(option.key)")
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.15),
                    value: selectedKey
                )
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
    }

    private func submitAfterDelay(key: String, value: String) {
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            onSelect(key, value)
        }
    }
}

#if DEBUG
#Preview {
    MCQOptionPicker(
        options: [
            (key: "a", value: "Mars"),
            (key: "b", value: "Jupiter"),
            (key: "c", value: "Saturn"),
            (key: "d", value: "Neptune")
        ],
        onSelect: { key, value in
            print("Selected \(key): \(value)")
        }
    )
    .background(Theme.Colors.bgPrimary)
}
#endif
